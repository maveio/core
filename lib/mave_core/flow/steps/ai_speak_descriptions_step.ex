defmodule MaveCore.Flow.Steps.AiSpeakDescriptionsStep do
  @moduledoc """
  Speaks every description cue of one language with text-to-speech, in a voice
  of that language. Clips are stored privately as trimmed mono 24 kHz PCM; a
  clip that already exists is reused, so a retry only speaks what is missing.
  """
  @behaviour MaveCore.Flow.Step

  alias MaveCore.AudioDescription.{Budget, Cues, Prompts, SpeechFit, SpeechTiming, Wav}
  alias MaveCore.Flow.Steps.AudioDescriptionSupport, as: AD

  @step_type "ai.speak_descriptions"
  @concurrency 5
  @timeout_ms 3 * 60 * 1000

  @impl true
  def run(step, context) do
    ctx = AD.run_context(step, context)
    language = AD.language(ctx)
    source_step_id = AD.source_step_id(ctx, "describe_video")

    with :ok <- AD.check_requested(ctx),
         {:ok, source} <- AD.check_dependency(ctx, source_step_id) do
      speak(ctx, source, language)
    else
      {:skip, reason} -> {:ok, AD.skipped(@step_type, ctx, reason, %{"language" => language}), []}
    end
  end

  defp speak(ctx, source, language) do
    with {:ok, json} <- AD.get_json(ctx, source["cues_key"]),
         cues = Cues.from_json(json),
         {:ok, results} <- speak_cues(ctx, cues, language),
         accepted =
           Enum.flat_map(results, fn
             {:ok, cue, clip, adjustment} -> [{cue, clip, adjustment}]
             _ -> []
           end)
           |> Enum.sort_by(&fitted_cue_start/1),
         rejected =
           Enum.flat_map(results, fn
             {:skip, cue, reason} -> [Budget.rejection(cue, reason)]
             _ -> []
           end),
         {:ok, missing} <- missing_text(ctx, source, accepted),
         {:ok, _} <-
           AD.put_json(ctx, AD.work_key(ctx, "#{language}/uncovered-text.json"), missing),
         {:ok, cues_key} <-
           AD.put_json(
             ctx,
             AD.work_key(ctx, "#{language}/fitted-cues.json"),
             Cues.to_json(Enum.map(accepted, &elem(&1, 0)))
           ),
         {:ok, _} <-
           AD.put_json(ctx, AD.work_key(ctx, "#{language}/unfitted-cues.json"), rejected) do
      {:ok,
       source
       |> Map.take(["speech_key", "duration", "category", "word_limit"])
       |> Map.merge(%{
         "status" => "ok",
         "step_type" => @step_type,
         "step_id" => ctx.step_id,
         "language" => language,
         "cues_key" => cues_key,
         "sample_rate" => Wav.sample_rate(),
         "clips" => Enum.map(accepted, &elem(&1, 1)),
         "uncovered_text_count" => length(missing),
         "faster_cue_count" => Enum.count(accepted, &(elem(&1, 2) == "shortened_faster")),
         "adjusted_cue_count" =>
           Enum.count(accepted, &(elem(&1, 2) in ["shortened", "shortened_faster"])),
         "unplaced_cue_count" => Map.get(source, "unplaced_cue_count", 0) + length(rejected),
         "review_required" =>
           Map.get(source, "review_required", false) or missing != [] or
             Enum.any?(rejected, &needs_review?/1)
       }), []}
    else
      {:error, reason} -> AD.failure(@step_type, ctx, reason)
    end
  end

  defp needs_review?(rejection),
    do: rejection["priority"] == 3 or String.starts_with?(rejection["reason"], "rewrite_")

  defp fitted_cue_start({%{window: %{start: start}}, _, _}), do: start
  defp fitted_cue_start({cue, _, _}), do: cue.start

  defp missing_text(ctx, %{"plan_key" => key}, accepted) do
    with {:ok, plan} <- AD.get_json(ctx, key) do
      narration = Enum.map_join(accepted, " ", fn {cue, _, _} -> cue.text end)

      {:ok,
       SpeechFit.missing_text(plan["essential_text"] || [], narration, plan["spoken_text"] || "")}
    end
  end

  defp missing_text(_ctx, _source, _accepted), do: {:ok, []}

  defp speak_cues(ctx, cues, language) do
    cues
    |> Enum.with_index()
    |> Task.async_stream(fn {cue, index} -> fit_cue(ctx, cue, index, language) end,
      max_concurrency: @concurrency,
      timeout: @timeout_ms,
      ordered: true
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:error, reason}}, _acc -> {:halt, {:error, reason}}
      {:ok, result}, {:ok, results} -> {:cont, {:ok, [result | results]}}
      {:exit, reason}, _acc -> {:halt, {:error, {:speech_task_exit, reason}}}
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp fit_cue(ctx, cue, index, language) do
    speak = fn text, pace ->
      case speak_cue(ctx, %{cue | text: text}, index, language, pace) do
        {:ok, clip} -> ctx.storage.get(ctx.bucket, clip["key"], ctx.region)
        error -> error
      end
    end

    rewrite = fn text, seconds, max_words, feedback ->
      rewrite_cue(ctx, language, cue, text, seconds, max_words, feedback)
    end

    case SpeechFit.fit(cue, speak, rewrite, estimate: &SpeechTiming.estimate(&1, language)) do
      {:ok, fitted, _pcm, adjustment} ->
        pace = if adjustment == "shortened_faster", do: :fast, else: :moderate

        with {:ok, clip} <- speak_cue(ctx, fitted, index, language, pace),
             do: {:ok, fitted, clip, adjustment}

      {:skip, reason} ->
        {:skip, cue, reason}

      error ->
        error
    end
  end

  defp rewrite_cue(ctx, language, cue, text, seconds, max_words, feedback) do
    input = %{
      "original_event_text" => cue.text,
      "text" => text,
      "required_on_screen_text" => cue[:on_screen_text] || "",
      "event_window" => cue[:visual_window] || cue[:scene],
      "speech_measurement" => feedback
    }

    case AD.writer_provider(ctx).chat_json(
           Prompts.rewrite_instruction(language, Float.round(seconds * 1.0, 3), max_words),
           [%{"type" => "text", "text" => Jason.encode!(input)}],
           schema: Prompts.rewrite_schema(),
           max_tokens: 4_000,
           model: get_in(ctx.run_input, ["audio_description", "writer_model"]),
           reasoning_effort: "low"
         ) do
      {:ok, %{"text" => shortened}} when is_binary(shortened) -> {:ok, shortened}
      {:ok, _} -> {:error, :invalid_description_rewrite}
      {:error, _} = error -> error
    end
  end

  defp speak_cue(ctx, cue, index, language, pace) do
    # Retrying a description run can change its text or voice at the same index.
    # Reuse a clip only while all inputs to speech generation stay the same.
    {provider, options} = AD.speech_config(ctx)

    inputs =
      {4, cue.text, language, pace, provider, System.get_env("MAVE_AUDIO_DESCRIPTION_TTS_MODEL"),
       System.get_env("MAVE_AUDIO_DESCRIPTION_VOICES"),
       System.get_env("MAVE_AUDIO_DESCRIPTION_VOICE")}

    fingerprint =
      if(options == [], do: inputs, else: {inputs, provider, options})
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    key =
      AD.work_key(
        ctx,
        "#{language}/speech/#{String.pad_leading("#{index}", 5, "0")}-#{fingerprint}.pcm"
      )

    case ctx.storage.get(ctx.bucket, key, ctx.region) do
      {:ok, pcm} ->
        {:ok, %{"key" => key, "samples" => div(byte_size(pcm), 2)}}

      {:error, _not_found} ->
        with {:ok, audio} <- generate_speech(ctx, cue.text, language, pace),
             {:ok, pcm} <- Wav.clip(audio),
             {:ok, _} <- AD.put_private(ctx, key, pcm, "application/octet-stream") do
          {:ok, %{"key" => key, "samples" => div(byte_size(pcm), 2)}}
        end
    end
  end

  defp generate_speech(ctx, text, language, pace) do
    {provider, options} = AD.speech_config(ctx)

    if Code.ensure_loaded?(provider) and function_exported?(provider, :speak, 3),
      do: provider.speak(text, language, Keyword.put(options, :pace, pace)),
      else: provider.speak(text, language)
  end
end
