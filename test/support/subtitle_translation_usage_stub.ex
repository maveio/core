defmodule MaveCore.TestSupport.SubtitleTranslationUsageStub do
  @moduledoc false

  def can_translate_subtitles?(_space, request) do
    send(self(), {:subtitle_usage_checked, request})
    if Process.get(:allow_subtitle_translation, true), do: :ok, else: {:error, :limit_reached}
  end
end
