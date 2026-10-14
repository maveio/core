defmodule MaveCore.Flow.Steps.SubtitlePublishTranslationStep do
  @moduledoc false
  @behaviour MaveCore.Flow.Step
  alias MaveCore.Transcription.SubtitleTranslations

  @impl true
  def run(_definition, %{run_input: input, dependency_outputs: outputs}) do
    case SubtitleTranslations.publish(
           input,
           outputs["translate_subtitles"]
         ) do
      {:ok, subtitle} -> {:ok, %{"status" => "ok", "subtitle_id" => subtitle.id}, []}
      {:error, reason} -> {:error, {:subtitle_publication_failed, reason}}
    end
  end
end
