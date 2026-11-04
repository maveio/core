defmodule MaveCore.AudioDescription do
  @moduledoc """
  Audio description: per video, a full-mix MP3 (the video's audio with spoken
  descriptions of what is on screen) and a descriptions VTT in the original language.

  New runs describe the picture directly in the detected language, falling back
  to English when no language is known. See `docs/audio_description.md`.
  """

  alias MaveCore.Spaces
  alias MaveCore.Spaces.Space

  @source_language "en"
  @languages ["en", "nl"]
  @default_max_seconds 600

  def source_language, do: @source_language
  def languages, do: @languages

  @doc """
  The `audio_description` run input for a new flow run in `space`, or `nil` when
  the space doesn't get audio descriptions.
  """
  def run_input(%Space{} = space) do
    if Spaces.audio_description_active?(space),
      do: %{"languages" => ["original"], "fallback_language" => "en"},
      else: nil
  end

  def run_input(_space), do: nil

  @doc "Languages requested by a run, or `[]` when it has no audio description."
  def requested_languages(%{"audio_description" => %{"languages" => languages}})
      when is_list(languages) do
    languages = Enum.filter(languages, &is_binary/1)

    cond do
      languages == [] -> []
      "original" in languages -> ["original"]
      true -> Enum.uniq([@source_language | languages])
    end
  end

  def requested_languages(_run_input), do: []

  @doc "Original language from transcription or run metadata, with a configurable fallback."
  def original_language(run_input, outputs, fallback_language \\ nil) do
    candidates = [
      get_in(outputs, ["transcribe_audio", "transcription_language"]),
      get_in(outputs, ["transcribe_audio", "language"]),
      run_input["language"]
    ]

    fallback =
      normalize_language(fallback_language) ||
        normalize_language(get_in(run_input, ["audio_description", "fallback_language"])) ||
        @source_language

    Enum.find_value(candidates, fallback, &normalize_language/1)
  end

  defp normalize_language(value) when is_binary(value) do
    value = value |> String.trim() |> String.downcase() |> String.split(~r/[-_]/) |> hd()
    if value =~ ~r/^[a-z]{2,3}$/ and value not in ["und", "zxx"], do: value
  end

  defp normalize_language(_), do: nil

  def requested?(run_input), do: requested_languages(run_input) != []

  @doc "Longest video that gets an audio description, in seconds."
  def max_seconds do
    case config(:max_seconds, System.get_env("MAVE_AUDIO_DESCRIPTION_MAX_SECONDS")) do
      value when is_integer(value) and value > 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {seconds, ""} when seconds > 0 -> seconds
          _ -> @default_max_seconds
        end

      _ ->
        @default_max_seconds
    end
  end

  @doc "Object key prefix of a video version (`<embed>/vN` or `<embed>`)."
  def version_prefix(embed_hash, version) when is_integer(version) and version > 0,
    do: "#{embed_hash}/v#{version}"

  def version_prefix(embed_hash, _version), do: embed_hash

  @doc "Private working objects (stills, cues, speech clips) of a video version."
  def work_prefix(embed_hash, version),
    do: "#{version_prefix(embed_hash, version)}/audio_description"

  def audio_filename(language), do: "audio_description_#{language}.mp3"
  def vtt_filename(language), do: "descriptions_#{language}.vtt"

  @doc false
  def config(key, default \\ nil) do
    :mave_core
    |> Application.get_env(:audio_description, [])
    |> Keyword.get(key, default)
  end
end
