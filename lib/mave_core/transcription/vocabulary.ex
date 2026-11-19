defmodule MaveCore.Transcription.Vocabulary do
  @moduledoc "Space-specific spelling hints for subtitle generation."
  @term ~r/\A[\p{L}\p{N}][\p{L}\p{M}\p{N} &'’.+()\/®™#‐‑–-]*\z/u

  def parse(text) when is_binary(text) and byte_size(text) <= 16_000 do
    terms =
      text
      |> String.split(~r/\r\n|\n|\r/u)
      |> Enum.map(&(String.trim(&1) |> String.normalize(:nfc)))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq_by(&String.downcase/1)

    if valid?(terms), do: {:ok, terms}, else: {:error, :invalid_vocabulary}
  end

  def parse(_), do: {:error, :invalid_vocabulary}

  def valid?(terms) when is_list(terms) and length(terms) <= 25 do
    Enum.all?(terms, fn term ->
      is_binary(term) and String.valid?(term) and String.length(term) <= 80 and
        Regex.match?(@term, term)
    end)
  end

  def valid?(_), do: false

  def snapshot(%{automatic_subtitles_enabled: true, subtitle_vocabulary: terms}), do: terms
  def snapshot(_), do: []

  def matching(terms, texts) do
    if valid?(terms) do
      Enum.filter(terms, fn term ->
        pattern =
          Regex.compile!(
            "(?<![\\p{L}\\p{M}\\p{N}])" <> Regex.escape(term) <> "(?![\\p{L}\\p{M}\\p{N}])",
            "iu"
          )

        Enum.any?(texts, &Regex.match?(pattern, &1))
      end)
    else
      []
    end
  end
end
