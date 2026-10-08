defmodule MaveCore.Transcription.MistralTranslator do
  @moduledoc false

  @endpoint "https://api.mistral.ai/v1/chat/completions"
  @default_model "mistral-medium-latest"
  @segment_batch_size 10
  @text_chunk_max_chars 12_000
  @pool_timeout_ms 30_000
  @receive_timeout_ms 10 * 60 * 1000

  def translate(transcription, opts \\ []) when is_map(transcription) do
    target_language =
      opts
      |> Keyword.get(:target_language, "en")
      |> normalize_language()
      |> Kernel.||("en")

    source_language =
      opts
      |> Keyword.get(:source_language)
      |> normalize_language()

    with {:ok, api_key} <- fetch_api_key(),
         {:ok, normalized} <- normalize_transcription(transcription) do
      translate_normalized(normalized, api_key, source_language, target_language)
    end
  end

  defp translate_normalized(%{segments: [_ | _] = segments}, api_key, source_language, target) do
    with {:ok, translated_segments} <-
           segments
           |> Enum.chunk_every(@segment_batch_size)
           |> translate_segment_batches(api_key, source_language, target) do
      {:ok,
       %{
         text: transcript_text_from_segments(translated_segments),
         language: target,
         segments: translated_segments
       }}
    end
  end

  defp translate_normalized(%{text: text}, api_key, source_language, target)
       when is_binary(text) and text != "" do
    with {:ok, translated_text} <- translate_text(text, api_key, source_language, target) do
      {:ok, %{text: translated_text, language: target, segments: []}}
    end
  end

  defp translate_normalized(_normalized, _api_key, _source_language, _target) do
    {:error, :empty_translation_input}
  end

  defp translate_segment_batches(batches, api_key, source_language, target) do
    Enum.reduce_while(batches, {:ok, []}, fn batch, {:ok, acc} ->
      case translate_segment_batch(batch, api_key, source_language, target) do
        {:ok, translated_batch} -> {:cont, {:ok, acc ++ translated_batch}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp translate_segment_batch(batch, api_key, source_language, target) do
    entries =
      batch
      |> Enum.with_index()
      |> Enum.map(fn {segment, index} ->
        %{"id" => index, "text" => segment.text}
      end)

    with {:ok, content} <-
           request_chat(segment_prompt(entries, source_language, target), api_key,
             max_tokens: 8_000
           ),
         {:ok, translated_entries} <- parse_segment_translation(content) do
      translated_by_id =
        Map.new(translated_entries, fn entry ->
          {entry.id, String.trim(entry.text)}
        end)

      translated_segments =
        batch
        |> Enum.with_index()
        |> Enum.map(fn {segment, index} ->
          %{
            start: segment.start,
            end: segment.end,
            text: Map.get(translated_by_id, index, segment.text)
          }
        end)

      {:ok, translated_segments}
    end
  end

  defp translate_text(text, api_key, source_language, target) do
    text
    |> chunk_text()
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
      case request_chat(text_prompt(chunk, source_language, target), api_key, max_tokens: 8_000) do
        {:ok, translated_chunk} -> {:cont, {:ok, [String.trim(translated_chunk) | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, chunks} -> {:ok, chunks |> Enum.reverse() |> Enum.join(" ") |> String.trim()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_api_key do
    case System.get_env("MISTRAL_API_KEY") do
      api_key when is_binary(api_key) and api_key != "" -> {:ok, api_key}
      _ -> {:error, :mistral_api_key_missing}
    end
  end

  defp request_chat(prompt, api_key, opts) do
    body = %{
      "model" => @default_model,
      "messages" => [%{"role" => "user", "content" => prompt}],
      "max_tokens" => Keyword.get(opts, :max_tokens, 8_000),
      "temperature" => 0.1
    }

    options = [
      headers: [
        {"authorization", "Bearer #{api_key}"},
        {"accept", "application/json"}
      ],
      json: body,
      finch: [pool_timeout: @pool_timeout_ms],
      receive_timeout: @receive_timeout_ms,
      retry: :transient,
      max_retries: 3
    ]

    case Req.post(@endpoint, options) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        chat_content(body)

      {:ok, %{status: status, body: body}} ->
        {:error, {:mistral_translation_failed, status, body}}

      {:error, reason} ->
        {:error, {:mistral_translation_failed, reason}}
    end
  end

  defp chat_content(%{"choices" => [%{"message" => %{"content" => content}} | _]})
       when is_binary(content) do
    {:ok, String.trim(content)}
  end

  defp chat_content(body), do: {:error, {:mistral_translation_invalid_response, body}}

  defp segment_prompt(entries, source_language, target_language) do
    """
    Translate each subtitle segment to #{language_name(target_language)}.

    Rules:
    - Return only a JSON array.
    - Keep each id unchanged.
    - Each returned object must contain "id" and "text".
    - Preserve meaning, tone, punctuation, and readable subtitle length.
    - Do not add explanations or markdown.

    Source language: #{source_language || "auto"}
    Segments:
    #{Jason.encode!(entries)}
    """
  end

  defp text_prompt(text, source_language, target_language) do
    """
    Translate the following subtitle text to #{language_name(target_language)}.

    Rules:
    - Return only the translation.
    - Preserve meaning, tone, punctuation, and paragraph breaks.
    - Do not add explanations or markdown.

    Source language: #{source_language || "auto"}
    Text:
    #{text}
    """
  end

  defp parse_segment_translation(content) when is_binary(content) do
    with {:ok, parsed} <- parse_json_content(content),
         entries <- normalize_translation_entries(parsed),
         true <- entries != [] do
      {:ok, entries}
    else
      _ -> parse_numbered_lines(content)
    end
  end

  defp parse_json_content(content) do
    content
    |> strip_markdown_fence()
    |> Jason.decode()
    |> case do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, _reason} ->
        content
        |> extract_json_array()
        |> case do
          nil -> {:error, :invalid_json}
          json -> Jason.decode(json)
        end
    end
  end

  defp normalize_translation_entries(%{"segments" => segments}) when is_list(segments),
    do: normalize_translation_entries(segments)

  defp normalize_translation_entries(entries) when is_list(entries) do
    entries
    |> Enum.flat_map(fn
      %{"id" => id, "text" => text} ->
        normalize_translation_entry(id, text)

      %{"id" => id, "translation" => text} ->
        normalize_translation_entry(id, text)

      %{"index" => id, "text" => text} ->
        normalize_translation_entry(id, text)

      _entry ->
        []
    end)
  end

  defp normalize_translation_entries(_), do: []

  defp normalize_translation_entry(id, text) when is_binary(text) do
    case parse_integer(id) do
      nil -> []
      parsed_id -> [%{id: parsed_id, text: text}]
    end
  end

  defp normalize_translation_entry(_id, _text), do: []

  defp parse_numbered_lines(content) do
    entries =
      ~r/^\s*\[(\d+)\]\s*(.+)$/m
      |> Regex.scan(content)
      |> Enum.flat_map(fn [_line, id, text] ->
        normalize_translation_entry(id, text)
      end)

    if entries == [], do: {:error, :translation_parse_failed}, else: {:ok, entries}
  end

  defp strip_markdown_fence(content) do
    content
    |> String.trim()
    |> String.replace(~r/^```(?:json)?\s*/i, "")
    |> String.replace(~r/\s*```$/i, "")
    |> String.trim()
  end

  defp extract_json_array(content) do
    case Regex.run(~r/\[[\s\S]*\]/, content) do
      [json] -> json
      _ -> nil
    end
  end

  defp chunk_text(text) when byte_size(text) <= @text_chunk_max_chars, do: [text]

  defp chunk_text(text) do
    text
    |> String.split(~r/(?<=[.!?])\s+/, trim: true)
    |> Enum.reduce([], fn sentence, chunks ->
      append_sentence_chunk(chunks, sentence)
    end)
    |> Enum.reverse()
  end

  defp append_sentence_chunk([], sentence), do: [sentence]

  defp append_sentence_chunk([current | rest], sentence) do
    candidate = current <> " " <> sentence

    if byte_size(candidate) <= @text_chunk_max_chars do
      [candidate | rest]
    else
      [sentence, current | rest]
    end
  end

  defp normalize_transcription(transcription) do
    text =
      transcription
      |> map_get(:text)
      |> normalize_text()

    segments =
      transcription
      |> map_get(:segments, [])
      |> normalize_segments()

    text = text || transcript_text_from_segments(segments)

    if is_binary(text) and text != "" do
      {:ok, %{text: text, segments: segments}}
    else
      {:error, :empty_translation_input}
    end
  end

  defp normalize_segments(segments) when is_list(segments) do
    segments
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn segment ->
      start_time = parse_float(map_get(segment, :start)) || 0.0
      end_time = parse_float(map_get(segment, :end)) || start_time + 0.5

      %{
        start: start_time,
        end: max(end_time, start_time + 0.1),
        text: normalize_text(map_get(segment, :text)) || ""
      }
    end)
    |> Enum.filter(&(&1.text != ""))
  end

  defp normalize_segments(_), do: []

  defp transcript_text_from_segments(segments) when is_list(segments) do
    segments
    |> Enum.map(& &1.text)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp normalize_text(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_text(_), do: nil

  defp language_name("en"), do: "English"
  defp language_name(language) when is_binary(language), do: language
  defp language_name(_), do: "English"

  defp normalize_language(language) when is_binary(language) do
    language
    |> String.trim()
    |> String.downcase()
    |> String.replace("_", "-")
    |> case do
      "" -> nil
      "un" -> nil
      "und" -> nil
      normalized -> normalized
    end
  end

  defp normalize_language(_), do: nil

  defp map_get(map, key, default \\ nil)

  defp map_get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp map_get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp map_get(_map, _key, default), do: default

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_integer(_), do: nil

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
