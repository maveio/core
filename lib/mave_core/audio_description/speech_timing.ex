defmodule MaveCore.AudioDescription.SpeechTiming do
  @moduledoc "Local, approximate speech timing for avoiding clearly oversized synthesis requests."
  alias MaveCore.AudioDescription.Pronunciation

  @vowels ~r/[aeiouyáéíóúàèìòùäëïöü]+/iu
  @tokens ~r/\p{L}+|\d+(?:[.,:]\d+)*/u

  @doc "Estimate an edit relative to the published text's existing audio timing."
  def estimate_edit(text, original, duration, language) do
    text = editor_spoken_text(text)
    original = editor_spoken_text(original)

    cond do
      String.trim(text) == "" ->
        0.0

      text == original ->
        duration

      duration > 0 and String.trim(original) != "" ->
        original_estimate = estimate(original, language)["estimated_seconds"]
        edited_estimate = estimate(text, language)["estimated_seconds"]
        Float.round(duration * edited_estimate / original_estimate, 3)

      true ->
        estimate(text, language)["estimated_seconds"]
    end
  end

  @doc "Exclude typed time-label syntax from editor estimates without changing the saved text."
  def editor_spoken_text(text) do
    ~r/\[([0-9:.,-]*)(\]?)/u
    |> Regex.replace(text, fn full, value, closing ->
      if closing == "]" and not String.contains?(value, ":"), do: full, else: ""
    end)
    |> String.trim()
  end

  @doc "Estimate natural speech without a provider call; coefficients are heuristics, not measured voice rates."
  def estimate(text, language) do
    spoken = Pronunciation.for_speech(text, language)
    tokens = Regex.scan(@tokens, spoken) |> List.flatten()
    syllables = Enum.reduce(tokens, 0, &(&2 + syllables(&1)))

    pauses =
      length(Regex.scan(~r/[,;:]/u, spoken)) * 0.12 +
        length(Regex.scan(~r/[.!?](?:\s|$)/u, spoken)) * 0.18

    duration = max(length(tokens) / 2.7, syllables / 4.8) + pauses + 0.15

    %{
      "duration_source" => "heuristic_estimate",
      "attempted_text" => text,
      "estimated_seconds" => Float.round(duration, 3),
      "words_per_second" => length(String.split(text)) / max(duration, 0.1)
    }
  end

  defp syllables(token) do
    cond do
      Regex.match?(~r/^\d/u, token) -> numeric_syllables(token)
      String.length(token) in 2..5 and token == String.upcase(token) -> String.length(token)
      true -> max(1, length(Regex.scan(@vowels, token)))
    end
  end

  # Estimate numeric groups separately so a long reference, decimal or time is
  # not counted as one ordinary word. Spoken number forms vary by language.
  defp numeric_syllables(token) do
    token
    |> String.split(~r/[.,:]/u)
    |> Enum.reduce(0, fn digits, total -> total + numeric_group_syllables(digits) end)
  end

  defp numeric_group_syllables(digits) do
    case String.length(digits) do
      1 -> if digits == "7", do: 2, else: 1
      2 -> 3
      3 -> 5
      4 -> 7
      count -> count * 1.5
    end
  end
end
