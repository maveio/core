defmodule MaveCore.AudioDescription.SpeechFit do
  @moduledoc "Fits complete spoken descriptions to reserved time windows without cutting audio."
  alias MaveCore.AudioDescription.Wav

  @rewrite_response_errors [
    :model_output_truncated,
    :invalid_model_json,
    :empty_model_answer,
    :invalid_description_rewrite
  ]
  @max_speedup 1.15

  def fit(cue, speak, rewrite, opts \\ [])

  def fit(%{window: _} = cue, speak, rewrite, opts) do
    case fit_window(cue, speak, rewrite, opts) do
      {:skip, reason} -> ducking_fallback(cue, speak, rewrite, reason, opts)
      result -> result
    end
  end

  def fit(cue, speak, _rewrite, _opts) do
    with {:ok, clip} <- speak.(cue.text, :moderate), do: {:ok, cue, clip, "legacy"}
  end

  defp fit_window(%{window: nil}, _speak, _rewrite, _opts), do: {:skip, "no_safe_time"}

  defp fit_window(%{window: window} = cue, speak, rewrite, opts) do
    budget = window.end - window.start

    with true <- required_text_present?(cue, cue.text),
         {:ok, prepared, remaining} <-
           prepare(cue, preparation_budget(cue, budget), rewrite, opts[:estimate], 2),
         {:ok, clip} <- speak.(prepared.text, :moderate) do
      accept_or_shorten(cue, prepared, clip, budget, speak, rewrite, remaining)
    else
      false -> {:skip, "missing_on_screen_text"}
      error -> error
    end
  end

  defp accept_or_shorten(cue, prepared, clip, budget, speak, rewrite, remaining) do
    adjustment = if prepared.text == cue.text, do: "original", else: "shortened"

    cond do
      fits?(prepared.text, clip, budget) ->
        {:ok, prepared, clip, adjustment}

      fits_extension?(prepared, clip) ->
        fitted =
          prepared |> Map.put(:window, prepared.duck_window) |> Map.put(:allow_ducking, true)

        {:ok, fitted, clip, adjustment}

      true ->
        shorten(prepared, clip, budget, speak, rewrite, remaining)
    end
  end

  # Useful descriptions may finish across a short pause boundary. Use their
  # reserved extension before rewriting a complete, naturally spoken sentence.
  defp preparation_budget(%{priority: 2, window: window, duck_window: extra}, budget)
       when extra.start == window.start,
       do: max(budget, extra.end - extra.start)

  defp preparation_budget(_cue, budget), do: budget

  defp fits_extension?(%{priority: 2, window: window, duck_window: extra} = cue, clip),
    do: extra.start == window.start and fits?(cue.text, clip, extra.end - extra.start)

  defp fits_extension?(_cue, _clip), do: false

  defp ducking_fallback(
         %{priority: priority, duck_window: window} = cue,
         speak,
         rewrite,
         reason,
         opts
       )
       when priority in [2, 3] and
              reason in ["no_safe_time", "no_fitting_rewrite", "speech_too_long"] do
    fallback =
      cue
      |> Map.put(:window, window)
      |> Map.put(:max_words, min(8, floor((window.end - window.start) * 2.5)))

    case fit_window(fallback, speak, rewrite, opts) do
      {:ok, fitted, clip, adjustment} ->
        {:ok, Map.put(fitted, :allow_ducking, true), clip, adjustment}

      result ->
        result
    end
  end

  defp ducking_fallback(_cue, _speak, _rewrite, reason, _opts), do: {:skip, reason}

  defp prepare(cue, _budget, _rewrite, nil, attempts), do: {:ok, cue, attempts}
  defp prepare(cue, _budget, _rewrite, _estimate, 0), do: {:ok, cue, 0}

  defp prepare(cue, budget, rewrite, estimate, attempts) do
    predicted = estimate.(cue.text)

    if predicted["estimated_seconds"] > budget * 1.2 + 0.25,
      do: prepare_shorter(cue, budget, rewrite, estimate, attempts, predicted),
      else: {:ok, cue, attempts}
  end

  defp prepare_shorter(cue, budget, rewrite, estimate, attempts, predicted) do
    literal = literal_candidate(cue)

    if literal && estimate.(literal)["estimated_seconds"] <= budget do
      {:ok, %{cue | text: literal}, attempts}
    else
      rewrite_preflight(cue, budget, rewrite, estimate, attempts, predicted)
    end
  end

  defp rewrite_preflight(cue, budget, rewrite, estimate, attempts, predicted) do
    limit = max(1, floor(budget * predicted["words_per_second"] * 0.9))

    case request_rewrite(rewrite, cue.text, budget, limit, predicted) do
      {:ok, text} ->
        text = String.trim(text)
        # Estimates alone must not remove an otherwise valid event.
        if valid_rewrite?(cue, text, limit) and text != cue.text,
          do: prepare(%{cue | text: text}, budget, rewrite, estimate, attempts - 1),
          else: {:ok, cue, attempts - 1}

      {:skip, _reason} ->
        {:ok, cue, attempts - 1}

      error ->
        error
    end
  end

  # A primary text card can fit verbatim even when a combined description with
  # framing and later imagery does not. Measure that candidate before rewriting.
  defp shorten(cue, _original, budget, speak, _rewrite, 0) do
    case fit_required_text(cue, budget, speak) do
      {:skip, _} -> {:skip, "speech_too_long"}
      result -> result
    end
  end

  defp shorten(cue, original, budget, speak, rewrite, attempts) do
    case fit_required_text(cue, budget, speak) do
      {:skip, _} -> rewrite_shorter(cue, original, budget, speak, rewrite, attempts)
      result -> result
    end
  end

  defp fit_required_text(cue, budget, speak) do
    case literal_candidate(cue) do
      nil -> {:skip, "no_literal_candidate"}
      text -> fit_rewrite(%{cue | text: text}, budget, speak)
    end
  end

  defp literal_candidate(%{kind: "text", on_screen_text: required} = cue)
       when is_binary(required) and required != "" do
    if required != cue.text and not Regex.match?(~r/^[\d\s.,:]+$/u, required) and
         MapSet.subset?(numbers(cue.text), numbers(required)),
       do: required
  end

  defp literal_candidate(_), do: nil

  defp rewrite_shorter(cue, original, budget, speak, rewrite, attempts) do
    measured_rate = word_count(cue.text) / max(seconds(original), 0.1)
    max_words = min(Map.get(cue, :max_words, 1_000), ceil(budget * measured_rate * 0.85))

    if max_words < 1 do
      {:skip, "no_safe_time"}
    else
      rewrite_and_fit(
        cue,
        budget,
        max_words,
        speak,
        rewrite,
        attempts - 1,
        measurement(cue.text, original)
      )
    end
  end

  defp rewrite_and_fit(cue, budget, max_words, speak, rewrite, retries, measured) do
    with {:ok, text} <- request_rewrite(rewrite, cue.text, budget, max_words, measured) do
      text = String.trim(text)

      result =
        if valid_rewrite?(cue, text, max_words),
          do: measure_rewrite(%{cue | text: text}, budget, speak),
          else: {:skip, "no_fitting_rewrite"}

      case result do
        {:too_long, measured} when retries > 0 and max_words > 1 ->
          next_limit =
            min(max_words - 1, max(1, floor(budget * measured["words_per_second"] * 0.9)))

          rewrite_and_fit(cue, budget, next_limit, speak, rewrite, retries - 1, measured)

        {:too_long, _} ->
          {:skip, "speech_too_long"}

        _ ->
          result
      end
    end
  end

  defp request_rewrite(rewrite, text, budget, max_words, measured) do
    feedback =
      Map.merge(measured, %{"available_seconds" => budget, "target_max_words" => max_words})

    result =
      if is_function(rewrite, 4),
        do: rewrite.(text, budget, max_words, feedback),
        else: rewrite.(text, budget, max_words)

    # Malformed model output affects this cue. Transport/service failures retain
    # their retryable error so the flow's normal retry policy can handle them.
    case result do
      {:error, reason} when reason in @rewrite_response_errors -> {:skip, "rewrite_#{reason}"}
      _ -> result
    end
  end

  defp measurement(text, clip) do
    duration = seconds(clip)

    %{
      "duration_source" => "measured_audio",
      "attempted_text" => text,
      "measured_seconds" => duration,
      "words_per_second" => word_count(text) / max(duration, 0.1),
      "pace" => "moderate"
    }
  end

  defp valid_rewrite?(cue, text, max_words) do
    # The word target estimates timing, not grammar. Let a complete phrase keep
    # its articles/prepositions; synthesized duration remains the hard limit.
    text != "" and word_count(text) <= max(max_words, word_count(cue.text)) and
      MapSet.subset?(numbers(cue.text), numbers(text)) and required_text_present?(cue, text)
  end

  defp required_text_present?(cue, text) do
    case Map.get(cue, :on_screen_text) do
      required when is_binary(required) and required != "" ->
        String.contains?(normalize_text(text), normalize_text(required))

      _ ->
        true
    end
  end

  @doc "Essential visible text absent from both the narration and original spoken content."
  def missing_text(required, narration, transcript) do
    spoken = normalize_text(narration <> " " <> transcript)

    Enum.filter(required, fn text ->
      is_binary(text) and String.trim(text) != "" and
        not String.contains?(spoken, normalize_text(text))
    end)
  end

  defp numbers(text), do: Regex.scan(~r/\d+(?:[.,:]\d+)*/, text) |> List.flatten() |> MapSet.new()

  defp normalize_text(text),
    do: text |> String.replace(~r/\s+/u, " ") |> String.downcase() |> String.trim()

  defp fit_rewrite(cue, budget, speak) do
    case measure_rewrite(cue, budget, speak) do
      {:too_long, _} -> {:skip, "speech_too_long"}
      result -> result
    end
  end

  defp measure_rewrite(cue, budget, speak) do
    with {:ok, clip} <- speak.(cue.text, :moderate) do
      cond do
        fits?(cue.text, clip, budget) -> {:ok, cue, clip, "shortened"}
        seconds(clip) <= budget * @max_speedup -> try_faster(cue, clip, budget, speak)
        true -> {:too_long, measurement(cue.text, clip)}
      end
    end
  end

  defp try_faster(cue, clip, budget, speak) do
    case faster(cue, clip, budget, speak) do
      {:skip, "speech_too_long"} -> {:too_long, measurement(cue.text, clip)}
      result -> result
    end
  end

  defp faster(cue, original, budget, speak) do
    with {:ok, clip} <- speak.(cue.text, :fast) do
      if fits?(cue.text, clip, budget) and
           seconds(original) / max(seconds(clip), 0.001) <= @max_speedup do
        {:ok, cue, clip, "shortened_faster"}
      else
        {:skip, "speech_too_long"}
      end
    end
  end

  defp fits?(_text, clip, budget) do
    duration = seconds(clip)
    # Written word counts vary by language and do not measure delivery speed.
    # Natural synthesis is accepted on duration; requested speedups stay capped.
    duration > 0 and duration <= budget
  end

  defp seconds(clip), do: byte_size(clip) / (2 * Wav.sample_rate())
  defp word_count(text), do: text |> String.split(~r/\s+/u, trim: true) |> length()
end
