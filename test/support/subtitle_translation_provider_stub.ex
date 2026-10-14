defmodule MaveCore.TestSupport.SubtitleTranslationProviderStub do
  @moduledoc false

  def translate(transcription, opts) do
    send(self(), {:subtitle_translation_requested, transcription, opts})

    case Process.get(:subtitle_translation_response, :ok) do
      :ok ->
        segments =
          Enum.map(
            transcription.segments,
            &%{&1 | text: "Translated " <> &1.text, start: 0.0, end: 0.1}
          )

        {:ok, %{text: "Translated", language: opts[:target_language], segments: segments}}

      response ->
        response
    end
  end
end
