defmodule MaveCore.Flow.Steps.AiDescribeVideoStep do
  @moduledoc """
  Collects timestamped visual observations from `media.detect_scenes`, then asks
  the configured writer for original-language narration around measured speech.

  Speech comes from the `ai.transcribe_audio` segments (never from the description
  model); when that step has none, this step transcribes the audio itself. The
  cues are the source for the spoken description.
  """
  @behaviour MaveCore.Flow.Step
  require Logger

  alias MaveCore.AudioDescription.{Budget, Cues, Observations, Script, Timeline}
  alias MaveCore.Embeds.SettingsSerializer
  alias MaveCore.Flow.Steps.AudioDescriptionSupport, as: AD
  alias MaveCore.Flow.Steps.Support, as: StepSupport

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
         {:ok, narration} <- narration(ctx, document, transcript),
         script = narration.script,
         alignment = script["alignment_report"],
         raw_cues = script["cues"],
         plan = Map.take(script, ["category", "summary", "essential_text"]),
         candidates = clean_cues(raw_cues, speech, scenes, duration, transcript.text),
         allocation = Budget.allocate(candidates, speech, duration, plan["category"]),
         rejected = allocation.rejected ++ alignment["rejected"],
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
         {:ok, _} <- AD.put_json(ctx, AD.work_key(ctx, "alignment-report.json"), alignment),
         {:ok, _} <- AD.put_json(ctx, AD.work_key(ctx, "unplaced-cues.json"), rejected) do
      report_progress(ctx, "script_ready", 100, 1)

      output = %{
        "status" => "ok",
        "step_type" => @step_type,
        "step_id" => ctx.step_id,
        "language" => language,
        "cues_key" => cues_key,
        "plan_key" => plan_key,
        "observations_key" => narration.observations_key,
        "observations_reused" => narration.observations_reused,
        "script_reused" => option?(ctx, "reuse_script"),
        "alignment_repaired_count" => alignment["repaired_count"],
        "alignment_rejected_count" => length(alignment["rejected"]),
        "speech_key" => speech_key,
        "duration" => duration,
        "cue_count" => length(cues),
        "unplaced_cue_count" => length(rejected),
        "review_required" =>
          alignment["rejected"] != [] or Enum.any?(rejected, &(&1["priority"] == 3)),
        "category" => plan["category"],
        "word_limit" => allocation.word_limit,
        "scene_count" => length(scenes),
        "speech_seconds" =>
          speech |> Enum.reduce(0.0, &(&2 + &1.end - &1.start)) |> Float.round(1)
      }

      {:ok, Map.merge(output, narration.metadata), []}
    else
      {:error, :no_descriptions} ->
        {:ok, AD.skipped(@step_type, ctx, "no_descriptions"), []}

      {:error, reason} ->
        AD.failure(@step_type, ctx, reason)
    end
  end

  defp narration(ctx, document, transcript) do
    backend = MaveCore.AudioDescription.config(:backend)

    case backend && backend.describe(ctx, document, transcript) do
      result when result in [nil, :default] -> default_narration(ctx, document, transcript)
      result -> result
    end
  end

  defp default_narration(ctx, document, transcript) do
    with {:ok, rows, key, reused?} <- observations(ctx, document, transcript),
         {:ok, script} <- write_script(ctx, rows, document, transcript) do
      {:ok, %{script: script, observations_key: key, observations_reused: reused?, metadata: %{}}}
    end
  end

  defp write_script(ctx, observations, document, transcript) do
    opts = [
      on_attempt: fn attempt -> report_progress(ctx, "writing_script", 75, attempt) end,
      on_alignment_attempt: fn attempt ->
        report_progress(ctx, "repairing_alignment", 85, attempt)
      end,
      on_response: &store_request_metrics(ctx, &1)
    ]

    if option?(ctx, "reuse_script") do
      with {:ok, cues} <- AD.get_json(ctx, AD.work_key(ctx, "raw-cues.json")),
           {:ok, plan} <- AD.get_json(ctx, AD.work_key(ctx, "plan.json")) do
        Script.repair(
          AD.writer_provider(),
          Map.put(plan, "cues", cues),
          observations,
          document,
          AD.language(ctx),
          opts
        )
      end
    else
      Script.write(
        AD.writer_provider(),
        observations,
        document,
        transcript,
        AD.language(ctx),
        opts
      )
    end
  end

  defp option?(ctx, name),
    do: ctx.params[name] == true or get_in(ctx.run_input, ["audio_description", name]) == true

  defp observations(ctx, document, transcript) do
    key = AD.work_key(ctx, "observations.json")

    case AD.get_json(ctx, key) do
      {:ok, %{"schema_version" => 1, "frames" => rows} = cache} ->
        if cache["language"] in [nil, AD.language(ctx)] and Observations.reusable?(rows, document) do
          report_progress(ctx, "reusing_observations", 70, 0)
          {:ok, rows, key, true}
        else
          missing_observations(ctx, document, transcript, key)
        end

      {:ok, _invalid} ->
        missing_observations(ctx, document, transcript, key)

      {:error, {:invalid_json, _}} ->
        missing_observations(ctx, document, transcript, key)

      {:error, {:storage_get_failed, _, :not_found}} ->
        missing_observations(ctx, document, transcript, key)

      error ->
        error
    end
  end

  defp missing_observations(ctx, document, transcript, key) do
    if option?(ctx, "reuse_observations_only"),
      do: {:error, :matching_observations_required},
      else: collect_observations(ctx, document, transcript, key)
  end

  defp collect_observations(ctx, document, transcript, key) do
    report_progress(ctx, "visual_observations", 0, 0)

    with {:ok, rows} <-
           Observations.collect(ctx, document, AD.chat_provider(), AD.language(ctx), transcript),
         {:ok, ^key} <-
           AD.put_json(ctx, key, %{
             "schema_version" => 1,
             "language" => AD.language(ctx),
             "frames" => rows
           }) do
      {:ok, rows, key, false}
    end
  end

  defp report_progress(ctx, stage, percent, attempt) do
    stage =
      if stage == "writing_script" and attempt > 1, do: "rewriting_truncated_script", else: stage

    StepSupport.report_progress(ctx[:progress_reporter], %{
      "stage" => stage,
      "source" => "audio_description",
      "percent" => percent,
      "force" => true
    })
  end

  defp store_request_metrics(ctx, metrics) do
    name =
      if metrics["phase"] == "alignment",
        do: "alignment-request-#{metrics["batch"]}-#{metrics["attempt"]}.json",
        else: "script-request-#{metrics["attempt"]}.json"

    key = AD.work_key(ctx, name)

    case AD.put_json(ctx, key, metrics) do
      {:ok, _} -> :ok
      {:error, _} -> Logger.warning("Could not store audio-description request metrics")
    end
  end

  # Preserve visual event times. The measured-audio scheduler chooses pauses afterwards;
  # model-selected pauses must not move an event to an unrelated picture.
  defp clean_cues(raw_cues, speech, scenes, duration, transcript) do
    gaps = Timeline.free_gaps(speech, duration)

    raw_cues
    |> Enum.flat_map(&clean_cue(&1, scenes, transcript))
    |> Timeline.snap_cues(gaps, scenes)
    |> Enum.flat_map(&Cues.normalize([&1], duration))
    |> Enum.sort_by(& &1.start)
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
      priority: cue_priority(cue),
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

    %{
      intervals: speech_from_segments(segments, duration),
      text: String.slice(text, 0, 40_000),
      segments: Enum.flat_map(segments, &timed_segment/1)
    }
  end

  defp transcript_data(_segments, _duration), do: %{intervals: [], text: "No spoken words."}

  defp timed_segment(segment) do
    start = number(segment[:start] || segment["start"])
    stop = number(segment[:end] || segment["end"])
    text = segment[:text] || segment["text"]

    if start && stop && is_binary(text) && stop > start,
      do: [%{"start" => start, "end" => stop, "text" => text}],
      else: []
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
