defmodule MaveCore.Flow.Steps.AiDescribeVideoStep do
  @moduledoc """
  Collects timestamped visual observations from `media.detect_scenes`, then asks
  the configured writer for original-language narration around measured speech.

  Speech comes from the `ai.transcribe_audio` segments (never from the description
  model); when that step has none, this step transcribes the audio itself. The
  cues are the source for the spoken description.
  """
  @behaviour MaveCore.Flow.Step

  alias MaveCore.AudioDescription.{Budget, Cues, Observations, Script, Timeline}
  alias MaveCore.Embeds.SettingsSerializer
  alias MaveCore.Flow.Steps.AudioDescriptionSupport, as: AD

  @step_type "ai.describe_video"

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
         {:ok, transcript} <- speech(ctx, duration),
         speech = transcript.intervals,
         scenes = intervals(document["scenes"]),
         {:ok, observations} <-
           Observations.collect(ctx, document, AD.chat_provider(), AD.language(ctx)),
         {:ok, observations_key} <-
           AD.put_json(ctx, AD.work_key(ctx, "observations.json"), %{
             "schema_version" => 1,
             "frames" => observations
           }),
         {:ok, script} <-
           Script.write(
             AD.writer_provider(),
             observations,
             document,
             transcript,
             AD.language(ctx)
           ),
         raw_cues = script["cues"],
         plan = Map.take(script, ["category", "summary", "essential_text"]),
         candidates = clean_cues(raw_cues, speech, scenes, duration, transcript.text),
         allocation = Budget.allocate(candidates, speech, duration, plan["category"]),
         cues = allocation.cues,
         language = AD.language(ctx),
         {:ok, cues_key} <-
           AD.put_json(ctx, AD.work_key(ctx, "#{language}/cues.json"), Cues.to_json(cues)),
         {:ok, speech_key} <-
           AD.put_json(ctx, AD.work_key(ctx, "speech.json"), Enum.map(speech, &interval_json/1)),
         {:ok, _} <- AD.put_json(ctx, AD.work_key(ctx, "raw-cues.json"), raw_cues),
         {:ok, plan_key} <-
           AD.put_json(
             ctx,
             AD.work_key(ctx, "plan.json"),
             Map.put(plan, "spoken_text", transcript.text)
           ),
         {:ok, _} <- AD.put_json(ctx, AD.work_key(ctx, "unplaced-cues.json"), allocation.rejected) do
      {:ok,
       %{
         "status" => "ok",
         "step_type" => @step_type,
         "step_id" => ctx.step_id,
         "language" => language,
         "cues_key" => cues_key,
         "plan_key" => plan_key,
         "observations_key" => observations_key,
         "speech_key" => speech_key,
         "duration" => duration,
         "cue_count" => length(cues),
         "unplaced_cue_count" => length(allocation.rejected),
         "review_required" => Enum.any?(allocation.rejected, &(&1["priority"] == 3)),
         "category" => plan["category"],
         "word_limit" => allocation.word_limit,
         "scene_count" => length(scenes),
         "speech_seconds" =>
           speech |> Enum.reduce(0.0, &(&2 + &1.end - &1.start)) |> Float.round(1)
       }, []}
    else
      {:error, :no_descriptions} ->
        {:ok, AD.skipped(@step_type, ctx, "no_descriptions"), []}

      {:error, reason} ->
        AD.failure(@step_type, ctx, reason)
    end
  end

  # Preserve visual event times. The measured-audio scheduler chooses pauses afterwards;
  # model-selected pauses must not move an event to an unrelated picture.
  defp clean_cues(raw_cues, speech, scenes, duration, transcript) do
    gaps = Timeline.free_gaps(speech, duration)

    raw_cues
    |> Enum.flat_map(&clean_cue(&1, scenes, transcript))
    |> Timeline.snap_cues(gaps, scenes)
    |> Cues.normalize(duration)
  end

  defp clean_cue(%{"text" => text} = cue, scenes, transcript) when is_binary(text) do
    start = Cues.parse_timestamp(cue["start"])
    required = literal_text(cue, text)
    spoken = required && String.contains?(comparable_text(transcript), comparable_text(required))

    cond do
      is_nil(start) ->
        []

      spoken && comparable_text(text) == comparable_text(required) ->
        []

      true ->
        [build_cue(cue, scenes, start, text, if(spoken, do: nil, else: required))]
    end
  end

  defp clean_cue(_cue, _scenes, _transcript), do: []

  defp build_cue(cue, scenes, start, text, required) do
    %{
      start: start,
      end: Cues.parse_timestamp(cue["end"]) || start + 2,
      text: text,
      pause: -1,
      scene: cue_scene_index(cue, scenes, start),
      on_screen_text: required || "",
      observation_ids: Map.get(cue, "observation_ids", []),
      visual_window: cue["visual_window"],
      priority: if(required, do: 3, else: cue_priority(cue)),
      kind: if(required, do: "text", else: cue_kind(cue))
    }
  end

  defp literal_text(%{"on_screen_text" => required}, text) when is_binary(required) do
    normalized = comparable_text(required)
    if normalized != "" and String.contains?(comparable_text(text), normalized), do: required
  end

  defp literal_text(_cue, _text), do: nil

  defp cue_scene_index(cue, scenes, start) do
    Enum.find_index(scenes, &(start >= &1.start and start < &1.end)) ||
      integer_or_nil(cue["shot"])
  end

  defp comparable_text(text),
    do: text |> String.downcase() |> String.replace(~r/[^\p{L}\p{N}]+/u, " ") |> String.trim()

  defp cue_priority(%{"priority" => value}) when value in [1, 2, 3], do: value
  defp cue_priority(_cue), do: 2
  defp cue_kind(%{"kind" => value}) when value in ["action", "setting"], do: value
  defp cue_kind(_cue), do: "action"

  defp speech(ctx, duration) do
    case Map.get(ctx.outputs, "transcribe_audio") do
      %{"status" => "ok", "subtitle_json_key" => key} when is_binary(key) ->
        with {:ok, %{"segments" => segments}} <- AD.get_json(ctx, key) do
          {:ok, transcript_data(segments, duration)}
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
          {:ok, transcript_data(Map.get(transcription, :segments, []), duration)}
        end

      _ ->
        {:ok, %{intervals: [], text: "No spoken words."}}
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

  defp transcript_data(segments, duration) when is_list(segments) do
    text =
      Enum.map_join(segments, "\n", fn segment ->
        "#{segment[:start] || segment["start"]}-#{segment[:end] || segment["end"]}: #{segment[:text] || segment["text"] || ""}"
      end)

    %{intervals: speech_from_segments(segments, duration), text: String.slice(text, 0, 40_000)}
  end

  defp transcript_data(_segments, _duration), do: %{intervals: [], text: "No spoken words."}

  defp speech_from_segments(segments, duration) when is_list(segments) do
    segments
    |> Enum.flat_map(fn segment ->
      start = number(segment[:start] || segment["start"])
      stop = number(segment[:end] || segment["end"])
      if start && stop, do: [%{start: start, end: stop}], else: []
    end)
    |> Timeline.speech_from_words(duration)
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
