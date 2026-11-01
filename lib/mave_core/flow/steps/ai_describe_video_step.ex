defmodule MaveCore.Flow.Steps.AiDescribeVideoStep do
  @moduledoc """
  Writes the English audio description cues from the labelled stills of
  `media.detect_scenes`, around the speech measured by speech-to-text.

  Speech comes from the `ai.transcribe_audio` segments (never from the description
  model); when that step has none, this step transcribes the audio itself. The
  English cues are the only source for every other language.
  """
  @behaviour MaveCore.Flow.Step

  alias MaveCore.AudioDescription
  alias MaveCore.AudioDescription.{Cues, Prompts, Timeline}
  alias MaveCore.Embeds.SettingsSerializer
  alias MaveCore.Flow.Steps.AudioDescriptionSupport, as: AD

  @step_type "ai.describe_video"
  # Scaleway's vision models accept at most this many images per prompt.
  @max_images 12

  @impl true
  def run(step, context) do
    ctx = AD.run_context(step, context)

    with :ok <- AD.check_requested(ctx),
         {:ok, scenes_output} <- AD.check_dependency(ctx, AD.source_step_id(ctx, "detect_scenes")) do
      describe(ctx, scenes_output)
    else
      {:skip, reason} -> {:ok, AD.skipped(@step_type, ctx, reason), []}
    end
  end

  defp describe(ctx, scenes_output) do
    with {:ok, document} <- AD.get_json(ctx, scenes_output["scenes_key"]),
         duration = document["duration"] * 1.0,
         {:ok, speech} <- speech(ctx, duration),
         scenes = intervals(document["scenes"]),
         {:ok, raw_cues} <- describe_batches(ctx, document["stills"], scenes, speech, duration),
         cues = clean_cues(raw_cues, speech, scenes, duration),
         :ok <- require_cues(cues),
         language = AudioDescription.source_language(),
         {:ok, cues_key} <-
           AD.put_json(ctx, AD.work_key(ctx, "#{language}/cues.json"), Cues.to_json(cues)),
         {:ok, speech_key} <-
           AD.put_json(ctx, AD.work_key(ctx, "speech.json"), Enum.map(speech, &interval_json/1)),
         {:ok, _} <- AD.put_json(ctx, AD.work_key(ctx, "raw-cues.json"), raw_cues) do
      {:ok,
       %{
         "status" => "ok",
         "step_type" => @step_type,
         "step_id" => ctx.step_id,
         "language" => language,
         "cues_key" => cues_key,
         "speech_key" => speech_key,
         "duration" => duration,
         "cue_count" => length(cues),
         "scene_count" => length(scenes),
         "speech_seconds" =>
           speech |> Enum.map(&(&1.end - &1.start)) |> Enum.sum() |> Float.round(1)
       }, []}
    else
      {:error, :no_descriptions} ->
        {:ok, AD.skipped(@step_type, ctx, "no_descriptions"), []}

      {:error, reason} ->
        AD.failure(@step_type, ctx, reason)
    end
  end

  defp describe_batches(ctx, stills, scenes, speech, duration) do
    stills
    |> Enum.map(&%{scene: &1["scene"], time: &1["time"] * 1.0, key: &1["key"]})
    |> Timeline.batch_stills(@max_images)
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, cues} ->
      case describe_batch(ctx, batch, cues, scenes, speech, duration) do
        {:ok, batch_cues} -> {:cont, {:ok, cues ++ batch_cues}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp describe_batch(ctx, batch, previous_cues, scenes, speech, duration) do
    window = %{
      start: scene_bound(scenes, hd(batch).scene, :start, 0.0),
      end: scene_bound(scenes, List.last(batch).scene, :end, duration)
    }

    timing = Timeline.timing_prompt(speech, scenes, duration, window)
    previous = previous_cues |> Enum.take(-3) |> Enum.map(&to_string(&1["text"]))

    with {:ok, images} <- load_stills(ctx, batch) do
      content =
        images ++ [%{"type" => "text", "text" => Prompts.stills_request(window, previous)}]

      case AD.chat_provider().chat_json(Prompts.describe_instruction(duration, timing), content,
             schema: Prompts.cues_schema(),
             max_tokens: 8_000
           ) do
        {:ok, %{"cues" => cues}} when is_list(cues) -> {:ok, Enum.filter(cues, &is_map/1)}
        {:ok, _answer} -> {:ok, []}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp load_stills(ctx, batch) do
    Enum.reduce_while(batch, {:ok, []}, fn still, {:ok, parts} ->
      case ctx.storage.get(ctx.bucket, still.key, ctx.region) do
        {:ok, image} ->
          label = "S#{still.scene} at #{:erlang.float_to_binary(still.time, decimals: 2)} s:"

          {:cont,
           {:ok,
            parts ++
              [
                %{"type" => "text", "text" => label},
                %{
                  "type" => "image_url",
                  "image_url" => %{"url" => "data:image/jpeg;base64," <> Base.encode64(image)}
                }
              ]}}

        {:error, reason} ->
          {:halt, {:error, {:still_unavailable, still.key, reason}}}
      end
    end)
  end

  # Pin cues to their scene and chosen pause, using the same scenes and pauses the model was given.
  defp clean_cues(raw_cues, speech, scenes, duration) do
    gaps = Timeline.free_gaps(speech, duration)

    raw_cues
    |> Enum.flat_map(fn cue ->
      start = Cues.parse_timestamp(cue["start"])
      text = cue["text"]

      if is_nil(start) or not is_binary(text) do
        []
      else
        [
          %{
            start: start,
            end: Cues.parse_timestamp(cue["end"]) || start + 2,
            text: text,
            pause: integer_or_nil(cue["pause"]),
            scene: integer_or_nil(cue["shot"])
          }
        ]
      end
    end)
    |> Timeline.snap_cues(gaps, scenes)
    |> Cues.normalize(duration)
  end

  defp require_cues([]), do: {:error, :no_descriptions}
  defp require_cues(_cues), do: :ok

  defp speech(ctx, duration) do
    case Map.get(ctx.outputs, "transcribe_audio") do
      %{"status" => "ok", "subtitle_json_key" => key} when is_binary(key) ->
        with {:ok, %{"segments" => segments}} <- AD.get_json(ctx, key) do
          {:ok, speech_from_segments(segments, duration)}
        end

      _ ->
        transcribe(ctx, duration)
    end
  end

  # Without a transcription from the flow, measure the speech here. A video without
  # audio has no speech, so every moment is a pause.
  defp transcribe(ctx, duration) do
    case Map.get(ctx.outputs, "transcode_audio") do
      %{"status" => "ok", "key" => key} when is_binary(key) ->
        provider =
          Application.get_env(:mave_core, :transcription_provider, MaveCore.Transcription.Mistral)

        with {:ok, transcription} <- transcribe_with(provider, ctx, key) do
          {:ok, speech_from_segments(Map.get(transcription, :segments, []), duration)}
        end

      _ ->
        {:ok, []}
    end
  end

  defp transcribe_with(provider, ctx, key) do
    opts = [filename: Path.basename(key), content_type: "audio/mpeg"]
    url = SettingsSerializer.storage_object_url(ctx.bucket, key)

    url_result =
      if is_binary(url) and function_exported?(provider, :transcribe_url, 2),
        do: provider.transcribe_url(url, opts),
        else: {:error, :url_unsupported}

    case url_result do
      {:ok, transcription} ->
        {:ok, transcription}

      {:error, _reason} ->
        with {:ok, body} <- ctx.storage.get(ctx.bucket, key, ctx.region) do
          provider.transcribe(body, opts)
        end
    end
  end

  defp speech_from_segments(segments, duration) when is_list(segments) do
    segments
    |> Enum.flat_map(fn segment ->
      start = number(segment[:start] || segment["start"])
      stop = number(segment[:end] || segment["end"])
      if start && stop, do: [%{start: start, end: stop}], else: []
    end)
    |> Timeline.speech_from_words(duration)
  end

  defp speech_from_segments(_segments, _duration), do: []

  defp scene_bound(scenes, index, key, default) do
    case Enum.at(scenes, index || 0) do
      %{} = scene -> Map.fetch!(scene, key)
      nil -> default
    end
  end

  defp intervals(list) when is_list(list) do
    Enum.map(list, &%{start: &1["start"] * 1.0, end: &1["end"] * 1.0})
  end

  defp intervals(_list), do: []

  defp interval_json(%{start: start, end: stop}), do: %{"start" => start, "end" => stop}

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(value) when is_float(value), do: trunc(value)
  defp integer_or_nil(_value), do: nil

  defp number(value) when is_number(value), do: value * 1.0
  defp number(_value), do: nil
end
