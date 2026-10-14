defmodule MaveCore.Flow.Steps.SubtitleLoadTranslationSourceStep do
  @moduledoc false
  @behaviour MaveCore.Flow.Step
  alias MaveCore.Transcription.SubtitleTranslations

  @impl true
  def run(_definition, %{run_input: input}) do
    case SubtitleTranslations.load_source(input) do
      {:ok, output} -> {:ok, output, []}
      {:error, reason} -> {:error, {:subtitle_source_failed, reason}}
    end
  end
end
