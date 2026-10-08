defmodule MaveCore.Flow.Steps.AiTranslateSubtitlesStep do
  @moduledoc """
  Produces English subtitle artifacts from an existing transcription JSON output.
  """
  @behaviour MaveCore.Flow.Step

  alias MaveCore.Flow.Steps.Support, as: StepSupport
  alias MaveCore.Languages
  alias MaveCore.Media.Storage
  alias MaveCore.Transcription.LanguageDetector

  @target_language "en"

  @impl true
  def run(step_definition, context) do
    run_input = Map.get(context, :run_input, %{})
    params = Map.get(step_definition, "params", %{})
    dependency_outputs = Map.get(context, :dependency_outputs, %{})
    source_output = Map.get(dependency_outputs, "source", %{})
    transcribe_output = Map.get(dependency_outputs, "transcribe_audio", %{})
    step_id = Map.get(step_definition, "id", "translate_subtitles")

    target_language =
      normalize_optional_language(Map.get(params, "target_language")) || @target_language

    space_hash = Map.get(source_output, "space_hash") || Map.get(run_input, "space_hash")
    embed_hash = Map.get(source_output, "embed_hash") || Map.get(run_input, "embed_hash")
    version = Map.get(source_output, "version") || Map.get(run_input, "version", 0)
    region = Map.get(run_input, "region")
    strict? = StepSupport.strict_enabled?(params, run_input, "ai_translate_subtitles_strict")
    storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter, Storage)

    translation_provider =
      Application.get_env(
        :mave_core,
        :subtitle_translation_provider,
        MaveCore.Transcription.MistralTranslator
      )

    bucket = Storage.bucket_for_space(space_hash, region)
    source_language = source_language_from_output(transcribe_output)

    with {:ok, space_hash} <- StepSupport.require_binary(space_hash, :space_hash),
         {:ok, embed_hash} <- StepSupport.require_binary(embed_hash, :embed_hash),
         :ok <- transcribe_output_ready(transcribe_output),
         :ok <- continue_unless_target_language(source_language, target_language),
         {:ok, transcription} <-
           load_transcription(storage_adapter, bucket, transcribe_output, region),
         source_language = source_language || detect_language_from_text(transcription.text),
         :ok <- continue_unless_target_language(source_language, target_language),
         {:ok, translation} <-
           translate(translation_provider, transcription, source_language, target_language),
         {:ok, subtitle_body} <-
           translation_to_vtt(translation, transcription_duration(transcription)),
         {:ok, subtitle_json} <- translation_to_json(translation),
         {:ok, key} <- build_subtitle_key(embed_hash, version, target_language),
         {:ok, uri} <- put_subtitle(storage_adapter, bucket, key, subtitle_body, region),
         {:ok, json_key} <- build_subtitle_json_key(embed_hash, version, target_language),
         {:ok, json_uri} <-
           put_subtitle_json(storage_adapter, bucket, json_key, subtitle_json, region) do
      size = byte_size(subtitle_body)
      json_size = byte_size(subtitle_json)
      label = label_for_language(target_language)

      subtitle = %{
        "id" => target_language,
        "language" => target_language,
        "label" => label,
        "path" => uri,
        "src" => uri,
        "file_size" => size
      }

      output = %{
        "status" => "ok",
        "step_type" => "ai.translate_subtitles",
        "mode" => translation_mode(translation_provider),
        "provider" => inspect(translation_provider),
        "step_id" => step_id,
        "source_language" => source_language,
        "target_language" => target_language,
        "language" => target_language,
        "subtitle_key" => key,
        "subtitle_uri" => uri,
        "subtitle_json_key" => json_key,
        "subtitle_json_uri" => json_uri,
        "subtitle_default_json_key" => nil,
        "subtitle_default_json_uri" => nil,
        "subtitle" => subtitle,
        "subtitles" => [subtitle],
        "translation_text" => translation.text,
        "translation_segments_count" => length(translation.segments)
      }

      artifacts = [
        %{
          name: "subtitle_#{target_language}",
          uri: uri,
          media_type: "text/vtt",
          size_bytes: size,
          metadata: %{
            "type" => "subtitle",
            "language" => target_language,
            "source_language" => source_language,
            "space_hash" => space_hash,
            "embed_hash" => embed_hash,
            "version" => StepSupport.normalize_version(version)
          }
        },
        %{
          name: "subtitle_#{target_language}_json",
          uri: json_uri,
          media_type: "application/json",
          size_bytes: json_size,
          metadata: %{
            "type" => "subtitle_json",
            "language" => target_language,
            "source_language" => source_language,
            "space_hash" => space_hash,
            "embed_hash" => embed_hash,
            "version" => StepSupport.normalize_version(version),
            "default" => false
          }
        }
      ]

      {:ok, output, artifacts}
    else
      {:skip_translation, reason, skipped_source_language} ->
        {:ok, skipped_output(step_id, reason, skipped_source_language, target_language), []}

      {:error, reason} when strict? ->
        {:error, {:ai_translate_subtitles_failed, reason}}

      {:error, reason} ->
        {:ok, unavailable_output(step_id, reason, source_language, target_language), []}
    end
  end

  defp transcribe_output_ready(%{"status" => "ok"}), do: :ok

  defp transcribe_output_ready(%{"status" => status}),
    do: {:error, {:transcription_unavailable, status}}

  defp transcribe_output_ready(_), do: {:error, :missing_transcription_output}

  defp continue_unless_target_language(nil, _target_language), do: :ok

  defp continue_unless_target_language(source_language, target_language) do
    if same_base_language?(source_language, target_language) do
      {:skip_translation, "source language already matches target", source_language}
    else
      :ok
    end
  end

  defp load_transcription(storage_adapter, bucket, transcribe_output, region) do
    case subtitle_json_key(transcribe_output) do
      {:ok, key} ->
        with {:ok, body} <- fetch_json_body(storage_adapter, bucket, key, region),
             {:ok, decoded} <- decode_json_body(body),
             {:ok, transcription} <- normalize_transcription(decoded) do
          {:ok, transcription}
        else
          {:error, reason} -> {:error, {:translation_source_fetch_failed, reason}}
        end

      {:error, _reason} ->
        transcription_from_output_text(transcribe_output)
    end
  end

  defp fetch_json_body(storage_adapter, bucket, key, region) do
    case storage_adapter.get(bucket, key, region) do
      {:ok, body} when is_binary(body) -> {:ok, body}
      {:ok, body} when is_list(body) -> {:ok, IO.iodata_to_binary(body)}
      {:ok, body} when is_map(body) -> {:ok, body}
      {:ok, _body} -> {:error, :invalid_subtitle_json_body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_json_body(body) when is_map(body), do: {:ok, body}
  defp decode_json_body(body) when is_binary(body), do: Jason.decode(body)
  defp decode_json_body(_body), do: {:error, :invalid_subtitle_json_body}

  defp transcription_from_output_text(%{"transcription_text" => text}) when is_binary(text) do
    normalize_transcription(%{"text" => text, "segments" => []})
  end

  defp transcription_from_output_text(_output), do: {:error, :missing_transcription_json}

  defp subtitle_json_key(output) when is_map(output) do
    cond do
      is_binary(output["subtitle_json_key"]) and output["subtitle_json_key"] != "" ->
        {:ok, output["subtitle_json_key"]}

      is_binary(output["subtitle_default_json_key"]) and output["subtitle_default_json_key"] != "" ->
        {:ok, output["subtitle_default_json_key"]}

      true ->
        subtitle_json_uri_key(output["subtitle_json_uri"] || output["subtitle_default_json_uri"])
    end
  end

  defp subtitle_json_key(_), do: {:error, :missing_transcription_json}

  defp subtitle_json_uri_key("s3://" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [_bucket, key] when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :missing_transcription_json}
    end
  end

  defp subtitle_json_uri_key(_), do: {:error, :missing_transcription_json}

  defp translate(provider, transcription, source_language, target_language) do
    case provider.translate(transcription,
           source_language: source_language,
           target_language: target_language
         ) do
      {:ok, translation} -> normalize_translation(translation, target_language)
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_translation_response, other}}
    end
  end

  defp normalize_translation(translation, target_language) when is_map(translation) do
    text =
      translation
      |> map_get(:text)
      |> normalize_text()

    segments =
      translation
      |> map_get(:segments, [])
      |> normalize_segments()

    text = text || transcript_text_from_segments(segments)

    if is_binary(text) and text != "" do
      {:ok,
       %{
         text: text,
         language:
           normalize_optional_language(map_get(translation, :language)) || target_language,
         segments: segments
       }}
    else
      {:error, :empty_translation_response}
    end
  end

  defp normalize_translation(_translation, _target_language),
    do: {:error, :empty_translation_response}

  defp normalize_transcription(transcription) when is_map(transcription) do
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

  defp normalize_transcription(_), do: {:error, :empty_translation_input}

  defp translation_to_vtt(%{segments: [_ | _] = segments}, _fallback_duration) do
    segments_to_vtt(segments)
  end

  defp translation_to_vtt(%{text: text}, fallback_duration) when is_binary(text) and text != "" do
    duration = fallback_duration || 5.0

    [
      "WEBVTT\n\n",
      format_time(0.0),
      " --> ",
      format_time(max(duration, 0.5)),
      "\n",
      String.trim(text),
      "\n"
    ]
    |> IO.iodata_to_binary()
    |> then(&{:ok, &1})
  end

  defp translation_to_vtt(_translation, _fallback_duration),
    do: {:error, :empty_translation_response}

  defp translation_to_json(%{text: text, segments: segments}) when is_binary(text) do
    json_segments =
      segments
      |> Enum.with_index(1)
      |> Enum.map(fn {segment, index} ->
        %{
          "id" => index,
          "start" => segment.start,
          "end" => segment.end,
          "text" => segment.text,
          "words" => segment_words(segment)
        }
      end)

    {:ok, Jason.encode!(%{"text" => String.trim(text), "segments" => json_segments})}
  end

  defp translation_to_json(_), do: {:error, :empty_translation_response}

  defp segments_to_vtt(segments) do
    valid_segments =
      segments
      |> normalize_segments()
      |> Enum.filter(&(&1.text != ""))

    if valid_segments == [] do
      {:error, :empty_translation_segments}
    else
      [
        "WEBVTT\n\n",
        Enum.map(valid_segments, fn segment ->
          [
            format_time(segment.start),
            " --> ",
            format_time(segment.end),
            "\n",
            segment.text,
            "\n\n"
          ]
        end)
      ]
      |> IO.iodata_to_binary()
      |> then(&{:ok, &1})
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

  defp segment_words(%{text: text, start: start_time, end: end_time}) do
    words = String.split(text, ~r/\s+/, trim: true)
    duration = max(end_time - start_time, 0.001)

    case words do
      [] ->
        []

      words ->
        word_duration = duration / length(words)

        words
        |> Enum.with_index()
        |> Enum.map(fn {word, index} ->
          word_start = Float.round(start_time + word_duration * index, 3)
          word_end = Float.round(min(end_time, word_start + word_duration), 3)

          %{
            "start" => word_start,
            "end" => word_end,
            "word" => word
          }
        end)
    end
  end

  defp build_subtitle_key(embed_hash, version, language) do
    with {:ok, embed_hash} <- StepSupport.require_binary(embed_hash, :embed_hash),
         {:ok, language} <- StepSupport.require_binary(language, :language) do
      filename = "subtitle_#{language}.vtt"

      key =
        if StepSupport.normalize_version(version) > 0 do
          "#{embed_hash}/v#{StepSupport.normalize_version(version)}/#{filename}"
        else
          "#{embed_hash}/#{filename}"
        end

      {:ok, key}
    end
  end

  defp build_subtitle_json_key(embed_hash, version, language) do
    with {:ok, embed_hash} <- StepSupport.require_binary(embed_hash, :embed_hash),
         {:ok, language} <- StepSupport.require_binary(language, :language) do
      filename = "subtitle_#{language}.json"

      key =
        if StepSupport.normalize_version(version) > 0 do
          "#{embed_hash}/v#{StepSupport.normalize_version(version)}/#{filename}"
        else
          "#{embed_hash}/#{filename}"
        end

      {:ok, key}
    end
  end

  defp put_subtitle(storage_adapter, bucket, key, body, region) do
    case storage_adapter.put_public(bucket, key, body, "text/vtt", region) do
      {:ok, _body} -> {:ok, "s3://#{bucket}/#{key}"}
      {:error, reason} -> {:error, {:subtitle_upload_failed, reason}}
    end
  end

  defp put_subtitle_json(storage_adapter, bucket, key, body, region) do
    case storage_adapter.put_public(bucket, key, body, "application/json", region) do
      {:ok, _body} -> {:ok, "s3://#{bucket}/#{key}"}
      {:error, reason} -> {:error, {:subtitle_json_upload_failed, reason}}
    end
  end

  defp transcription_duration(%{segments: segments}) when is_list(segments) do
    segments
    |> Enum.map(& &1.end)
    |> Enum.filter(&is_number/1)
    |> Enum.max(fn -> nil end)
  end

  defp transcription_duration(_), do: nil

  defp source_language_from_output(output) when is_map(output) do
    normalize_optional_language(output["language"] || output["transcription_language"]) ||
      case output["subtitles"] do
        subtitles when is_list(subtitles) ->
          Enum.find_value(subtitles, fn
            %{"language" => language} -> normalize_optional_language(language)
            _ -> nil
          end)

        _ ->
          nil
      end
  end

  defp source_language_from_output(_), do: nil

  defp detect_language_from_text(text) when is_binary(text), do: LanguageDetector.detect(text)
  defp detect_language_from_text(_), do: nil

  defp same_base_language?(left, right) do
    base_language(left) == base_language(right)
  end

  defp base_language(language) when is_binary(language) do
    language
    |> String.split("-", parts: 2)
    |> List.first()
  end

  defp base_language(_), do: nil

  defp label_for_language(language) do
    language
    |> base_language()
    |> Languages.spoken_language()
    |> Kernel.||(String.upcase(language))
  end

  defp translation_mode(MaveCore.Transcription.MistralTranslator), do: "mistral"
  defp translation_mode(provider), do: inspect(provider)

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

  defp normalize_optional_language(language) when is_binary(language) do
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

  defp normalize_optional_language(_), do: nil

  defp format_time(seconds) do
    total_ms = trunc(max(seconds, 0.0) * 1000)
    hours = div(total_ms, 3_600_000)
    minutes = div(rem(total_ms, 3_600_000), 60_000)
    secs = div(rem(total_ms, 60_000), 1000)
    millis = rem(total_ms, 1000)
    :io_lib.format("~2..0B:~2..0B:~2..0B.~3..0B", [hours, minutes, secs, millis]) |> to_string()
  end

  defp map_get(map, key, default \\ nil)

  defp map_get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp map_get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp map_get(_map, _key, default), do: default

  defp parse_float(value) when is_float(value), do: value
  defp parse_float(value) when is_integer(value), do: value * 1.0

  defp parse_float(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  defp parse_float(_), do: nil

  defp skipped_output(step_id, reason, source_language, target_language) do
    %{
      "status" => "skipped",
      "step_type" => "ai.translate_subtitles",
      "mode" => "skipped",
      "step_id" => step_id,
      "source_language" => source_language,
      "target_language" => target_language,
      "reason" => reason
    }
  end

  defp unavailable_output(step_id, reason, source_language, target_language) do
    %{
      "status" => "unavailable",
      "step_type" => "ai.translate_subtitles",
      "mode" => "failed",
      "step_id" => step_id,
      "source_language" => source_language,
      "target_language" => target_language,
      "error" => inspect(reason)
    }
  end
end
