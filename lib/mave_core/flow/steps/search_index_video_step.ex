defmodule MaveCore.Flow.Steps.SearchIndexVideoStep do
  @moduledoc """
  Collects the text that makes a video searchable by content and stores it as a
  private moments document (`<embed>/vN/search/moments.json`).

  Visual moments reuse the frame observations of `ai.describe_video` when audio
  description already produced them; otherwise this step asks the same vision
  provider for the stills of `media.detect_scenes`, and saves the observations
  where a later audio-description run finds them. Transcript moments come from
  `ai.transcribe_audio`. One source failing or being unavailable does not stop
  the other from being indexed.

  The step skips itself unless the run input has `search`. Core indexes the
  document in PostgreSQL once the step has succeeded.
  """
  @behaviour MaveCore.Flow.Step

  alias MaveCore.AudioDescription
  alias MaveCore.AudioDescription.Observations
  alias MaveCore.Flow.RetryPolicy
  alias MaveCore.Flow.Steps.AudioDescriptionSupport, as: AD
  alias MaveCore.Search
  alias MaveCore.Search.Document

  @step_type "search.index_video"

  @impl true
  def run(step, context) do
    ctx = AD.run_context(step, context)
    sources = Search.requested_sources(ctx.run_input)

    cond do
      sources == [] ->
        {:ok, AD.skipped(@step_type, ctx, "not_requested"), []}

      not (is_binary(ctx.space_hash) and is_binary(ctx.embed_hash)) ->
        {:ok, AD.skipped(@step_type, ctx, "missing_embed"), []}

      true ->
        index(ctx, sources)
    end
  end

  defp index(ctx, sources) do
    language = AudioDescription.original_language(ctx.run_input, ctx.outputs)

    with {:ok, segments, transcript_report} <- transcript(ctx, sources),
         {:ok, observations, duration, visual_report} <- visual(ctx, sources, language, segments) do
      visual_moments = Document.visual_moments(observations, duration)
      transcript_moments = Document.transcript_moments(segments)
      moments = visual_moments ++ transcript_moments
      key = Search.document_key(ctx.embed_hash, ctx.version)

      case AD.put_json(ctx, key, Document.to_json(moments, language)) do
        {:ok, ^key} ->
          {:ok,
           %{
             "status" => "ok",
             "step_type" => @step_type,
             "step_id" => ctx.step_id,
             "document_key" => key,
             "language" => language,
             "moment_count" => length(moments),
             "visual_moment_count" => length(visual_moments),
             "transcript_moment_count" => length(transcript_moments),
             "visual" => visual_report,
             "transcript" => transcript_report
           }, []}

        {:error, reason} ->
          failure(ctx, reason)
      end
    else
      {:error, reason} -> failure(ctx, reason)
    end
  end

  ## Transcript

  defp transcript(ctx, sources) do
    output = Map.get(ctx.outputs, "transcribe_audio")

    cond do
      "transcript" not in sources ->
        {:ok, [], report("skipped", "not_requested")}

      not match?(%{"status" => "ok"}, output) ->
        {:ok, [], report("skipped", "no_transcript")}

      true ->
        case transcript_segments(ctx, output) do
          {:ok, segments} -> {:ok, segments, %{"status" => "ok"}}
          {:error, reason} -> unavailable(reason, [])
        end
    end
  end

  defp transcript_segments(ctx, %{"subtitle_json_key" => key}) when is_binary(key) do
    case AD.get_json(ctx, key) do
      {:ok, %{"segments" => segments}} when is_list(segments) -> {:ok, segments}
      {:ok, _other} -> {:error, {:invalid_json, key}}
      error -> error
    end
  end

  defp transcript_segments(ctx, %{"subtitle_key" => key}) when is_binary(key) do
    case ctx.storage.get(ctx.bucket, key, ctx.region) do
      {:ok, body} when is_binary(body) -> {:ok, Document.vtt_segments(body)}
      {:ok, _body} -> {:error, {:invalid_vtt, key}}
      {:error, reason} -> {:error, {:storage_get_failed, key, reason}}
    end
  end

  defp transcript_segments(_ctx, _output), do: {:ok, []}

  ## Visual

  defp visual(ctx, sources, language, segments) do
    scenes = Map.get(ctx.outputs, AD.source_step_id(ctx, "detect_scenes"))

    cond do
      "visual" not in sources ->
        {:ok, [], nil, report("skipped", "not_requested")}

      not match?(%{"status" => "ok", "scenes_key" => key} when is_binary(key), scenes) ->
        {:ok, [], nil, report("skipped", skip_reason(scenes))}

      true ->
        observed_frames(ctx, scenes["scenes_key"], language, segments)
    end
  end

  defp observed_frames(ctx, scenes_key, language, segments) do
    with {:ok, document} <- AD.get_json(ctx, scenes_key),
         {:ok, rows, reused?} <- observations(ctx, document, language, segments) do
      {:ok, rows, document["duration"], %{"status" => "ok", "observations_reused" => reused?}}
    else
      {:error, reason} ->
        with {:ok, [], report} <- unavailable(reason, []), do: {:ok, [], nil, report}
    end
  end

  defp skip_reason(%{"reason" => reason}) when is_binary(reason), do: reason
  defp skip_reason(_output), do: "no_scenes"

  # Same object and shape as `ai.describe_video`, so whichever step runs first
  # pays for the vision request and the other one reuses it.
  defp observations(ctx, document, language, segments) do
    key = AD.work_key(ctx, "observations.json")

    case AD.get_json(ctx, key) do
      {:ok, %{"schema_version" => 1, "frames" => rows}} ->
        if Observations.reusable?(rows, document),
          do: {:ok, rows, true},
          else: collect(ctx, document, language, segments, key)

      {:ok, _invalid} ->
        collect(ctx, document, language, segments, key)

      {:error, {:invalid_json, _}} ->
        collect(ctx, document, language, segments, key)

      {:error, {:storage_get_failed, _, :not_found}} ->
        collect(ctx, document, language, segments, key)

      error ->
        error
    end
  end

  defp collect(ctx, document, language, segments, key) do
    transcript = %{segments: Enum.flat_map(segments, &timed_segment/1)}

    with {:ok, rows} <-
           Observations.collect(ctx, document, AD.chat_provider(), language, transcript),
         {:ok, ^key} <-
           AD.put_json(ctx, key, %{
             "schema_version" => 1,
             "language" => language,
             "frames" => rows
           }) do
      {:ok, rows, false}
    end
  end

  defp timed_segment(%{"start" => start, "end" => stop, "text" => text})
       when is_number(start) and is_number(stop) and is_binary(text),
       do: [%{"start" => start, "end" => stop, "text" => text}]

  defp timed_segment(_segment), do: []

  ## Results

  defp report(status, reason), do: %{"status" => status, "reason" => reason}

  # Transient provider and storage errors fail the step so the engine retries
  # it; anything else is recorded and the other source is still indexed.
  defp unavailable(reason, value) do
    if RetryPolicy.transient_error?(reason),
      do: {:error, reason},
      else: {:ok, value, %{"status" => "unavailable", "error" => inspect(reason)}}
  end

  defp failure(ctx, reason) do
    if ctx.strict? or RetryPolicy.transient_error?(reason) do
      {:error, {:search_index_video_failed, reason}}
    else
      {:ok,
       %{
         "status" => "unavailable",
         "step_type" => @step_type,
         "step_id" => ctx.step_id,
         "error" => inspect(reason)
       }, []}
    end
  end
end
