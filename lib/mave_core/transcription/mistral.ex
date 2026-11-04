defmodule MaveCore.Transcription.Mistral do
  @moduledoc false

  @endpoint "https://api.mistral.ai/v1/audio/transcriptions"
  @default_model "voxtral-mini-2602"
  @pool_timeout_ms 30_000
  @receive_timeout_ms 30 * 60 * 1000

  def transcribe(audio_body, opts \\ []) when is_binary(audio_body) do
    model = transcription_model()
    granularity = timestamp_granularity(model, opts)

    with {:ok, api_key} <- fetch_api_key(),
         {:ok, response} <- request_transcription(audio_body, api_key, opts, model, granularity),
         {:ok, transcription} <- normalize_response(response.body, granularity) do
      {:ok, transcription}
    else
      {:error, _reason} = error ->
        error
    end
  end

  def transcribe_url(file_url, opts \\ []) when is_binary(file_url) do
    model = transcription_model()
    granularity = timestamp_granularity(model, opts)

    with {:ok, api_key} <- fetch_api_key(),
         {:ok, response} <- request_transcription_url(file_url, api_key, model, granularity),
         {:ok, transcription} <- normalize_response(response.body, granularity) do
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

  defp request_transcription(audio_body, api_key, opts, model, granularity) do
    filename = Keyword.get(opts, :filename, "audio.mp3")
    content_type = Keyword.get(opts, :content_type, "audio/mpeg")

    multipart =
      [
        {"file", {audio_body, filename: filename, content_type: content_type}},
        {"model", model},
        {"timestamp_granularities", granularity}
      ]

    request(multipart, api_key, :form_multipart)
  end

  defp request_transcription_url(file_url, api_key, model, granularity) do
    body = %{
      "file_url" => file_url,
      "model" => model,
      "timestamp_granularities" => [granularity]
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

  # Word timestamps are supported by the pinned V2 model, but not by Voxtral 3.
  # Unknown model overrides retain the existing segment-only request.
  defp timestamp_granularity(model, opts) do
    case Keyword.get(opts, :timestamp_granularity) do
      value when value in [:word, "word"] -> "word"
      value when value in [:segment, "segment"] -> "segment"
      _ -> if model == @default_model, do: "word", else: "segment"
    end
  end

  defp normalize_response(%{"text" => text} = body, granularity) when is_binary(text) do
    segments = normalize_segments(Map.get(body, "segments", []))
    words = response_words(body, granularity)

    # With word granularity, Mistral can put individual words in `segments`.
    # Keep a full-text fallback envelope instead of exposing one-word cues.
    segments =
      if granularity == "word" and words != [] and not match?([_ | _], body["words"]) do
        [%{start: hd(words).start, end: List.last(words).end, text: String.trim(text)}]
      else
        segments
      end

    {:ok,
     %{
       text: String.trim(text),
       language: normalize_language(Map.get(body, "language")),
       segments: segments,
       words: words
     }}
  end

  defp normalize_response(body, _granularity), do: {:error, {:mistral_invalid_response, body}}

  defp response_words(body, granularity) do
    entries =
      case body["words"] do
        [_ | _] = words -> words
        _ -> if(granularity == "word", do: body["segments"], else: [])
      end

    if is_list(entries) do
      entries
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn entry ->
        %{
          word: to_string(entry["word"] || entry["text"] || "") |> String.trim(),
          start: parse_float(entry["start"]),
          end: parse_float(entry["end"])
        }
      end)
      |> Enum.filter(&valid_word?/1)
    else
      []
    end
  end

  defp valid_word?(entry) do
    is_number(entry.start) and is_number(entry.end) and entry.start >= 0 and
      entry.end >= entry.start and entry.word != "" and not String.match?(entry.word, ~r/\s/u)
  end

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
