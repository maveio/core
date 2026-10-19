defmodule MaveCore.Transcription.LanguageDetector do
  @moduledoc false

  alias MaveCore.Languages

  @minimum_confidence 0.8

  def detect(text) when is_binary(text) do
    text
    |> String.trim()
    |> case do
      "" ->
        nil

      trimmed ->
        with {:module, Whatlangex} <- Code.ensure_loaded(Whatlangex),
             %{lang: iso3, confidence: confidence} <- Whatlangex.detect(trimmed),
             true <- is_number(confidence) and confidence >= @minimum_confidence do
          Languages.normalize_media_language(iso3)
        else
          _ -> nil
        end
    end
  end

  def detect(_), do: nil
end
