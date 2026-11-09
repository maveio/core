defmodule MaveCore.AudioDescription.PronunciationTest do
  use ExUnit.Case, async: true
  alias MaveCore.AudioDescription.Pronunciation

  test "Dutch URLs use Dutch letter names and separators" do
    assert Pronunciation.for_speech("Bekijk www.ab.nl.", "nl") ==
             "Bekijk wee wee wee punt aa bee punt en el."

    assert Pronunciation.for_speech("Lees ab.nl/blogs", "nl-NL") ==
             "Lees aa bee punt en el schuine streep blogs"

    assert Pronunciation.for_speech("https://example.org/start", "nl") ==
             "example punt oo er gee schuine streep start"
  end

  test "other languages and ordinary words or numbers are preserved" do
    assert Pronunciation.for_speech("Open Access kost 3.14 euro.", "nl") ==
             "Open Access kost 3.14 euro."

    assert Pronunciation.for_speech("See www.ab.nl", "en") == "See www.ab.nl"
  end
end
