defmodule MaveCore.Transcription.LanguageDetectorTest do
  use ExUnit.Case, async: true

  alias MaveCore.Transcription.LanguageDetector

  test "uses the configured provider and normalizes returned language codes" do
    Process.put(:language_detection_result, {:ok, "ita"})
    assert LanguageDetector.detect("  Un testo italiano.  ") == "it"
    assert_received {:language_detection_called, "Un testo italiano."}
  end

  test "accepts European languages beyond the audio model's published language list" do
    for code <- ~w(pl sv da fi cs el hu ro uk) do
      Process.put(:language_detection_result, {:ok, code})
      assert LanguageDetector.detect("Transcript sample") == code
    end
  end

  test "keeps uncertain, invalid and failed provider responses unknown" do
    for result <- [{:ok, nil}, {:ok, "und"}, {:ok, "invalid"}, {:error, :timeout}, :unexpected] do
      Process.put(:language_detection_result, result)
      assert LanguageDetector.detect("Transcript sample") == nil
    end
  end

  test "does not call the provider for empty or missing text" do
    for text <- ["", "   ", nil], do: assert(LanguageDetector.detect(text) == nil)
    refute_received {:language_detection_called, _}
  end
end
