defmodule MaveCore.Languages do
  @moduledoc false

  @spoken_languages [
    {"Pashto", "af"},
    {"Amharic", "am"},
    {"Arabic", "ar"},
    {"Samoan", "as"},
    {"Azerbaijani", "az"},
    {"Bosnian", "ba"},
    {"Belarusian", "be"},
    {"Bulgarian", "bg"},
    {"Bengali", "bn"},
    {"Tibetan", "bo"},
    {"Portuguese", "br"},
    {"Bosnian", "bs"},
    {"Catalan", "ca"},
    {"Czech", "cs"},
    {"Welsh", "cy"},
    {"Danish", "da"},
    {"German", "de"},
    {"Greek", "el"},
    {"English", "en"},
    {"Spanish", "es"},
    {"Estonian", "et"},
    {"Basque", "eu"},
    {"Persian", "fa"},
    {"Finnish", "fi"},
    {"Faroese", "fo"},
    {"French", "fr"},
    {"Galician", "gl"},
    {"Gujarati", "gu"},
    {"Haitian Creole", "ha"},
    {"Hawaiian", "haw"},
    {"Hindi", "hi"},
    {"Croatian", "hr"},
    {"Haitian Creole", "ht"},
    {"Hungarian", "hu"},
    {"Armenian", "hy"},
    {"Indonesian", "id"},
    {"Icelandic", "is"},
    {"Italian", "it"},
    {"Hebrew", "iw"},
    {"Japanese", "ja"},
    {"Javanese", "jw"},
    {"Georgian", "ka"},
    {"Kazakh", "kk"},
    {"Khmer", "km"},
    {"Kannada", "kn"},
    {"Korean", "ko"},
    {"Latin", "la"},
    {"Luxembourgish", "lb"},
    {"Lingala", "ln"},
    {"Lao", "lo"},
    {"Lithuanian", "lt"},
    {"Latvian", "lv"},
    {"Malagasy", "mg"},
    {"Maori", "mi"},
    {"Macedonian", "mk"},
    {"Malayalam", "ml"},
    {"Mongolian", "mn"},
    {"Marathi", "mr"},
    {"Malay", "ms"},
    {"Maltese", "mt"},
    {"Burmese", "my"},
    {"Nepali", "ne"},
    {"Dutch", "nl"},
    {"Norwegian Nynorsk", "nn"},
    {"Norwegian", "no"},
    {"Occitan", "oc"},
    {"Panjabi", "pa"},
    {"Polish", "pl"},
    {"Pashto", "ps"},
    {"Portuguese", "pt"},
    {"Romanian", "ro"},
    {"Russian", "ru"},
    {"Sanskrit", "sa"},
    {"Sindhi", "sd"},
    {"Sinhala", "si"},
    {"Slovak", "sk"},
    {"Slovenian", "sl"},
    {"Shona", "sn"},
    {"Somali", "so"},
    {"Albanian", "sq"},
    {"Serbian", "sr"},
    {"Sundanese", "su"},
    {"Swedish", "sv"},
    {"Swahili", "sw"},
    {"Tamil", "ta"},
    {"Telugu", "te"},
    {"Tajik", "tg"},
    {"Thai", "th"},
    {"Turkmen", "tk"},
    {"Tagalog", "tl"},
    {"Turkish", "tr"},
    {"Tatar", "tt"},
    {"Ukrainian", "uk"},
    {"Urdu", "ur"},
    {"Uzbek", "uz"},
    {"Vietnamese", "vi"},
    {"Yiddish", "yi"},
    {"Yoruba", "yo"},
    {"Chinese", "zh"}
  ]

  # ISO 639-2 terminology and bibliographic codes, mapped to the language codes
  # supported by the media database. Hebrew and Javanese retain its legacy codes.
  # Source: https://www.loc.gov/standards/iso639-2/php/code_list.php
  @media_language_aliases %{
    "afr" => "af",
    "amh" => "am",
    "ara" => "ar",
    "asm" => "as",
    "aze" => "az",
    "bak" => "ba",
    "bel" => "be",
    "bul" => "bg",
    "ben" => "bn",
    "bod" => "bo",
    "tib" => "bo",
    "bre" => "br",
    "bos" => "bs",
    "cat" => "ca",
    "ces" => "cs",
    "cze" => "cs",
    "cym" => "cy",
    "wel" => "cy",
    "dan" => "da",
    "deu" => "de",
    "ger" => "de",
    "ell" => "el",
    "gre" => "el",
    "eng" => "en",
    "spa" => "es",
    "est" => "et",
    "eus" => "eu",
    "baq" => "eu",
    "fas" => "fa",
    "per" => "fa",
    "fin" => "fi",
    "fao" => "fo",
    "fra" => "fr",
    "fre" => "fr",
    "glg" => "gl",
    "guj" => "gu",
    "hau" => "ha",
    "haw" => "haw",
    "hin" => "hi",
    "hrv" => "hr",
    "hat" => "ht",
    "hun" => "hu",
    "hye" => "hy",
    "arm" => "hy",
    "ind" => "id",
    "isl" => "is",
    "ice" => "is",
    "ita" => "it",
    "heb" => "iw",
    "jpn" => "ja",
    "jav" => "jw",
    "kat" => "ka",
    "geo" => "ka",
    "kaz" => "kk",
    "khm" => "km",
    "kan" => "kn",
    "kor" => "ko",
    "lat" => "la",
    "ltz" => "lb",
    "lin" => "ln",
    "lao" => "lo",
    "lit" => "lt",
    "lav" => "lv",
    "mlg" => "mg",
    "mri" => "mi",
    "mao" => "mi",
    "mkd" => "mk",
    "mac" => "mk",
    "mal" => "ml",
    "mon" => "mn",
    "mar" => "mr",
    "msa" => "ms",
    "may" => "ms",
    "mlt" => "mt",
    "mya" => "my",
    "bur" => "my",
    "nep" => "ne",
    "nld" => "nl",
    "dut" => "nl",
    "nno" => "nn",
    "nor" => "no",
    "oci" => "oc",
    "pan" => "pa",
    "pol" => "pl",
    "pus" => "ps",
    "por" => "pt",
    "ron" => "ro",
    "rum" => "ro",
    "rus" => "ru",
    "san" => "sa",
    "snd" => "sd",
    "sin" => "si",
    "slk" => "sk",
    "slo" => "sk",
    "slv" => "sl",
    "sna" => "sn",
    "som" => "so",
    "sqi" => "sq",
    "alb" => "sq",
    "srp" => "sr",
    "sun" => "su",
    "swe" => "sv",
    "swa" => "sw",
    "tam" => "ta",
    "tel" => "te",
    "tgk" => "tg",
    "tha" => "th",
    "tuk" => "tk",
    "tgl" => "tl",
    "tur" => "tr",
    "tat" => "tt",
    "ukr" => "uk",
    "urd" => "ur",
    "uzb" => "uz",
    "vie" => "vi",
    "yid" => "yi",
    "yor" => "yo",
    "zho" => "zh",
    "chi" => "zh"
  }
  @media_language_codes MapSet.new(Enum.map(@spoken_languages, &elem(&1, 1)))

  # Unknown and unsupported languages must not reach the database enum. Preserve
  # Hawaiian's supported three-letter code and accept regional language tags.
  def normalize_media_language(nil), do: nil

  def normalize_media_language(language) when is_atom(language),
    do: normalize_media_language(Atom.to_string(language))

  def normalize_media_language(language) when is_binary(language) do
    base =
      language
      |> String.trim()
      |> String.downcase()
      |> String.split(~r/[-_]/, parts: 2)
      |> hd()

    code = Map.get(@media_language_aliases, base, base)
    code = Map.get(%{"he" => "iw", "jv" => "jw"}, code, code)

    if MapSet.member?(@media_language_codes, code), do: code
  end

  def normalize_media_language(_language), do: nil

  def spoken_languages, do: @spoken_languages

  def spoken_language(nil), do: nil

  def spoken_language(language) when is_atom(language) do
    language
    |> Atom.to_string()
    |> spoken_language()
  end

  def spoken_language(language) when is_binary(language) do
    case Enum.find(@spoken_languages, fn {_label, code} -> code == language end) do
      {label, _code} -> label
      nil -> nil
    end
  end

  def spoken_language_code(nil), do: nil

  def spoken_language_code(language) when is_atom(language) do
    language
    |> Atom.to_string()
    |> spoken_language_code()
  end

  def spoken_language_code(language) when is_binary(language) do
    normalized = language |> String.trim() |> String.downcase()

    case Enum.find(@spoken_languages, fn {label, code} ->
           String.downcase(label) == normalized or String.downcase(code) == normalized
         end) do
      {_label, code} -> code
      nil -> nil
    end
  end
end
