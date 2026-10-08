defmodule MaveCore.Transcription.LanguageDetector do
  @moduledoc false

  alias MaveCore.Languages

  def detect(text) when is_binary(text) do
    text
    |> String.trim()
    |> case do
      "" ->
        nil

      trimmed ->
        with {:module, Whatlangex} <- Code.ensure_loaded(Whatlangex),
             {:ok, result} <- Whatlangex.detect(trimmed),
             iso3 when is_binary(iso3) <- Map.get(result, :lang) || Map.get(result, "lang"),
             language_name when is_binary(language_name) <- Whatlangex.code_to_eng_name(iso3),
             iso2 when is_binary(iso2) <- Languages.spoken_language_code(language_name) do
          iso2
        else
          _ -> nil
        end
    end
  end

  def detect(_), do: nil
end
