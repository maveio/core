defmodule MaveCore.Transcription.Mistral do
  @moduledoc false

  @endpoint "https://api.mistral.ai/v1/audio/transcriptions"
  @default_model "voxtral-mini-2602"
  @pool_timeout_ms 30_000
  @receive_timeout_ms 30 * 60 * 1000

  def transcribe(audio_body, opts \\ []) when is_binary(audio_body) do
    with {:ok, api_key} <- fetch_api_key(),
         {:ok, response} <- request_transcription(audio_body, api_key, opts),
         {:ok, transcription} <- normalize_response(response.body) do
      {:ok, transcription}
    else
      {:error, _reason} = error ->
        error
    end
  end

  def transcribe_url(file_url, opts \\ []) when is_binary(file_url) do
    with {:ok, api_key} <- fetch_api_key(),
         {:ok, response} <- request_transcription_url(file_url, api_key, opts),
         {:ok, transcription} <- normalize_response(response.body) do
      {:ok, transcription}
    else
      {:error, _reason} = error ->
        error
    end
  end

  defp fetch_api_key do
    case System.get_env("MISTRAL_API_KEY") do
      api_key when is_binary(api_key) and api_key != "" -> {:ok, api_key}
      _ -> {:error, :mistral_api_key_missing}
    end
  end

  defp request_transcription(audio_body, api_key, opts) do
    model = transcription_model()
    filename = Keyword.get(opts, :filename, "audio.mp3")
    content_type = Keyword.get(opts, :content_type, "audio/mpeg")

    multipart =
      [
        {"file", {audio_body, filename: filename, content_type: content_type}},
        {"model", model},
        {"timestamp_granularities", "segment"}
      ]

    request(multipart, api_key, :form_multipart)
  end

  defp request_transcription_url(file_url, api_key, _opts) do
    model = transcription_model()

    body = %{
      "file_url" => file_url,
      "model" => model,
      "timestamp_granularities" => ["segment"]
    }

    request(body, api_key, :json)
  end

  defp request(body, api_key, body_option) do
    options =
      [
        headers: [
          {"authorization", "Bearer #{api_key}"},
          {"accept", "application/json"}
        ],
        finch: [pool_timeout: @pool_timeout_ms],
        receive_timeout: @receive_timeout_ms,
        retry: :transient,
        max_retries: 3
      ]
      |> Keyword.put(body_option, body)

    case Req.post(@endpoint, options) do
      {:ok, %{status: status} = response} when status in 200..299 -> {:ok, response}
      {:ok, %{status: status, body: body}} -> {:error, {:mistral_request_failed, status, body}}
      {:error, reason} -> {:error, {:mistral_request_failed, reason}}
    end
  end

  defp transcription_model do
    case System.get_env("MISTRAL_TRANSCRIPTION_MODEL") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> @default_model
          trimmed -> trimmed
        end

      _ ->
        @default_model
    end
  end

  defp normalize_response(%{"text" => text} = body) when is_binary(text) do
    {:ok,
     %{
       text: String.trim(text),
       language: normalize_language(Map.get(body, "language")),
       segments: normalize_segments(Map.get(body, "segments", []))
     }}
  end

  defp normalize_response(body), do: {:error, {:mistral_invalid_response, body}}

  defp normalize_segments(segments) when is_list(segments) do
    segments
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn segment ->
      %{
        start: parse_float(Map.get(segment, "start")),
        end: parse_float(Map.get(segment, "end")),
        text: segment |> Map.get("text", "") |> to_string() |> String.trim()
      }
    end)
    |> Enum.filter(fn segment ->
      is_number(segment.start) and is_number(segment.end) and segment.text != ""
    end)
  end

  defp normalize_segments(_), do: []

  defp normalize_language(language) when is_binary(language) do
    language
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> String.downcase(trimmed)
    end
  end

  defp normalize_language(_), do: nil

  defp parse_float(value) when is_float(value), do: value
  defp parse_float(value) when is_integer(value), do: value * 1.0

  defp parse_float(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  defp parse_float(_), do: nil
end
