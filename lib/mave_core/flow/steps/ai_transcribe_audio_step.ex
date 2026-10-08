defmodule MaveCore.Flow.Steps.AiTranscribeAudioStep do
  @moduledoc """
  Produces subtitle artifacts from transcription inputs.

  This step is intentionally input-driven for now:
  - `run_input["transcription_vtt"]` can provide raw VTT
  - `run_input["transcription_text"]` generates a simple single-cue VTT
  - `run_input["transcription_segments"]` can provide a list of `%{"start","end","text"}`
  """
  @behaviour MaveCore.Flow.Step

  alias MaveCore.Embeds.SettingsSerializer
  alias MaveCore.Flow.Steps.Support, as: StepSupport
  alias MaveCore.Languages
  alias MaveCore.Media.Storage
  alias MaveCore.Transcription.LanguageDetector

  @language_stopwords %{
    "nl" => ~w(
      de het een en van voor met dat die dit op aan als ook niet wel naar je jij we wij
      te om maar zijn is was wordt door bij uit over nog dan hier daar
    ),
    "en" => ~w(
      the a and of for with that this on in to is are was were be by from at it not
      as you we they your our their have has had
    ),
    "de" => ~w(
      der die das und ist nicht ein eine mit von auf zu im den dem des für aus auch
      wir sie ich du
    ),
    "fr" => ~w(
      le la les de des et est pour avec dans sur que qui un une du au aux pas nous vous
    ),
    "es" => ~w(
      el la los las de del y es para con que en un una por no se como
    )
  }

  @impl true
  def run(step_definition, context) do
    run_input = Map.get(context, :run_input, %{})
    params = Map.get(step_definition, "params", %{})
    source_output = Map.get(Map.get(context, :dependency_outputs, %{}), "source", %{})
    inspect_output = Map.get(Map.get(context, :dependency_outputs, %{}), "inspect_media", %{})

    transcode_audio_output =
      Map.get(Map.get(context, :dependency_outputs, %{}), "transcode_audio", %{})

    step_id = Map.get(step_definition, "id", "transcribe_audio")

    space_hash = Map.get(source_output, "space_hash") || Map.get(run_input, "space_hash")
    embed_hash = Map.get(source_output, "embed_hash") || Map.get(run_input, "embed_hash")
    version = Map.get(source_output, "version") || Map.get(run_input, "version", 0)
    region = Map.get(run_input, "region")
    requested_language = normalize_optional_language(Map.get(run_input, "transcription_language"))
    strict? = StepSupport.strict_enabled?(params, run_input, "ai_transcribe_audio_strict")
    storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter, Storage)

    transcription_provider =
      Application.get_env(
        :mave_core,
        :transcription_provider,
        MaveCore.Transcription.Mistral
      )

    bucket = Storage.bucket_for_space(space_hash, region)

    with {:ok, space_hash} <- StepSupport.require_binary(space_hash, :space_hash),
         {:ok, embed_hash} <- StepSupport.require_binary(embed_hash, :embed_hash),
         {:ok, subtitle_body, subtitle_json, mode, mode_meta, detected_language,
          transcription_text} <-
           build_subtitle_body(
             run_input,
             inspect_output,
             transcode_audio_output,
             storage_adapter,
             transcription_provider,
             bucket,
             region,
             requested_language
           ),
         language =
           subtitle_language(
             detected_language,
             requested_language,
             transcode_audio_output,
             transcription_text
           ),
         label = normalize_label(Map.get(run_input, "transcription_label"), language),
         {:ok, key} <- build_subtitle_key(embed_hash, version, language),
         {:ok, uri} <- put_subtitle(storage_adapter, bucket, key, subtitle_body, region),
         {:ok, json_output} <-
           maybe_put_subtitle_json(
             storage_adapter,
             bucket,
             embed_hash,
             version,
             language,
             subtitle_json,
             region
           ) do
      size = byte_size(subtitle_body)

      subtitle = %{
        "id" => language,
        "language" => language,
        "label" => label,
        "path" => uri,
        "src" => uri,
        "file_size" => size
      }

      output =
        %{
          "status" => "ok",
          "step_type" => "ai.transcribe_audio",
          "mode" => mode,
          "step_id" => step_id,
          "language" => language,
          "subtitle_key" => key,
          "subtitle_uri" => uri,
          "subtitle_json_key" => json_output["subtitle_json_key"],
          "subtitle_json_uri" => json_output["subtitle_json_uri"],
          "subtitle_default_json_key" => json_output["subtitle_default_json_key"],
          "subtitle_default_json_uri" => json_output["subtitle_default_json_uri"],
          "subtitle" => subtitle,
          "subtitles" => [subtitle]
        }
        |> Map.merge(mode_meta)
        |> Map.put("transcription_language", language)

      artifacts =
        [
          %{
            name: "subtitle_#{language}",
            uri: uri,
            media_type: "text/vtt",
            size_bytes: size,
            metadata: %{
              "type" => "subtitle",
              "language" => language,
              "space_hash" => space_hash,
              "embed_hash" => embed_hash,
              "version" => StepSupport.normalize_version(version)
            }
          }
        ] ++ subtitle_json_artifacts(json_output, language, size, space_hash, embed_hash, version)

      {:ok, output, artifacts}
    else
      {:error, reason} when strict? ->
        {:error, {:ai_transcribe_audio_failed, reason}}

      {:error, reason} ->
        {:ok, unavailable_output(step_id, reason), []}
    end
  end

  defp build_subtitle_body(
         run_input,
         inspect_output,
         transcode_audio_output,
         storage_adapter,
         transcription_provider,
         bucket,
         region,
         requested_language
       ) do
    cond do
      is_binary(run_input["transcription_vtt"]) and run_input["transcription_vtt"] != "" ->
        {:ok, run_input["transcription_vtt"], nil, "input_vtt", %{}, requested_language, nil}

      is_list(run_input["transcription_segments"]) ->
        with {:ok, vtt_body} <- segments_to_vtt(run_input["transcription_segments"]) do
          transcript_text = transcript_text_from_segments(run_input["transcription_segments"])
          {:ok, vtt_body, nil, "input_segments", %{}, requested_language, transcript_text}
        end

      is_binary(run_input["transcription_text"]) and run_input["transcription_text"] != "" ->
        duration =
          parse_float(run_input["duration"]) ||
            parse_float(inspect_output["duration"]) ||
            5.0

        vtt_body =
          [
            "WEBVTT\n\n",
            format_time(0.0),
            " --> ",
            format_time(max(duration, 0.5)),
            "\n",
            String.trim(run_input["transcription_text"]),
            "\n"
          ]
          |> IO.iodata_to_binary()

        {:ok, vtt_body, nil, "input_text", %{}, requested_language,
         run_input["transcription_text"]}

      true ->
        build_provider_subtitle_body(
          transcode_audio_output,
          inspect_output,
          storage_adapter,
          transcription_provider,
          bucket,
          region,
          requested_language
        )
    end
  end

  defp build_provider_subtitle_body(
         transcode_audio_output,
         inspect_output,
         storage_adapter,
         transcription_provider,
         bucket,
         region,
         requested_language
       ) do
    with {:ok, audio_key} <- transcode_audio_key(transcode_audio_output),
         {:ok, transcription, transcription_input} <-
           transcribe_audio(
             storage_adapter,
             transcription_provider,
             bucket,
             audio_key,
             region,
             requested_language
           ),
         {:ok, vtt_body} <- transcription_to_vtt(transcription, inspect_output),
         {:ok, subtitle_json} <- transcription_to_json(transcription) do
      language =
        normalize_optional_language(transcription[:language] || requested_language)

      meta =
        transcription
        |> provider_mode_meta(transcription_provider)
        |> Map.put("transcription_input", transcription_input)

      {:ok, vtt_body, subtitle_json, "mistral", meta, language, transcription[:text]}
    end
  end

  defp transcribe_audio(
         storage_adapter,
         transcription_provider,
         bucket,
         audio_key,
         region,
         requested_language
       ) do
    opts = [
      filename: Path.basename(audio_key),
      content_type: content_type_for_path(audio_key),
      language: requested_language
    ]

    case transcribe_audio_url(transcription_provider, bucket, audio_key, opts) do
      {:ok, transcription} ->
        {:ok, transcription, "url"}

      {:error, _reason} ->
        with {:ok, audio_body} <- fetch_audio_body(storage_adapter, bucket, audio_key, region),
             {:ok, transcription} <- transcription_provider.transcribe(audio_body, opts) do
          {:ok, transcription, "body"}
        end
    end
  end

  defp transcribe_audio_url(transcription_provider, bucket, audio_key, opts) do
    if function_exported?(transcription_provider, :transcribe_url, 2) do
      case SettingsSerializer.storage_object_url(bucket, audio_key) do
        audio_url when is_binary(audio_url) and audio_url != "" ->
          transcription_provider.transcribe_url(audio_url, opts)

        _ ->
          {:error, :missing_public_transcription_audio_url}
      end
    else
      {:error, :transcription_provider_url_unsupported}
    end
  end

  defp transcription_to_vtt(%{segments: [%{} | _] = segments}, _inspect_output) do
    segments_to_vtt(segments)
  end

  defp transcription_to_vtt(%{text: text}, inspect_output) when is_binary(text) and text != "" do
    duration = parse_float(inspect_output["duration"]) || 5.0

    vtt_body =
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

    {:ok, vtt_body}
  end

  defp transcription_to_vtt(_transcription, _inspect_output) do
    {:error, :empty_transcription_response}
  end

  defp transcription_to_json(%{text: text} = transcription) when is_binary(text) do
    segments =
      transcription
      |> Map.get(:segments, [])
      |> normalize_transcription_segments()
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

    {:ok, Jason.encode!(%{"text" => String.trim(text), "segments" => segments})}
  end

  defp transcription_to_json(_), do: {:error, :empty_transcription_response}

  defp normalize_transcription_segments(segments) when is_list(segments) do
    segments
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn segment ->
      start_time = parse_float(segment[:start] || segment["start"]) || 0.0
      end_time = parse_float(segment[:end] || segment["end"]) || start_time + 0.5
      text = to_string(segment[:text] || segment["text"] || "") |> String.trim()
      %{start: start_time, end: max(end_time, start_time + 0.1), text: text}
    end)
    |> Enum.filter(&(&1.text != ""))
  end

  defp normalize_transcription_segments(_), do: []

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

  defp provider_mode_meta(%{language: language, text: text, segments: segments}, provider) do
    %{
      "provider" => inspect(provider),
      "transcription_language" => normalize_optional_language(language),
      "transcription_text" => text,
      "transcription_segments_count" => length(segments || [])
    }
  end

  defp transcode_audio_key(%{"key" => key}) when is_binary(key) and key != "", do: {:ok, key}

  defp transcode_audio_key(%{"uri" => uri}) when is_binary(uri) and uri != "" do
    case parse_s3_uri(uri) do
      {_bucket, key} when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :missing_transcode_audio_key}
    end
  end

  defp transcode_audio_key(_), do: {:error, :missing_transcription_input}

  defp fetch_audio_body(storage_adapter, bucket, key, region) do
    case storage_adapter.get(bucket, key, region) do
      {:ok, body} when is_binary(body) -> {:ok, body}
      {:ok, body} when is_list(body) -> {:ok, IO.iodata_to_binary(body)}
      {:ok, _body} -> {:error, :invalid_transcription_audio}
      {:error, reason} -> {:error, {:transcription_audio_fetch_failed, reason}}
    end
  end

  defp parse_s3_uri("s3://" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [bucket, key] -> {bucket, key}
      _ -> {nil, nil}
    end
  end

  defp parse_s3_uri(_), do: {nil, nil}

  defp content_type_for_path(path) when is_binary(path) do
    case String.downcase(Path.extname(path)) do
      ".mp3" -> "audio/mpeg"
      ".aac" -> "audio/aac"
      ".wav" -> "audio/wav"
      ".m4a" -> "audio/mp4"
      ".flac" -> "audio/flac"
      _ -> "application/octet-stream"
    end
  end

  defp segments_to_vtt(segments) do
    valid_segments =
      segments
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn segment ->
        start_time = parse_float(segment["start"]) || parse_float(segment[:start]) || 0.0
        end_time = parse_float(segment["end"]) || parse_float(segment[:end]) || start_time + 1.0
        text = to_string(segment["text"] || segment[:text] || "") |> String.trim()
        %{start: start_time, end: max(end_time, start_time + 0.1), text: text}
      end)
      |> Enum.filter(&(is_binary(&1.text) and &1.text != ""))

    if valid_segments == [] do
      {:error, :empty_transcription_segments}
    else
      body =
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

      {:ok, body}
    end
  end

  defp transcript_text_from_segments(segments) when is_list(segments) do
    segments
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn segment ->
      segment["text"] || segment[:text] || ""
    end)
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp transcript_text_from_segments(_), do: nil

  defp format_time(seconds) do
    total_ms = trunc(max(seconds, 0.0) * 1000)
    hours = div(total_ms, 3_600_000)
    minutes = div(rem(total_ms, 3_600_000), 60_000)
    secs = div(rem(total_ms, 60_000), 1000)
    millis = rem(total_ms, 1000)
    :io_lib.format("~2..0B:~2..0B:~2..0B.~3..0B", [hours, minutes, secs, millis]) |> to_string()
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

  defp put_subtitle(storage_adapter, bucket, key, body, region) do
    case storage_adapter.put_public(bucket, key, body, "text/vtt", region) do
      {:ok, _body} -> {:ok, "s3://#{bucket}/#{key}"}
      {:error, reason} -> {:error, {:subtitle_upload_failed, reason}}
    end
  end

  defp maybe_put_subtitle_json(
         _storage_adapter,
         _bucket,
         _embed_hash,
         _version,
         _language,
         nil,
         _region
       ) do
    {:ok,
     %{
       "subtitle_json_key" => nil,
       "subtitle_json_uri" => nil,
       "subtitle_default_json_key" => nil,
       "subtitle_default_json_uri" => nil
     }}
  end

  defp maybe_put_subtitle_json(
         storage_adapter,
         bucket,
         embed_hash,
         version,
         language,
         body,
         region
       ) do
    with {:ok, subtitle_json_key} <- build_subtitle_json_key(embed_hash, version, language),
         {:ok, subtitle_json_uri} <-
           put_subtitle_json(storage_adapter, bucket, subtitle_json_key, body, region),
         {:ok, default_json_key} <- build_default_subtitle_json_key(embed_hash, version),
         {:ok, default_json_uri} <-
           put_subtitle_json(storage_adapter, bucket, default_json_key, body, region) do
      {:ok,
       %{
         "subtitle_json_key" => subtitle_json_key,
         "subtitle_json_uri" => subtitle_json_uri,
         "subtitle_default_json_key" => default_json_key,
         "subtitle_default_json_uri" => default_json_uri
       }}
    end
  end

  defp put_subtitle_json(storage_adapter, bucket, key, body, region) do
    case storage_adapter.put_public(bucket, key, body, "application/json", region) do
      {:ok, _body} -> {:ok, "s3://#{bucket}/#{key}"}
      {:error, reason} -> {:error, {:subtitle_json_upload_failed, reason}}
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

  defp build_default_subtitle_json_key(embed_hash, version) do
    with {:ok, embed_hash} <- StepSupport.require_binary(embed_hash, :embed_hash) do
      key =
        if StepSupport.normalize_version(version) > 0 do
          "#{embed_hash}/v#{StepSupport.normalize_version(version)}/subtitle.json"
        else
          "#{embed_hash}/subtitle.json"
        end

      {:ok, key}
    end
  end

  defp subtitle_json_artifacts(
         %{
           "subtitle_json_uri" => nil,
           "subtitle_default_json_uri" => nil
         },
         _language,
         _size,
         _space_hash,
         _embed_hash,
         _version
       ),
       do: []

  defp subtitle_json_artifacts(json_output, language, _size, space_hash, embed_hash, version) do
    version = StepSupport.normalize_version(version)

    base_metadata = %{
      "type" => "subtitle_json",
      "language" => language,
      "space_hash" => space_hash,
      "embed_hash" => embed_hash,
      "version" => version
    }

    [
      %{
        name: "subtitle_#{language}_json",
        uri: json_output["subtitle_json_uri"],
        media_type: "application/json",
        size_bytes: nil,
        metadata: Map.put(base_metadata, "default", false)
      },
      %{
        name: "subtitle_json",
        uri: json_output["subtitle_default_json_uri"],
        media_type: "application/json",
        size_bytes: nil,
        metadata: Map.put(base_metadata, "default", true)
      }
    ]
  end

  defp normalize_optional_language(language) when is_binary(language) do
    language
    |> String.trim()
    |> case do
      "" ->
        nil

      trimmed ->
        trimmed
        |> String.downcase()
        |> String.replace("_", "-")
        |> case do
          "un" -> nil
          "und" -> nil
          normalized -> normalized
        end
    end
  end

  defp normalize_optional_language(_), do: nil

  defp subtitle_language(
         detected_language,
         requested_language,
         transcode_audio_output,
         transcription_text
       ) do
    normalize_optional_language(detected_language) ||
      detect_language_from_text(transcription_text) ||
      normalize_optional_language(requested_language) ||
      transcode_audio_language(transcode_audio_output) ||
      "en"
  end

  defp transcode_audio_language(%{"audio_tracks" => tracks}) when is_list(tracks) do
    tracks
    |> Enum.find_value(fn
      %{"default" => true, "language" => language} -> normalize_optional_language(language)
      _ -> nil
    end) ||
      Enum.find_value(tracks, fn
        %{"language" => language} -> normalize_optional_language(language)
        _ -> nil
      end)
  end

  defp transcode_audio_language(_), do: nil

  defp detect_language_from_text(text) when is_binary(text) do
    LanguageDetector.detect(text) || heuristic_language_from_text(text)
  end

  defp detect_language_from_text(_), do: nil

  defp heuristic_language_from_text(text) when is_binary(text) do
    words =
      text
      |> String.downcase()
      |> String.replace(~r/[^[:alpha:]\s'-]/u, " ")
      |> String.split(~r/\s+/, trim: true)

    if length(words) < 3 do
      nil
    else
      {language, score} =
        @language_stopwords
        |> Enum.map(fn {language, stopwords} ->
          count = Enum.count(words, &(&1 in stopwords))
          {language, count}
        end)
        |> Enum.max_by(fn {_language, count} -> count end, fn -> {nil, 0} end)

      if score > 0, do: language, else: nil
    end
  end

  defp heuristic_language_from_text(_), do: nil

  defp normalize_label(label, _language) when is_binary(label) and label != "" do
    String.trim(label)
  end

  defp normalize_label(_label, language) do
    language
    |> String.split("-")
    |> List.first()
    |> Languages.spoken_language()
    |> Kernel.||(String.upcase(language))
  end

  defp parse_float(value) when is_float(value), do: value
  defp parse_float(value) when is_integer(value), do: value * 1.0

  defp parse_float(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  defp parse_float(_), do: nil

  defp unavailable_output(step_id, reason) do
    %{
      "status" => "unavailable",
      "step_type" => "ai.transcribe_audio",
      "mode" => "failed",
      "step_id" => step_id,
      "error" => inspect(reason)
    }
  end
end
