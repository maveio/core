defmodule MaveCore.Flow.Steps.MediaMixAudioDescriptionStep do
  @moduledoc """
  Builds the audio description of one language: places the spoken clips on the
  timeline (in a pause, or over speech with the original ducked to 20%), mixes
  them with the video's own audio into `audio_description_<lang>.mp3`, writes
  `descriptions_<lang>.vtt` timed to when each description is spoken, and
  packages the MP3 as an HLS audio rendition marked
  `public.accessibility.describes-video`.
  """
  @behaviour MaveCore.Flow.Step

  alias MaveCore.AudioDescription
  alias MaveCore.AudioDescription.{Cues, Mix, Timeline, Wav}
  alias MaveCore.Flow.Steps.AudioDescriptionSupport, as: AD
  alias MaveCore.Flow.Steps.MediaPackageHlsAudioStep
  alias MaveCore.Flow.Steps.Support, as: StepSupport
  alias MaveCore.Languages

  @step_type "media.mix_audio_description"
  @characteristics "public.accessibility.describes-video"

  def characteristics, do: @characteristics

  @impl true
  def run(step, context) do
    ctx = AD.run_context(step, context)
    language = AD.language(ctx)

    with :ok <- AD.check_requested(ctx),
         {:ok, speech} <-
           AD.check_dependency(ctx, AD.source_step_id(ctx, "speak_descriptions_#{language}")) do
      mix(ctx, context, speech, language)
    else
      {:skip, reason} -> {:ok, AD.skipped(@step_type, ctx, reason, %{"language" => language}), []}
    end
  end

  defp mix(ctx, context, speech_output, language) do
    duration = speech_output["duration"] * 1.0

    with {:ok, cues_json} <- AD.get_json(ctx, speech_output["cues_key"]),
         {:ok, speech_json} <- AD.get_json(ctx, speech_output["speech_key"]),
         {:ok, clips} <- load_clips(ctx, speech_output["clips"]),
         cues = Cues.from_json(cues_json),
         speech = Enum.map(speech_json, &%{start: &1["start"] * 1.0, end: &1["end"] * 1.0}),
         lengths = Enum.map(clips, &div(byte_size(&1), 2)),
         timeline = Timeline.plan_timeline(cues, lengths, speech, duration, Wav.sample_rate()),
         :ok <- require_placements(timeline),
         {:ok, audio_size} <- render_and_mix(ctx, context, timeline, clips, duration, language),
         vtt = Cues.to_vtt(timeline.cues, language),
         vtt_key = AD.output_key(ctx, AudioDescription.vtt_filename(language)),
         {:ok, _} <- ctx.storage.put_public(ctx.bucket, vtt_key, vtt, "text/vtt", ctx.region),
         {:ok, hls} <- package_hls(ctx, language, audio_size) do
      output(ctx, language, timeline, audio_size, byte_size(vtt), hls)
    else
      {:error, :no_placements} ->
        {:ok, AD.skipped(@step_type, ctx, "no_descriptions", %{"language" => language}), []}

      {:error, reason} ->
        AD.failure(@step_type, ctx, reason)
    end
  end

  defp load_clips(ctx, clips) when is_list(clips) do
    Enum.reduce_while(clips, {:ok, []}, fn %{"key" => key}, {:ok, acc} ->
      case ctx.storage.get(ctx.bucket, key, ctx.region) do
        {:ok, pcm} -> {:cont, {:ok, [pcm | acc]}}
        {:error, reason} -> {:halt, {:error, {:speech_clip_unavailable, key, reason}}}
      end
    end)
    |> case do
      {:ok, loaded} -> {:ok, Enum.reverse(loaded)}
      error -> error
    end
  end

  defp load_clips(_ctx, _clips), do: {:error, :missing_speech_clips}

  defp require_placements(%{placements: []}), do: {:error, :no_placements}
  defp require_placements(_timeline), do: :ok

  defp render_and_mix(ctx, context, timeline, clips, duration, language) do
    clips = List.to_tuple(clips)
    audio_key = AD.output_key(ctx, AudioDescription.audio_filename(language))

    progress =
      StepSupport.ffmpeg_progress(context[:progress_reporter], %{
        stage: "mix_audio_description",
        step_id: ctx.step_id,
        total_ms: round(duration * 1000)
      })

    StepSupport.with_temp_dir("audio_description", fn dir ->
      with {:ok, description_path} <- StepSupport.tmp_file_path(dir, "description", "pcm"),
           {:ok, output_path} <- StepSupport.tmp_file_path(dir, "mix", "mp3"),
           pcm = Wav.render(timeline.placements, timeline.total_samples, &elem(clips, &1)),
           :ok <- StepSupport.write_tmp_file(description_path, pcm),
           build = &Mix.ffmpeg_args(&1, description_path, output_path, timeline.ducks, duration),
           :ok <- run_mix(ctx, dir, build, progress),
           {:ok, %{size: size}} <- MaveCore.SafeFile.stat_regular(output_path),
           {:ok, _} <-
             ctx.storage.put_file_public(
               ctx.bucket,
               audio_key,
               output_path,
               "audio/mpeg",
               ctx.region
             ) do
        {:ok, size}
      end
    end)
  end

  # Mix with the video's own audio, or the descriptions alone when the video has none.
  defp run_mix(ctx, dir, build, progress) do
    case Map.get(ctx.outputs, "transcode_audio") do
      %{"status" => "ok", "key" => key} when is_binary(key) ->
        case StepSupport.run_ffmpeg_with_storage_fallback(
               dir,
               ctx.run_input,
               nil,
               ctx.outputs,
               &{:ok, build.(&1)},
               progress: progress,
               preferred_storage_step_id: "transcode_audio"
             ) do
          {:ok, _output, _fallback?} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _ ->
        with {:ok, ffmpeg} <- StepSupport.find_ffmpeg(),
             {_output, 0} <- StepSupport.run_media_cmd(ffmpeg, build.(nil)) do
          :ok
        else
          {:error, reason} -> {:error, reason}
          {output, status} -> {:error, {output, status}}
        end
    end
  end

  defp package_hls(ctx, language, audio_size) do
    filename = AudioDescription.audio_filename(language)
    key = AD.output_key(ctx, filename)
    track = audio_track(ctx, language, filename, audio_size)

    step = %{
      "id" => "#{ctx.step_id}_hls",
      "type" => "media.package_hls_audio",
      "params" => %{"source_step_id" => "audio_description", "default" => false, "strict" => true}
    }

    context = %{
      run_input: Map.take(ctx.run_input, ["space_hash", "embed_hash", "version", "region"]),
      dependency_outputs: %{
        "source" => Map.get(ctx.outputs, "source", %{}),
        "audio_description" => %{
          "step_type" => "media.transcode_audio",
          "status" => "ok",
          "bucket" => ctx.bucket,
          "key" => key,
          "uri" => "s3://#{ctx.bucket}/#{key}",
          "audio_track" => track,
          "audio_tracks" => [track]
        }
      }
    }

    case MediaPackageHlsAudioStep.run(step, context) do
      {:ok, %{"status" => "ok", "audio_track" => packaged}, _artifacts} ->
        {:ok, packaged}

      {:ok, other, _artifacts} ->
        {:error, {:hls_packaging_unavailable, other["error"] || other["reason"]}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp audio_track(ctx, language, filename, size) do
    key = AD.output_key(ctx, filename)

    %{
      "id" => "audio_description_#{language}",
      "label" => label(language),
      "language" => language,
      "default" => false,
      "codec" => "mp3",
      "file_size" => size,
      "filename" => filename,
      "bucket" => ctx.bucket,
      "key" => key,
      "path" => "s3://#{ctx.bucket}/#{key}",
      "src" => "s3://#{ctx.bucket}/#{key}"
    }
  end

  @doc "Name of the audio-description track of `language`, e.g. `English (audio description)`."
  def label(language) do
    "#{Languages.spoken_language(language) || String.upcase(language)} (audio description)"
  end

  defp output(ctx, language, timeline, audio_size, vtt_size, hls) do
    audio_filename = AudioDescription.audio_filename(language)
    vtt_filename = AudioDescription.vtt_filename(language)
    audio_key = AD.output_key(ctx, audio_filename)
    vtt_key = AD.output_key(ctx, vtt_filename)

    description = %{
      "language" => language,
      "label" => label(language),
      "audio_filename" => audio_filename,
      "audio_file_size" => audio_size,
      "vtt_filename" => vtt_filename,
      "vtt_file_size" => vtt_size,
      "cue_count" => length(timeline.cues),
      "ducked_cue_count" => length(timeline.ducks),
      "hls_playlist" => hls["hls_playlist"]
    }

    track =
      hls
      |> Map.take([
        "id",
        "label",
        "language",
        "hls_playlist",
        "hls_src",
        "hls_bandwidth",
        "hls_channels"
      ])
      |> Map.merge(%{"default" => false, "characteristics" => @characteristics})

    {:ok,
     %{
       "status" => "ok",
       "step_type" => @step_type,
       "step_id" => ctx.step_id,
       "language" => language,
       "audio_description" => description,
       "audio_track" => track,
       "cue_count" => length(timeline.cues),
       "ducked_cue_count" => length(timeline.ducks),
       "skipped_cue_count" => length(timeline.skipped)
     },
     [
       AD.artifact("audio_description_#{language}", ctx, audio_key, "audio/mpeg", audio_size, %{
         "language" => language
       }),
       AD.artifact("descriptions_#{language}", ctx, vtt_key, "text/vtt", vtt_size, %{
         "language" => language
       })
     ]}
  end
end
