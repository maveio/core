defmodule MaveCore.Transcription.LanguageDetectorTest do
  use ExUnit.Case, async: true

  alias MaveCore.Transcription.LanguageDetector

  test "recognizes Italian independently of shared Spanish stopwords" do
    text =
      "La nostra azienda si occupa di offrire un servizio di qualità per tutte le persone che desiderano imparare qualcosa di nuovo."

    assert LanguageDetector.detect(text) == "it"
  end

  test "recognizes Spanish when there is enough evidence" do
    text =
      "Nuestra empresa ofrece un servicio de calidad para todas las personas que desean aprender algo nuevo y compartir sus experiencias con los demás."

    assert LanguageDetector.detect(text) == "es"
  end

  test "abstains on short ambiguous text and missing input" do
    for text <- ["ciao", "la de un", "12345", "", "   ", nil] do
      assert LanguageDetector.detect(text) == nil
    end
  end
end
