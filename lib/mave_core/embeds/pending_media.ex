defmodule MaveCore.Embeds.PendingMedia do
  @moduledoc false

  alias MaveCore.Assets.AudioTrack
  alias MaveCore.AudioDescription
  alias MaveCore.Flow.{Definition, Run}
  alias MaveCore.Languages

  @active ~w(queued scheduled executing)
  @ad_types ~w(media.detect_scenes ai.describe_video ai.translate_descriptions ai.speak_descriptions media.mix_audio_description)
  @empty %{audio_tracks: [], audio_descriptions: [], subtitles: []}

  def for_run(%Run{status: status} = run, version, current)
      when status in ["queued", "running"] do
    if run_version(run) == version, do: build_pending(run, current), else: @empty
  end

  def for_run(_, _, _), do: @empty

  defp build_pending(run, current) do
    outputs = Map.new(run.step_runs, &{&1.step_id, &1.output || %{}})

    context = %{
      run: run,
      steps: Map.new(run.step_runs, &{&1.step_id, &1}),
      current: current,
      outputs: outputs,
      language: detected_language(run.input, outputs),
      definitions: Definition.steps(run.flow_version.definition) |> Map.new(&{&1["id"], &1})
    }

    run.step_runs
    |> Enum.filter(&(&1.status in @active))
    |> Enum.reduce(@empty, &add_pending(&1, context, &2))
  end

  defp add_pending(step, context, pending) do
    kind = media_kind(step.step_type)

    if kind && eligible?(kind, context.run, context.outputs) &&
         not blocked?(step.step_id, kind, context, MapSet.new()) do
      params = get_in(context.definitions, [step.step_id, "params"]) || %{}
      row = row(kind, step, params, context.language, context.run)

      if materialized?(kind, row, context.current),
        do: pending,
        else: Map.update!(pending, kind, &(&1 ++ [row]))
    else
      pending
    end
  end

  defp blocked?(id, kind, context, seen) do
    if MapSet.member?(seen, id) do
      false
    else
      definition = context.definitions[id] || %{}

      Enum.any?(definition["depends_on"] || [], fn dependency ->
        parent_id = dependency_id(dependency)
        parent = context.steps[parent_id]
        failed_parent?(parent, kind) or blocked?(parent_id, kind, context, MapSet.put(seen, id))
      end)
    end
  end

  defp dependency_id(%{"id" => id}), do: id
  defp dependency_id(id), do: id

  defp failed_parent?(nil, _kind), do: false

  defp failed_parent?(%{step_type: type}, :audio_descriptions)
       when type in ["media.transcode_audio", "ai.transcribe_audio"], do: false

  defp failed_parent?(step, _kind) do
    step.status in ["failed", "cancelled", "skipped"] or
      Map.get(step.output || %{}, "status") in ["skipped", "unavailable"]
  end

  defp media_kind("media.transcode_audio"), do: :audio_tracks
  defp media_kind("media.mix_audio_description"), do: :audio_descriptions

  defp media_kind(type) when type in ["ai.transcribe_audio", "ai.translate_subtitles"],
    do: :subtitles

  defp media_kind(_), do: nil

  defp eligible?(:audio_descriptions, run, outputs) do
    duration = get_in(outputs, ["inspect_media", "duration"])

    AudioDescription.requested?(run.input) and
      (not is_number(duration) or duration <= AudioDescription.max_seconds()) and
      get_in(outputs, ["inspect_media", "has_video"]) != false and
      Enum.all?(run.step_runs, fn step ->
        step.step_type not in @ad_types or
          (step.status not in ["failed", "cancelled", "skipped"] and
             Map.get(step.output || %{}, "status") not in ["skipped", "unavailable"])
      end)
  end

  defp eligible?(_, _run, outputs), do: get_in(outputs, ["inspect_media", "has_audio"]) != false

  defp row(kind, step, params, detected, run) do
    language = Languages.normalize_media_language(params["language"]) || detected
    name = Languages.spoken_language(language)

    %{
      id: "generated-#{step.id}",
      label: row_label(kind, params, language, name),
      language: language,
      state: row_state(kind, step, run)
    }
  end

  defp row_label(:audio_tracks, params, language, _name),
    do:
      AudioTrack.display_label(%{
        label: params["label"] || "Original",
        language: language,
        default: true
      })

  defp row_label(:audio_descriptions, _params, _language, nil), do: "Audio description"
  defp row_label(:audio_descriptions, _params, _language, name), do: "#{name} (AD)"
  defp row_label(:subtitles, _params, _language, name), do: name || "Subtitles"

  defp row_state(_kind, %{status: "executing"}, _run), do: :processing

  defp row_state(:audio_descriptions, _step, run) do
    if Enum.any?(run.step_runs, &(&1.step_type in @ad_types and &1.status == "executing")),
      do: :processing,
      else: :queued
  end

  defp row_state(_, _, _), do: :queued

  defp materialized?(kind, row, current) do
    items = Map.get(current, kind, [])

    if is_nil(row.language),
      do: items != [],
      else: Enum.any?(items, &(&1.language == row.language))
  end

  defp detected_language(input, outputs) do
    transcript = outputs["transcribe_audio"] || %{}

    Languages.normalize_media_language(
      transcript["language"] || transcript["transcription_language"] || input["language"]
    )
  end

  defp run_version(%{input: %{"version" => value}}) when is_integer(value), do: value

  defp run_version(%{input: %{"version" => value}}) when is_binary(value) do
    case Integer.parse(value) do
      {version, ""} -> version
      _ -> 0
    end
  end

  defp run_version(_), do: 0
end
