defmodule MaveCore.Transcription.LanguageDetector do
  @moduledoc false

  alias MaveCore.Languages
  alias MaveCore.Transcription.MistralLanguageDetector

  def detect(text) when is_binary(text) do
    text = String.trim(text)

    if text == "" do
      nil
    else
      provider =
        Application.get_env(:mave_core, :language_detection_provider, MistralLanguageDetector)

      case provider.detect(text) do
        {:ok, language} -> Languages.normalize_media_language(language)
        _ -> nil
      end
    end
  end

  def detect(_text), do: nil
end
