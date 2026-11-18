defmodule MaveCore.AudioDescription.EditorAudio do
  @moduledoc "Renders the editor's literal text at its selected times using reusable private speech clips."

  alias MaveCore.AudioDescription.Wav
  alias MaveCore.Flow.Steps.{AiSpeakDescriptionsStep, MediaMixAudioDescriptionStep}
  alias MaveCore.Flow.Steps.AudioDescriptionSupport, as: AD

  def render(ctx, moments, duration, language, render_id, vtt) do
    prefix = AD.work_key(ctx, "#{language}/speech/")

    with {:ok, keys} <- list_keys(ctx, prefix),
         cache =
           Map.new(
             Enum.sort_by(keys, &String.contains?(&1, "/" <> render_id <> "-")),
             &{fingerprint(&1), &1}
           ),
         {:ok, rows} <-
           render_lines(ctx, moments, language, prefix <> render_id <> "-", cache, duration) do
      cues = Enum.map(rows, &elem(&1, 0))
      placements = Enum.map(rows, &elem(&1, 1))
      clips = Enum.map(rows, &elem(&1, 2))

      timeline = %{
        cues: cues,
        placements: placements,
        total_samples: round(duration * Wav.sample_rate())
      }

      with {:ok, attrs} <-
             MediaMixAudioDescriptionStep.render_edit(
               ctx,
               timeline,
               clips,
               duration,
               language,
               render_id,
               vtt
             ) do
        characters =
          rows
          |> Enum.map(&elem(&1, 3))
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
          |> Enum.map(&String.length/1)
          |> Enum.sum()

        {:ok, attrs, characters}
      end
    end
  end

  defp list_keys(ctx, prefix) do
    cond do
      function_exported?(ctx.storage, :list_keys, 3) ->
        ctx.storage.list_keys(ctx.bucket, prefix, ctx.region)

      function_exported?(ctx.storage, :list_prefix_keys, 3) ->
        ctx.storage.list_prefix_keys(ctx.bucket, prefix, ctx.region)

      true ->
        {:ok, []}
    end
  end

  # Initial flow runs use <index>-<digest>.pcm. Editor renders use <render_id>-<digest>.pcm
  # so an insertion, deletion or move never invalidates the other voices.
  defp fingerprint(key), do: key |> Path.basename(".pcm") |> String.split("-") |> List.last()

  defp render_lines(ctx, moments, language, prefix, cache, duration) do
    moments
    |> Enum.chunk_every(2, 1)
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], 0}, fn {[line | following], index}, {:ok, rows, cursor} ->
      start = max(cursor, round(line["start"] * Wav.sample_rate()))

      next_start = if following == [], do: duration, else: hd(following)["start"]

      {boundary, stop_time} =
        cond do
          is_number(line["end"]) and line["end"] < next_start -> {"cue_end", line["end"]}
          is_number(line["end"]) and following != [] -> {"next_description", next_start}
          true -> {"video_end", duration}
        end

      stop = round(stop_time * Wav.sample_rate())

      with {:ok, pcm, source} <-
             speech_clip(ctx, line["text"], language, prefix, cache, stop - start + 12),
           length = div(byte_size(pcm), 2),
           :ok <- check_fit(line["start"], length, stop - start, boundary) do
        # WebVTT rounds times to milliseconds; tolerate that rounding at cue boundaries.
        length = min(length, stop - start)

        cue = %{
          start: start / Wav.sample_rate(),
          end: (start + length) / Wav.sample_rate(),
          text: line["text"]
        }

        placement = %{index: index, start: start, length: length}

        {:cont,
         {:ok,
          [
            {cue, placement, pcm, if(String.starts_with?(source, prefix), do: line["text"])}
            | rows
          ], start + length}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rows, _cursor} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp check_fit(_time, length, available, _)
       when length > 0 and length <= available + 12 and available > 0, do: :ok

  defp check_fit(time, length, available, boundary) do
    {:error,
     {:description_does_not_fit,
      %{
        "start" => time,
        "boundary" => boundary,
        "needed" => length / Wav.sample_rate(),
        "available" => available / Wav.sample_rate()
      }}}
  end

  defp speech_clip(ctx, text, language, prefix, cache, available) do
    normal = AiSpeakDescriptionsStep.speech_fingerprint(ctx, text, language, :moderate)
    fast = AiSpeakDescriptionsStep.speech_fingerprint(ctx, text, language, :fast)
    pace = if cache[fast] && !cache[normal], do: :fast, else: :moderate
    digest = if pace == :fast, do: fast, else: normal

    with {:ok, pcm, key} <- load_clip(ctx, text, language, pace, prefix, digest, cache) do
      samples = div(byte_size(pcm), 2)

      if pace == :moderate and samples > available and
           (cache[fast] ||
              samples <= available * MaveCore.AudioDescription.SpeechFit.max_speedup()) do
        with {:ok, faster, fast_key} <- load_clip(ctx, text, language, :fast, prefix, fast, cache) do
          if byte_size(faster) < byte_size(pcm) and
               (cache[fast] ||
                  byte_size(pcm) <=
                    byte_size(faster) * MaveCore.AudioDescription.SpeechFit.max_speedup()),
             do: {:ok, faster, fast_key},
             else: {:ok, pcm, key}
        end
      else
        {:ok, pcm, key}
      end
    end
  end

  defp load_clip(ctx, text, language, pace, prefix, digest, cache) do
    key = cache[digest] || prefix <> digest <> ".pcm"

    case ctx.storage.get(ctx.bucket, key, ctx.region) do
      {:ok, pcm} when is_binary(pcm) and byte_size(pcm) >= 2 ->
        {:ok, pcm, key}

      {:ok, _} ->
        {:error, :invalid_description_clip}

      {:error, :not_found} ->
        with :ok <- ctx.before_speech.(text),
             {:ok, audio} <-
               AiSpeakDescriptionsStep.generate_speech(ctx, text, language, pace),
             {:ok, pcm} <- Wav.clip(audio),
             true <- byte_size(pcm) >= 2,
             {:ok, _} <-
               AD.put_private(ctx, prefix <> digest <> ".pcm", pcm, "application/octet-stream") do
          {:ok, pcm, prefix <> digest <> ".pcm"}
        else
          false -> {:error, :invalid_description_clip}
          error -> error
        end

      error ->
        error
    end
  end
end
