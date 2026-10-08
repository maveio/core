defmodule MaveCore.Flow.Steps.MediaBuildHlsMasterStep do
  @moduledoc """
  Builds the root HLS playlist (`playlist.m3u8`) from packaged HLS variants.
  """
  @behaviour MaveCore.Flow.Step

  alias MaveCore.Flow.Steps.Support, as: StepSupport
  alias MaveCore.Media.Storage

  @variant_order %{"sd" => 1, "hd" => 2, "fhd" => 3, "qhd" => 4, "uhd" => 5}
  @variant_profiles %{
    "sd" => %{bandwidth: 3_000_000, resolution: "842x480"},
    "hd" => %{bandwidth: 4_000_000, resolution: "1280x720"},
    "fhd" => %{bandwidth: 6_000_000, resolution: "1920x1080"},
    "qhd" => %{bandwidth: 8_000_000, resolution: "2560x1440"},
    "uhd" => %{bandwidth: 10_000_000, resolution: "3840x2160"}
  }

  @impl true
  def run(step_definition, context) do
    run_input = Map.get(context, :run_input, %{})
    dependency_outputs = Map.get(context, :dependency_outputs, %{})
    params = Map.get(step_definition, "params", %{})
    step_id = Map.get(step_definition, "id", "hls_master")
    strict? = StepSupport.strict_enabled?(params, run_input, "media_build_hls_master_strict")

    space_hash = map_get(run_input, "space_hash")
    embed_hash = map_get(run_input, "embed_hash")
    version = StepSupport.normalize_version(map_get(run_input, "version", 0))
    region = map_get(run_input, "region")
    storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter, Storage)
    bucket = Storage.bucket_for_space(space_hash, region)

    variants = collect_variants(dependency_outputs)
    audio_tracks = collect_audio_tracks(dependency_outputs)
    subtitles = collect_subtitles(dependency_outputs, embed_hash, version)
    duration = subtitle_duration(run_input, dependency_outputs)

    with {:ok, space_hash} <- StepSupport.require_binary(space_hash, :space_hash),
         {:ok, embed_hash} <- StepSupport.require_binary(embed_hash, :embed_hash),
         {:ok, sorted_variants} <- require_variants(variants),
         :ok <- require_waveform_audio(dependency_outputs, audio_tracks),
         {:ok, packaged_subtitles} <-
           publish_subtitle_playlists(
             storage_adapter,
             bucket,
             embed_hash,
             version,
             region,
             subtitles,
             duration
           ),
         {:ok, playlist_body} <-
           build_master_playlist(sorted_variants, audio_tracks, packaged_subtitles),
         key <- master_playlist_key(embed_hash, version),
         {:ok, _} <-
           storage_adapter.put_public(
             bucket,
             key,
             playlist_body,
             "application/vnd.apple.mpegurl",
             region
           ) do
      uri = "s3://#{bucket}/#{key}"
      size_bytes = byte_size(playlist_body)

      rendition = %{
        "type" => "video",
        "size" => "master",
        "codec" => "h264",
        "container" => "hls",
        "progress" => 100.0,
        "rendition_key" => key,
        "src" => uri,
        "file_size" => size_bytes
      }

      output = %{
        "status" => "ok",
        "step_type" => "media.build_hls_master",
        "step_id" => step_id,
        "container" => "hls",
        "bucket" => bucket,
        "key" => key,
        "uri" => uri,
        "variant_count" => length(sorted_variants),
        "audio_track_count" => length(audio_tracks),
        "subtitle_count" => length(packaged_subtitles),
        "variants" => sorted_variants,
        "audio_tracks" => audio_tracks,
        "subtitles" => packaged_subtitles,
        "file_size" => size_bytes,
        "rendition" => rendition,
        "renditions" => [rendition | waveform_renditions(dependency_outputs)]
      }

      artifacts = [
        %{
          name: "hls_master",
          uri: uri,
          media_type: "application/vnd.apple.mpegurl",
          size_bytes: size_bytes,
          metadata: %{
            "type" => "video",
            "container" => "hls",
            "scope" => "master",
            "space_hash" => space_hash,
            "embed_hash" => embed_hash,
            "version" => version
          }
        }
      ]

      {:ok, output, artifacts}
    else
      {:error, :no_hls_variants} ->
        {:ok, skipped_output(step_id), []}

      {:error, :missing_waveform_audio} ->
        {:ok, Map.put(skipped_output(step_id), "reason", "missing_waveform_audio"), []}

      {:error, reason} when strict? ->
        {:error, {:media_build_hls_master_failed, reason}}

      {:error, reason} ->
        {:ok, unavailable_output(step_id, reason), []}
    end
  end

  defp require_waveform_audio(dependency_outputs, []) do
    if waveform_renditions(dependency_outputs) == [],
      do: :ok,
      else: {:error, :missing_waveform_audio}
  end

  defp require_waveform_audio(_dependency_outputs, _audio_tracks), do: :ok

  defp waveform_renditions(dependency_outputs) do
    Enum.flat_map(dependency_outputs, fn
      {_id, %{"status" => "ok", "waveform_rendition" => rendition}} when is_map(rendition) ->
        [rendition]

      _ ->
        []
    end)
  end

  defp require_variants([]), do: {:error, :no_hls_variants}

  defp require_variants(variants) do
    sorted =
      variants
      |> Enum.sort_by(fn variant ->
        {Map.get(@variant_order, variant["size"], 999), variant["playlist_path"] || ""}
      end)

    {:ok, sorted}
  end

  defp collect_variants(dependency_outputs) do
    dependency_outputs
    |> Enum.flat_map(fn {_step_id, output} ->
      case output do
        %{
          "step_type" => "media.package_hls_variant",
          "status" => "ok",
          "playlist_path" => playlist_path
        }
        when is_binary(playlist_path) ->
          [normalize_variant(output)]

        %{
          "step_type" => "media.build_hls_master",
          "status" => "ok",
          "variants" => variants
        }
        when is_list(variants) ->
          variants
          |> Enum.filter(&is_map/1)
          |> Enum.map(&normalize_master_variant/1)

        _ ->
          []
      end
    end)
    |> Enum.uniq_by(fn variant ->
      {variant["playlist_path"], variant["size"], variant["codec"]}
    end)
  end

  defp collect_audio_tracks(dependency_outputs) do
    dependency_outputs
    |> Enum.flat_map(fn {_step_id, output} ->
      case output do
        %{
          "step_type" => "media.package_hls_audio",
          "status" => "ok",
          "audio_tracks" => tracks
        }
        when is_list(tracks) ->
          tracks
          |> Enum.filter(&is_map/1)
          |> Enum.map(&normalize_audio_track_map/1)

        %{
          "step_type" => "media.package_hls_audio",
          "status" => "ok",
          "playlist_path" => playlist_path
        }
        when is_binary(playlist_path) ->
          [normalize_audio_track(output)]

        %{
          "step_type" => "media.build_hls_master",
          "status" => "ok",
          "audio_tracks" => tracks
        }
        when is_list(tracks) ->
          tracks
          |> Enum.filter(&is_map/1)
          |> Enum.map(&normalize_audio_track_map/1)

        _ ->
          []
      end
    end)
    |> Enum.uniq_by(fn track ->
      {track["track_id"], track["playlist_path"]}
    end)
    |> Enum.sort_by(fn track ->
      {if(track["default"], do: 0, else: 1), track["name"] || ""}
    end)
  end

  defp collect_subtitles(dependency_outputs, embed_hash, version) do
    dependency_outputs
    |> Enum.flat_map(fn {_step_id, output} ->
      case output do
        %{
          "step_type" => step_type,
          "status" => "ok",
          "subtitles" => subtitles
        }
        when step_type in [
               "ai.transcribe_audio",
               "ai.translate_subtitles",
               "media.build_hls_master",
               "subtitle.collect"
             ] and is_list(subtitles) ->
          subtitles
          |> Enum.filter(&is_map/1)
          |> Enum.map(&normalize_subtitle(&1, embed_hash, version))

        _ ->
          []
      end
    end)
    |> Enum.reject(fn subtitle ->
      is_nil(subtitle["playlist_path"]) and is_nil(subtitle["source_path"])
    end)
    |> Enum.uniq_by(fn subtitle ->
      {subtitle["language"], subtitle["playlist_path"]}
    end)
    |> Enum.sort_by(fn subtitle ->
      {if(subtitle["default"], do: 0, else: 1), subtitle["name"] || ""}
    end)
  end

  defp normalize_variant(output) do
    size = map_get(output, "size")
    codec = map_get(output, "codec")
    profile = Map.get(@variant_profiles, size, %{})

    %{
      "size" => size,
      "codec" => codec,
      "playlist_path" => map_get(output, "playlist_path"),
      "playlist_uri" => map_get(output, "playlist_uri"),
      "bandwidth" => map_get(output, "bandwidth") || profile[:bandwidth],
      "resolution" => map_get(output, "resolution") || profile[:resolution]
    }
  end

  defp normalize_master_variant(variant) do
    size = map_get(variant, "size")
    profile = Map.get(@variant_profiles, size, %{})

    %{
      "size" => size,
      "codec" => map_get(variant, "codec"),
      "playlist_path" => map_get(variant, "playlist_path"),
      "playlist_uri" => map_get(variant, "playlist_uri"),
      "bandwidth" => map_get(variant, "bandwidth") || profile[:bandwidth],
      "resolution" => map_get(variant, "resolution") || profile[:resolution]
    }
  end

  defp normalize_audio_track(output) do
    track = map_get(output, "audio_track", %{})

    %{
      "track_id" => preferred_track_value(output, track, "track_id", "id", "default"),
      "name" => preferred_track_value(output, track, "label", "label", "Audio"),
      "language" => preferred_track_value(output, track, "language", "language", "und"),
      "default" =>
        normalize_boolean(map_get(output, "default"), map_get(track, "default", false)),
      "channels" =>
        normalize_string(preferred_track_value(output, track, "channels", "hls_channels", "2")),
      "bandwidth" =>
        normalize_integer(map_get(output, "bandwidth") || map_get(track, "hls_bandwidth")),
      "playlist_path" => map_get(output, "playlist_path"),
      "playlist_uri" => map_get(output, "playlist_uri")
    }
  end

  defp normalize_audio_track_map(track) do
    %{
      "track_id" => first_map_value(track, ["id", "track_id"], "default"),
      "name" => first_map_value(track, ["label", "name"], "Audio"),
      "language" => first_map_value(track, ["language"], "und"),
      "default" => normalize_boolean(map_get(track, "default"), false),
      "channels" => normalize_string(first_map_value(track, ["hls_channels", "channels"], "2")),
      "bandwidth" => normalize_integer(first_map_value(track, ["hls_bandwidth", "bandwidth"])),
      "playlist_path" => first_map_value(track, ["hls_playlist", "playlist_path"]),
      "playlist_uri" => first_map_value(track, ["hls_src", "playlist_uri"])
    }
  end

  defp normalize_subtitle(subtitle, embed_hash, version) do
    language = first_map_value(subtitle, ["language", "id"], "und")
    playlist_path = first_map_value(subtitle, ["hls_playlist", "playlist_path"])
    source_path = first_map_value(subtitle, ["path", "src", "source_path"])

    %{
      "id" => first_map_value(subtitle, ["id", "language"], language),
      "name" => first_map_value(subtitle, ["label", "name"], language),
      "language" => language,
      "default" => normalize_boolean(map_get(subtitle, "default"), false),
      "playlist_path" => relative_media_path(playlist_path, embed_hash, version),
      "source_path" => relative_media_path(source_path, embed_hash, version)
    }
  end

  defp first_map_value(map, keys, fallback \\ nil) do
    Enum.find_value(keys, fallback, &map_get(map, &1))
  end

  defp publish_subtitle_playlists(
         storage_adapter,
         bucket,
         embed_hash,
         version,
         region,
         subtitles,
         duration
       ) do
    subtitles
    |> Enum.reduce_while({:ok, []}, fn subtitle, {:ok, published} ->
      case publish_subtitle_playlist(
             storage_adapter,
             bucket,
             embed_hash,
             version,
             region,
             subtitle,
             duration
           ) do
        {:ok, packaged_subtitle} -> {:cont, {:ok, [packaged_subtitle | published]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, published} -> {:ok, Enum.reverse(published)}
      {:error, _reason} = error -> error
    end
  end

  defp publish_subtitle_playlist(
         _storage_adapter,
         _bucket,
         _embed_hash,
         _version,
         _region,
         %{"playlist_path" => playlist_path} = subtitle,
         _duration
       )
       when is_binary(playlist_path) and playlist_path != "" do
    {:ok, subtitle}
  end

  defp publish_subtitle_playlist(
         storage_adapter,
         bucket,
         embed_hash,
         version,
         region,
         %{"source_path" => source_path} = subtitle,
         duration
       )
       when is_binary(source_path) and source_path != "" do
    playlist_path = subtitle_playlist_path(subtitle)
    key = media_key(embed_hash, version, playlist_path)
    body = subtitle_playlist_body(source_path, duration)

    case storage_adapter.put_public(
           bucket,
           key,
           body,
           "application/vnd.apple.mpegurl",
           region
         ) do
      {:ok, _body} -> {:ok, Map.put(subtitle, "playlist_path", playlist_path)}
      {:error, reason} -> {:error, {:subtitle_playlist_upload_failed, reason}}
    end
  end

  defp publish_subtitle_playlist(
         _storage_adapter,
         _bucket,
         _embed_hash,
         _version,
         _region,
         _subtitle,
         _duration
       ),
       do: {:error, :missing_subtitle_source}

  defp subtitle_playlist_path(subtitle) do
    identifier =
      subtitle
      |> first_map_value(["language", "id"], "und")
      |> to_string()
      |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")

    "subtitle_#{identifier}_hls/playlist.m3u8"
  end

  defp subtitle_playlist_body(source_path, duration) do
    duration = if is_number(duration) and duration > 0, do: duration * 1.0, else: 1.0
    target_duration = duration |> ceil() |> max(1)
    segment_uri = subtitle_segment_uri(source_path)
    duration_text = :erlang.float_to_binary(duration, decimals: 6)

    [
      "#EXTM3U",
      "#EXT-X-VERSION:3",
      "#EXT-X-TARGETDURATION:#{target_duration}",
      "#EXT-X-MEDIA-SEQUENCE:0",
      "#EXTINF:#{duration_text},",
      segment_uri,
      "#EXT-X-ENDLIST"
    ]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp subtitle_segment_uri(source_path) do
    if String.starts_with?(source_path, "http://") or
         String.starts_with?(source_path, "https://") do
      source_path
    else
      "../#{source_path}"
    end
  end

  defp subtitle_duration(run_input, dependency_outputs) do
    run_input_duration = map_get(run_input, "duration")

    inspect_duration =
      dependency_outputs
      |> Enum.find_value(fn {_step_id, output} ->
        if map_get(output, "step_type") == "media.inspect", do: map_get(output, "duration")
      end)

    normalize_number(run_input_duration) || normalize_number(inspect_duration)
  end

  defp build_master_playlist(variants, audio_tracks, subtitles) do
    audio_group_id = if audio_tracks == [], do: nil, else: "audio"
    subtitle_group_id = if subtitles == [], do: nil, else: "subtitles"
    audio_lines = audio_playlist_lines(audio_tracks, audio_group_id)
    subtitle_lines = subtitle_playlist_lines(subtitles, subtitle_group_id)

    variant_lines =
      variants
      |> Enum.flat_map(fn variant ->
        stream_info = stream_info_line(variant, audio_group_id, subtitle_group_id)
        [stream_info, variant["playlist_path"]]
      end)

    playlist =
      ["#EXTM3U", "#EXT-X-VERSION:3"]
      |> Kernel.++(audio_lines)
      |> Kernel.++(subtitle_lines)
      |> Kernel.++(variant_lines)
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    {:ok, playlist}
  end

  defp audio_playlist_lines(_audio_tracks, nil), do: []

  defp audio_playlist_lines(audio_tracks, group_id) do
    Enum.map(audio_tracks, &audio_media_line(&1, group_id))
  end

  defp subtitle_playlist_lines(_subtitles, nil), do: []

  defp subtitle_playlist_lines(subtitles, group_id) do
    Enum.map(subtitles, &subtitle_media_line(&1, group_id))
  end

  defp stream_info_line(variant, audio_group_id, subtitle_group_id) do
    attrs =
      []
      |> append_attr("BANDWIDTH", variant["bandwidth"])
      |> append_attr("RESOLUTION", variant["resolution"])
      |> append_attr("CLOSED-CAPTIONS", "NONE")
      |> append_quoted_attr("AUDIO", audio_group_id)
      |> append_quoted_attr("SUBTITLES", subtitle_group_id)

    "#EXT-X-STREAM-INF:#{Enum.join(attrs, ",")}"
  end

  defp audio_media_line(track, group_id) do
    default? = track["default"] in [true, "true", 1, "1"]
    default_flag = if default?, do: "YES", else: "NO"
    autoselect_flag = if default?, do: "YES", else: "NO"

    attrs =
      [
        "TYPE=AUDIO",
        ~s(GROUP-ID="#{escape_attr(group_id)}"),
        ~s(NAME="#{escape_attr(track["name"] || "Audio")}"),
        ~s(LANGUAGE="#{escape_attr(track["language"] || "und")}"),
        "DEFAULT=#{default_flag}",
        "AUTOSELECT=#{autoselect_flag}",
        ~s(CHANNELS="#{escape_attr(track["channels"] || "2")}"),
        ~s(URI="#{escape_attr(track["playlist_path"] || "")}")
      ]
      |> append_attr("BANDWIDTH", track["bandwidth"])

    "#EXT-X-MEDIA:#{Enum.join(attrs, ",")}"
  end

  defp subtitle_media_line(subtitle, group_id) do
    default? = subtitle["default"] in [true, "true", 1, "1"]
    default_flag = if default?, do: "YES", else: "NO"

    attrs = [
      "TYPE=SUBTITLES",
      ~s(GROUP-ID="#{escape_attr(group_id)}"),
      ~s(NAME="#{escape_attr(subtitle["name"] || "Subtitles")}"),
      ~s(LANGUAGE="#{escape_attr(subtitle["language"] || "und")}"),
      "DEFAULT=#{default_flag}",
      "FORCED=NO",
      ~s(URI="#{escape_attr(subtitle["playlist_path"] || "")}")
    ]

    "#EXT-X-MEDIA:#{Enum.join(attrs, ",")}"
  end

  defp append_attr(attrs, _name, nil), do: attrs
  defp append_attr(attrs, name, value), do: attrs ++ ["#{name}=#{value}"]
  defp append_quoted_attr(attrs, _name, nil), do: attrs
  defp append_quoted_attr(attrs, name, value), do: attrs ++ [~s(#{name}="#{escape_attr(value)}")]

  # RFC 8216 quoted strings have no escape syntax and cannot contain a double
  # quote, CR or LF. Names such as audio labels come from users, so replace
  # those characters instead of letting them end the attribute or the line.
  defp escape_attr(value) when is_binary(value) do
    value
    |> String.replace("\"", "'")
    |> String.replace(~r/[\x00-\x1F\x7F]+/, " ")
  end

  defp escape_attr(value), do: to_string(value)

  defp normalize_boolean(value, _default) when value in [true, "true", 1, "1"], do: true
  defp normalize_boolean(value, _default) when value in [false, "false", 0, "0"], do: false
  defp normalize_boolean(_value, default), do: default

  defp normalize_string(value) when is_binary(value) and value != "", do: value
  defp normalize_string(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(_), do: nil

  defp normalize_integer(value) when is_integer(value), do: value

  defp normalize_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_integer(_), do: nil

  defp normalize_number(value) when is_integer(value), do: value * 1.0
  defp normalize_number(value) when is_float(value), do: value

  defp normalize_number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _other -> nil
    end
  end

  defp normalize_number(_value), do: nil

  defp relative_media_path(nil, _embed_hash, _version), do: nil

  defp relative_media_path("s3://" <> rest, embed_hash, version) do
    case String.split(rest, "/", parts: 2) do
      [_bucket, key] -> relative_media_path(key, embed_hash, version)
      _parts -> nil
    end
  end

  defp relative_media_path(path, embed_hash, version) when is_binary(path) do
    if String.starts_with?(path, "http://") or String.starts_with?(path, "https://") do
      path
    else
      prefix =
        if version > 0 do
          "#{embed_hash}/v#{version}/"
        else
          "#{embed_hash}/"
        end

      String.trim_leading(path, prefix)
    end
  end

  defp relative_media_path(_path, _embed_hash, _version), do: nil

  defp media_key(embed_hash, version, path) do
    if version > 0 do
      "#{embed_hash}/v#{version}/#{path}"
    else
      "#{embed_hash}/#{path}"
    end
  end

  defp master_playlist_key(embed_hash, version) do
    media_key(embed_hash, version, "playlist.m3u8")
  end

  defp skipped_output(step_id) do
    %{
      "status" => "skipped",
      "step_type" => "media.build_hls_master",
      "step_id" => step_id,
      "container" => "hls",
      "reason" => "no_hls_variants"
    }
  end

  defp unavailable_output(step_id, reason) do
    %{
      "status" => "unavailable",
      "step_type" => "media.build_hls_master",
      "step_id" => step_id,
      "container" => "hls",
      "error" => inspect(reason)
    }
  end

  defp map_get(map, key, default \\ nil)

  defp map_get(map, key, default) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        map
        |> Map.keys()
        |> Enum.find_value(default, &map_atom_string_value(map, &1, key))
    end
  end

  defp map_get(_map, _key, default), do: default

  defp preferred_track_value(output, track, output_key, track_key, fallback) do
    map_get(output, output_key) || map_get(track, track_key) || fallback
  end

  defp map_atom_string_value(map, map_key, key) when is_atom(map_key) do
    if Atom.to_string(map_key) == key, do: Map.get(map, map_key), else: nil
  end

  defp map_atom_string_value(_map, _map_key, _key), do: nil
end
