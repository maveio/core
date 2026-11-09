defmodule MaveCore.AudioDescription.SpeechFit do
  @moduledoc "Fits complete spoken descriptions to reserved time windows without cutting audio."
  alias MaveCore.AudioDescription.Wav

  @max_speedup 1.15
  @max_words_per_second 3.5

  def fit(%{window: _} = cue, speak, rewrite) do
    case fit_window(cue, speak, rewrite) do
      {:skip, reason} -> ducking_fallback(cue, speak, rewrite, reason)
      result -> result
    end
  end

  def fit(cue, speak, _rewrite) do
    with {:ok, clip} <- speak.(cue.text, :moderate), do: {:ok, cue, clip, "legacy"}
  end

  defp fit_window(%{window: nil}, _speak, _rewrite), do: {:skip, "no_safe_time"}

  defp fit_window(%{window: window} = cue, speak, rewrite) do
    budget = window.end - window.start

    with true <- required_text_present?(cue, cue.text),
         {:ok, clip} <- speak.(cue.text, :moderate) do
      if fits?(cue.text, clip, budget) and word_count(cue.text) <= Map.get(cue, :max_words, 1_000) do
        {:ok, cue, clip, "original"}
      else
        shorten(cue, clip, budget, speak, rewrite)
      end
    else
      false -> {:skip, "missing_on_screen_text"}
      error -> error
    end
  end

  defp ducking_fallback(%{priority: 3, duck_window: window} = cue, speak, rewrite, reason)
       when reason in ["no_safe_time", "no_fitting_rewrite", "speech_too_long"] do
    fallback =
      cue
      |> Map.put(:window, window)
      |> Map.put(:max_words, min(8, floor((window.end - window.start) * 2.5)))

    case fit_window(fallback, speak, rewrite) do
      {:ok, fitted, clip, adjustment} ->
        {:ok, Map.put(fitted, :allow_ducking, true), clip, adjustment}

      result ->
        result
    end
  end

  defp ducking_fallback(_cue, _speak, _rewrite, reason), do: {:skip, reason}

  defp shorten(cue, original, budget, speak, rewrite) do
    measured_rate = word_count(cue.text) / max(seconds(original), 0.1)
    max_words = min(Map.get(cue, :max_words, 1_000), ceil(budget * measured_rate * 0.85))

    if max_words < 1 do
      {:skip, "no_safe_time"}
    else
      rewrite_and_fit(cue, budget, max_words, speak, rewrite, 1)
    end
  end

  defp rewrite_and_fit(cue, budget, max_words, speak, rewrite, retries) do
    with {:ok, text} <- rewrite.(cue.text, budget, max_words) do
      text = String.trim(text)

      result =
        if valid_rewrite?(cue, text, max_words),
          do: fit_rewrite(%{cue | text: text}, budget, speak),
          else: {:skip, "no_fitting_rewrite"}

      case result do
        {:skip, "speech_too_long"} when retries > 0 and max_words > 1 ->
          rewrite_and_fit(cue, budget, max_words - 1, speak, rewrite, retries - 1)

        _ ->
          result
      end
    end
  end

  defp valid_rewrite?(cue, text, max_words) do
    text != "" and word_count(text) <= max_words and
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
    with {:ok, clip} <- speak.(cue.text, :moderate) do
      cond do
        fits?(cue.text, clip, budget) -> {:ok, cue, clip, "shortened"}
        seconds(clip) <= budget * @max_speedup -> faster(cue, clip, budget, speak)
        true -> {:skip, "speech_too_long"}
      end
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

  defp fits?(text, clip, budget) do
    duration = seconds(clip)
    duration > 0 and duration <= budget and word_count(text) / duration <= @max_words_per_second
  end

  defp seconds(clip), do: byte_size(clip) / (2 * Wav.sample_rate())
  defp word_count(text), do: text |> String.split(~r/\s+/u, trim: true) |> length()
end
