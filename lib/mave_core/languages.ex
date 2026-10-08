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
