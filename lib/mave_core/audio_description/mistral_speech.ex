defmodule MaveCore.AudioDescription.MistralSpeech do
  @moduledoc """
  Text-to-speech with Voxtral on the Mistral API.

  Every language gets a voice in that language, because Voxtral keeps the accent
  of its voice prompt. Voices come from `MAVE_AUDIO_DESCRIPTION_VOICES`
  (`en:gb_jane_neutral,nl:voice_3145` by default); a language without one
  falls back to `MAVE_AUDIO_DESCRIPTION_VOICE`. Never clone voices from customer
  videos.
  """

  @endpoint "https://api.mistral.ai/v1/audio/speech"
  @default_model "voxtral-mini-tts-3-0"
  @default_voices "en:gb_jane_neutral,nl:voice_3145"
  @default_voice "gb_jane_neutral"
  @pool_timeout_ms 30_000
  @receive_timeout_ms 2 * 60 * 1000

  @doc "Speaks `text` in `language` and returns WAV bytes."
  def speak(text, language) when is_binary(text) and is_binary(language) do
    with {:ok, api_key} <- fetch_api_key() do
      body = %{
        "model" => env("MAVE_AUDIO_DESCRIPTION_TTS_MODEL", @default_model),
        "input" => text,
        "voice_id" => voice(language),
        "response_format" => "wav"
      }

      case Req.post(@endpoint,
             json: body,
             headers: [{"authorization", "Bearer #{api_key}"}, {"accept", "application/json"}],
             finch: [pool_timeout: @pool_timeout_ms],
             receive_timeout: @receive_timeout_ms,
             retry: :transient,
             max_retries: 3
           ) do
        {:ok, %{status: status, body: %{"audio_data" => audio}}}
        when status in 200..299 and is_binary(audio) ->
          decode_audio(audio)

        {:ok, %{status: status}} when status in 200..299 ->
          {:error, :empty_speech_audio}

        {:ok, %{status: status, body: body}} ->
          {:error, {:http_error, status, body |> inspect() |> String.slice(0, 600)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp decode_audio(audio) do
    case Base.decode64(audio, ignore: :whitespace) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_speech_audio}
    end
  end

  @doc "The voice for `language`: its exact tag, then its base language, then the fallback."
  def voice(language) do
    voices = voices()
    base = language |> String.split("-") |> hd()

    Map.get(voices, language) || Map.get(voices, base) ||
      env("MAVE_AUDIO_DESCRIPTION_VOICE", @default_voice)
  end

  defp voices do
    "MAVE_AUDIO_DESCRIPTION_VOICES"
    |> env(@default_voices)
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn pair ->
      case String.split(pair, ":", parts: 2) do
        [lang, voice] when lang != "" and voice != "" -> [{String.trim(lang), String.trim(voice)}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp fetch_api_key do
    case System.get_env("MISTRAL_API_KEY") do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :mistral_api_key_missing}
    end
  end

  defp env(name, default) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> String.trim(value)
      _ -> default
    end
  end
end
