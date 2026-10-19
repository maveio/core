defmodule MaveCore.TestSupport.LanguageDetectionProviderStub do
  @moduledoc false

  def detect(text) do
    send(self(), {:language_detection_called, text})
    Process.get(:language_detection_result, {:ok, nil})
  end
end
