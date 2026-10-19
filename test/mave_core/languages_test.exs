defmodule MaveCore.LanguagesTest do
  use ExUnit.Case, async: true

  alias MaveCore.Languages

  test "maps ISO 639-2 terminology and bibliographic codes to supported media languages" do
    for {codes, expected} <- [
          {~w(jpn), "ja"},
          {~w(eng), "en"},
          {~w(hin), "hi"},
          {~w(spa), "es"},
          {~w(nld dut), "nl"},
          {~w(deu ger), "de"},
          {~w(fra fre), "fr"},
          {~w(zho chi), "zh"},
          {~w(ces cze), "cs"},
          {~w(ell gre), "el"},
          {~w(fas per), "fa"},
          {~w(bod tib), "bo"},
          {~w(mya bur), "my"},
          {~w(ron rum), "ro"},
          {~w(slk slo), "sk"},
          {~w(heb he), "iw"},
          {~w(jav jv), "jw"}
        ],
        code <- codes do
      assert Languages.normalize_media_language(code) == expected
    end
  end

  test "preserves supported codes including Hawaiian and normalizes regional tags" do
    for {_label, code} <- Languages.spoken_languages() do
      assert Languages.normalize_media_language(code) == code
    end

    assert Languages.normalize_media_language(" JPN-JP ") == "ja"
    assert Languages.normalize_media_language("nld_BE") == "nl"
    assert Languages.normalize_media_language("pt-BR") == "pt"
    assert Languages.normalize_media_language(:jpn) == "ja"
  end

  test "does not guess codes by truncating unknown, undefined or unsupported languages" do
    for code <- [nil, "", "un", "und", "zxx", "mul", "xxx", "jp", "enough", "sah", "aa", 123] do
      assert Languages.normalize_media_language(code) == nil
    end
  end
end
