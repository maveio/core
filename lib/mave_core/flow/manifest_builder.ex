defmodule MaveCore.Flow.ManifestBuilder do
  @moduledoc """
  Builds a player-facing `manifest.json` document from flow run context.

  The schema intentionally mirrors legacy manifest keys so we can diff outputs
  between `mave` and `core` during migration.
  """

  alias MaveCore.Embeds.{Embed, EmbedSettings, SettingsSerializer}
  alias MaveCore.Media.Storage
  alias MaveCore.Spaces.Space

  @settings_fields EmbedSettings.dashboard_fields()

  @doc """
  Builds manifest payload and storage coordinates.

  Returns:
  - `bucket`: destination bucket
  - `key`: manifest object key
  - `uri`: s3 URI
  - `manifest`: map payload
  - `json`: encoded JSON payload
  - `checksum`: SHA256 of payload
  """
  def build(%{} = attrs) do
    run_input = Map.get(attrs, :run_input, %{})
    dependency_outputs = Map.get(attrs, :dependency_outputs, %{})

    source_output = Map.get(dependency_outputs, "source", %{})
    inspect_output = resolve_inspect_output(dependency_outputs)
    audio_tracks = resolve_audio_tracks(run_input, dependency_outputs)
    subtitles = resolve_subtitles(run_input, dependency_outputs)
    video_renditions = resolve_video_renditions(run_input, dependency_outputs)
    poster_output = resolve_poster_output(dependency_outputs)
    upload_original_output = Map.get(dependency_outputs, "upload_original", %{})
    ensure_bucket_output = Map.get(dependency_outputs, "ensure_bucket", %{})

    space_hash = Map.get(source_output, "space_hash") || Map.get(run_input, "space_hash")
    embed_hash = Map.get(source_output, "embed_hash") || Map.get(run_input, "embed_hash")
    version = Map.get(source_output, "version") || Map.get(run_input, "version")

    with {:ok, space_hash} <- require_binary(space_hash, :space_hash),
         {:ok, embed_hash} <- require_binary(embed_hash, :embed_hash) do
      region = Map.get(run_input, "region")
      version = normalize_version(version)
      bucket = resolve_bucket(space_hash, region, ensure_bucket_output, upload_original_output)
      key = manifest_key(embed_hash, version)
      uri = "s3://#{bucket}/#{key}"

      manifest_context = %{
        run_input: run_input,
        source_output: source_output,
        inspect_output: inspect_output,
        audio_tracks: audio_tracks,
        subtitles: subtitles,
        video_renditions: video_renditions,
        poster_output: poster_output,
        upload_original_output: upload_original_output,
        space_hash: space_hash,
        embed_hash: embed_hash,
        version: version
      }

      manifest =
        build_manifest(manifest_context)
        |> maybe_put("waveform", resolve_waveform(dependency_outputs))
        |> normalize_public_manifest_refs()

      json = Jason.encode!(manifest)
      checksum = sha256(json)

      {:ok,
       %{
         "bucket" => bucket,
         "key" => key,
         "uri" => uri,
         "manifest" => manifest,
         "json" => json,
         "checksum" => checksum
       }}
    end
  end

  defp resolve_waveform(outputs) do
    Enum.find_value(outputs, fn
      {_,
       %{"step_type" => "media.generate_audio_peaks", "status" => "ok", "waveform" => waveform}} ->
        waveform

      _ ->
        nil
    end)
  end

  defp build_manifest(%{
         run_input: run_input,
         source_output: source_output,
         inspect_output: inspect_output,
         audio_tracks: audio_tracks,
         subtitles: subtitles,
         video_renditions: video_renditions,
         poster_output: poster_output,
         upload_original_output: upload_original_output,
         space_hash: space_hash,
         embed_hash: embed_hash,
         version: version
       }) do
    video_aspect_ratio = resolve_video_aspect_ratio(run_input, inspect_output)
    settings = resolve_settings(run_input)
    manifest_settings = resolve_manifest_settings(settings, video_aspect_ratio)
    source_url = source_url(source_output, run_input)
    filetype = resolve_filetype(run_input, inspect_output, upload_original_output, source_url)

    resolved_original_url =
      resolve_original_url(
        public_upload_url(run_input) || source_url,
        upload_original_output
      )

    original_url = playback_original_url(video_renditions, resolved_original_url)
    status = resolve_video_status(run_input, resolved_original_url, video_renditions)
    has_audio = resolve_has_audio(audio_tracks, inspect_output, run_input)

    %{
      "audio_tracks" => audio_tracks,
      "created_at" => manifest_created_at(run_input),
      "id" => "#{space_hash}#{embed_hash}",
      "name" => manifest_name(run_input, embed_hash),
      "poster" => build_poster(run_input, space_hash, embed_hash, poster_output, settings),
      "settings" => manifest_settings,
      "space_id" => space_hash,
      "subtitles" => subtitles,
      "video" =>
        build_manifest_video(%{
          run_input: run_input,
          inspect_output: inspect_output,
          upload_original_output: upload_original_output,
          video_aspect_ratio: video_aspect_ratio,
          video_renditions: video_renditions,
          has_audio: has_audio,
          filetype: filetype,
          original_url: original_url,
          status: status,
          embed_hash: embed_hash,
          version: version
        })
    }
    |> maybe_put("metrics_key", Map.get(run_input, "metrics_key"))
  end

  defp build_manifest_video(%{
         run_input: run_input,
         inspect_output: inspect_output,
         upload_original_output: upload_original_output,
         video_aspect_ratio: video_aspect_ratio,
         video_renditions: video_renditions,
         has_audio: has_audio,
         filetype: filetype,
         original_url: original_url,
         status: status,
         embed_hash: embed_hash,
         version: version
       }) do
    %{
      "audio" => has_audio,
      "aspect_ratio" => video_aspect_ratio,
      "duration" => manifest_duration(run_input, inspect_output),
      "filetype" => filetype,
      "id" => video_id(run_input, inspect_output, embed_hash),
      "language" => Map.get(run_input, "language") || Map.get(inspect_output, "language"),
      "max_height" => manifest_max_height(run_input, inspect_output),
      "max_width" => manifest_max_width(run_input, inspect_output),
      "original" => original_url,
      "ready" => status in ["ready", "playable"],
      "renditions" => video_renditions,
      "size" => manifest_size(run_input, inspect_output, upload_original_output),
      "sources" => ensure_list(Map.get(run_input, "sources")),
      "src" => original_url,
      "status" => status,
      "version" => version
    }
  end

  defp source_url(source_output, run_input) do
    Map.get(source_output, "source_url") || Map.get(run_input, "input_url")
  end

  defp manifest_created_at(run_input) do
    parse_unix(Map.get(run_input, "created_at"), DateTime.utc_now() |> DateTime.to_unix())
  end

  defp manifest_name(run_input, embed_hash) do
    Map.get(run_input, "name") || Map.get(run_input, "title") || embed_hash
  end

  defp manifest_duration(run_input, inspect_output) do
    parse_float(Map.get(run_input, "duration")) ||
      parse_float(Map.get(inspect_output, "duration"))
  end

  defp manifest_size(run_input, inspect_output, upload_original_output) do
    parse_integer(Map.get(run_input, "size")) ||
      parse_integer(Map.get(inspect_output, "size_bytes")) ||
      Map.get(upload_original_output, "bytes")
  end

  defp video_id(run_input, inspect_output, embed_hash) do
    Map.get(run_input, "video_id") || Map.get(inspect_output, "video_id") || embed_hash
  end

  defp manifest_max_height(run_input, inspect_output) do
    parse_integer(Map.get(run_input, "max_height")) ||
      parse_integer(Map.get(inspect_output, "height"))
  end

  defp manifest_max_width(run_input, inspect_output) do
    parse_integer(Map.get(run_input, "max_width")) ||
      parse_integer(Map.get(inspect_output, "width"))
  end

  defp build_poster(run_input, space_hash, embed_hash, poster_output, settings) do
    poster_src_from_input = Map.get(run_input, "poster_image_src")
    poster_src_from_step = poster_src_from_output(poster_output)

    poster_src =
      poster_src_from_input ||
        poster_src_from_step ||
        SettingsSerializer.poster_image_base_url(space_hash, embed_hash)
        |> public_url()

    initial_frame_src =
      if poster_src_from_input || poster_src_from_step do
        poster_src
      else
        SettingsSerializer.poster_image_url(space_hash, embed_hash, 0)
      end

    if settings do
      %{
        "image_src" => poster_src,
        "initial_frame_src" => initial_frame_src,
        "renditions" => ensure_list(Map.get(run_input, "poster_renditions")),
        "type" => Map.get(run_input, "poster_type"),
        "video_src" => Map.get(run_input, "poster_video_src")
      }
      |> then(
        &SettingsSerializer.manifest_poster(
          %Space{hash: space_hash},
          %Embed{hash: embed_hash},
          settings,
          &1
        )
      )
      |> maybe_put_preview_poster_type(settings)
    else
      %{
        "image_src" => poster_src,
        "initial_frame_src" => initial_frame_src,
        "renditions" => ensure_list(Map.get(run_input, "poster_renditions")),
        "type" => Map.get(run_input, "poster_type"),
        "video_src" => Map.get(run_input, "poster_video_src")
      }
    end
  end

  defp maybe_put_preview_poster_type(poster, %EmbedSettings{} = settings) do
    cond do
      settings.poster == :upload and is_binary(settings.external_poster) and
          settings.external_poster != "" ->
        Map.put(poster, "type", "upload")

      settings.poster == :timecode and is_number(settings.poster_time_seconds) and
          settings.poster_time_seconds > 0 ->
        Map.put(poster, "type", "timecode")

      true ->
        poster
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp poster_src_from_output(%{} = poster_output) do
    map_get(poster_output, "poster_image_src") ||
      map_get(poster_output, "src") ||
      map_get(poster_output, "uri") ||
      map_get(map_get(poster_output, "rendition"), "src")
  end

  defp poster_src_from_output(_), do: nil

  defp resolve_bucket(space_hash, region, ensure_bucket_output, upload_original_output) do
    Map.get(ensure_bucket_output, "bucket") ||
      Map.get(upload_original_output, "bucket") ||
      Storage.bucket_for_space(space_hash, region)
  end

  defp manifest_key(embed_hash, version) do
    if version in [0, "0", nil] do
      "#{embed_hash}/manifest.json"
    else
      "#{embed_hash}/v#{version}/manifest.json"
    end
  end

  defp resolve_video_aspect_ratio(run_input, inspect_output) do
    Map.get(run_input, "aspect_ratio") ||
      Map.get(inspect_output, "aspect_ratio") ||
      "16 / 9"
  end

  defp resolve_settings(%{"settings" => settings}) when is_map(settings) do
    settings
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      case normalize_settings_key(key) do
        atom when atom in @settings_fields ->
          Map.put(acc, atom, value)

        _ ->
          acc
      end
    end)
    |> then(&EmbedSettings.changeset(%EmbedSettings{}, &1))
    |> Ecto.Changeset.apply_changes()
    |> SettingsSerializer.settings_struct()
  end

  defp resolve_settings(_run_input), do: nil

  defp normalize_settings_key(key) when is_atom(key), do: key

  defp normalize_settings_key(key) when is_binary(key), do: to_existing_atom_or_nil(key)

  defp normalize_settings_key(_key), do: nil

  defp resolve_manifest_settings(nil, aspect_ratio) do
    nil
    |> SettingsSerializer.manifest_settings()
    |> Map.put("aspect_ratio", aspect_ratio)
  end

  defp resolve_manifest_settings(settings, aspect_ratio) do
    settings
    |> SettingsSerializer.manifest_settings()
    |> Map.put_new("aspect_ratio", aspect_ratio)
  end

  defp resolve_filetype(run_input, inspect_output, upload_original_output, source_url) do
    Map.get(run_input, "filetype") ||
      Map.get(inspect_output, "filetype") ||
      filetype_from_content_type(Map.get(upload_original_output, "content_type")) ||
      filetype_from_source_url(source_url) ||
      "mp4"
  end

  defp filetype_from_content_type(nil), do: nil

  defp filetype_from_content_type(content_type) when is_binary(content_type) do
    case String.split(content_type, "/") do
      [_prefix, suffix] ->
        suffix
        |> String.split(";")
        |> List.first()
        |> String.trim()
        |> case do
          generic when generic in ["octet-stream", "binary"] -> nil
          ext -> ext
        end

      _ ->
        nil
    end
  end

  defp filetype_from_source_url(source_url) when is_binary(source_url) do
    source_url
    |> String.split("?")
    |> List.first()
    |> Path.extname()
    |> case do
      "" -> nil
      ext -> ext |> String.trim_leading(".") |> String.downcase()
    end
  end

  defp filetype_from_source_url(_), do: nil

  defp parse_unix(value, _default) when is_integer(value), do: value

  defp parse_unix(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp parse_unix(_, default), do: default

  defp parse_float(nil), do: nil
  defp parse_float(value) when is_float(value), do: value
  defp parse_float(value) when is_integer(value), do: value * 1.0

  defp parse_float(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_float(_), do: nil

  defp parse_integer(nil), do: nil
  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_integer(_), do: nil

  defp ensure_list(value) when is_list(value), do: value
  defp ensure_list(_), do: []

  @public_ref_keys ~w(src path image_src initial_frame_src video_src hls_src vtt_src)

  defp normalize_public_manifest_refs(value) when is_list(value) do
    Enum.map(value, &normalize_public_manifest_refs/1)
  end

  defp normalize_public_manifest_refs(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested_value}, acc ->
      normalized_value =
        if is_binary(key) and key in @public_ref_keys do
          public_url(nested_value)
        else
          normalize_public_manifest_refs(nested_value)
        end

      Map.put(acc, key, normalized_value)
    end)
  end

  defp normalize_public_manifest_refs(value), do: value

  defp public_url("s3://" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [bucket, key] -> SettingsSerializer.storage_object_url(bucket, key) || "s3://#{rest}"
      _ -> "s3://#{rest}"
    end
  end

  defp public_url(value), do: value

  defp sha256(value) when is_binary(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp normalize_version(nil), do: 0
  defp normalize_version(value) when is_integer(value), do: value

  defp normalize_version(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> 0
    end
  end

  defp normalize_version(_), do: 0

  defp resolve_video_renditions(run_input, dependency_outputs) do
    declared_renditions = ensure_list(Map.get(run_input, "video_renditions"))

    derived_renditions =
      dependency_outputs
      |> Enum.flat_map(fn {_step_id, output} ->
        case output do
          %{
            "step_type" => "media.build_hls_master",
            "status" => "ok",
            "variants" => variants
          }
          when is_list(variants) ->
            Enum.flat_map(variants, &hls_master_variant_rendition/1)

          %{
            "step_type" => step_type,
            "status" => "ok",
            "rendition" => %{} = rendition
          }
          when step_type in [
                 "media.transcode_video",
                 "media.transcode_h264_ladder",
                 "media.package_hls_variant",
                 "media.build_hls_master"
               ] ->
            [rendition]

          %{"step_type" => step_type, "status" => "ok", "renditions" => renditions}
          when step_type in [
                 "media.transcode_video",
                 "media.transcode_h264_ladder",
                 "media.package_hls_variant",
                 "media.build_hls_master"
               ] and is_list(renditions) ->
            Enum.filter(renditions, &is_map/1)

          _ ->
            []
        end
      end)

    (declared_renditions ++ derived_renditions)
    |> Enum.filter(fn rendition ->
      is_map(rendition) and map_get(rendition, "type") in [nil, "video", "clip", "clip_keyframes"]
    end)
    |> Enum.reject(&hls_master_rendition?/1)
    |> Enum.uniq_by(fn rendition ->
      {
        map_get(rendition, "type"),
        map_get(rendition, "size"),
        map_get(rendition, "codec"),
        map_get(rendition, "container"),
        map_get(rendition, "src")
      }
    end)
  end

  defp hls_master_variant_rendition(variant) when is_map(variant) do
    size = map_get(variant, "size")
    playlist_uri = map_get(variant, "playlist_uri")

    if is_binary(size) and size != "" do
      [
        %{
          "type" => "video",
          "size" => size,
          "codec" => map_get(variant, "codec") || "h264",
          "container" => "hls",
          "src" => playlist_uri
        }
      ]
    else
      []
    end
  end

  defp hls_master_variant_rendition(_variant), do: []

  defp hls_master_rendition?(rendition) do
    map_get(rendition, "type") in [nil, "video"] and
      map_get(rendition, "container") == "hls" and
      map_get(rendition, "size") in [nil, "master"]
  end

  defp completed_video_rendition?(rendition) do
    map_get(rendition, "type") in [nil, "video"] and is_binary(map_get(rendition, "src"))
  end

  defp playback_original_url(video_renditions, original_url) do
    if Enum.any?(video_renditions, &playable_video_rendition?/1), do: nil, else: original_url
  end

  defp playable_video_rendition?(rendition) do
    map_get(rendition, "type") == "video" and
      map_get(rendition, "container") in ["mp4", "hls"]
  end

  defp resolve_original_url(source_url, upload_original_output) do
    source_url
    |> original_url_candidates(upload_original_output)
    |> Enum.find_value(&candidate_original_url/1)
  end

  defp original_url_candidates(source_url, upload_original_output) do
    [
      {:storage, map_get(upload_original_output, "bucket"),
       map_get(upload_original_output, "original_key")},
      {:upload, source_url},
      {:public, map_get(upload_original_output, "original_uri")},
      {:public, map_get(upload_original_output, "player_uri")}
    ]
  end

  defp candidate_original_url({:upload, url}) when is_binary(url) and url != "" do
    if Storage.upload_storage_url?(url) or Storage.upload_public_url?(url), do: url
  end

  defp candidate_original_url({:storage, bucket, original_key})
       when is_binary(bucket) and bucket != "" and is_binary(original_key) and original_key != "" do
    SettingsSerializer.storage_object_url(bucket, original_key)
  end

  defp candidate_original_url({:public, uri}) when is_binary(uri) and uri != "" do
    public_url(uri)
  end

  defp candidate_original_url(_candidate), do: nil

  defp public_upload_url(run_input) do
    Map.get(run_input, "upload_public_url") ||
      Storage.upload_public_object_url(Map.get(run_input, "source_key"))
  end

  defp resolve_video_status(run_input, original_url, video_renditions) do
    case Map.get(run_input, "status") do
      status when is_binary(status) and status != "" ->
        status

      _ ->
        if is_binary(original_url) or Enum.any?(video_renditions, &completed_video_rendition?/1) do
          "playable"
        end
    end
  end

  defp resolve_has_audio(audio_tracks, inspect_output, run_input) do
    cond do
      audio_tracks != [] ->
        true

      is_boolean(boolean_value(map_get(inspect_output, "has_audio"))) ->
        boolean_value(map_get(inspect_output, "has_audio"))

      inspect_audio_streams?(inspect_output) ->
        true

      map_get(inspect_output, "status") == "ok" ->
        false

      is_boolean(boolean_value(Map.get(run_input, "has_audio"))) ->
        boolean_value(Map.get(run_input, "has_audio"))

      true ->
        true
    end
  end

  defp inspect_audio_streams?(inspect_output) do
    inspect_output
    |> map_get("streams")
    |> case do
      streams when is_list(streams) ->
        Enum.any?(streams, &(map_get(&1, "codec_type") == "audio"))

      _ ->
        false
    end
  end

  defp boolean_value(value) when value in [true, "true", 1, "1"], do: true
  defp boolean_value(value) when value in [false, "false", 0, "0"], do: false
  defp boolean_value(_value), do: nil

  defp resolve_audio_tracks(run_input, dependency_outputs) do
    declared_tracks = ensure_list(Map.get(run_input, "audio_tracks"))

    derived_tracks =
      dependency_outputs
      |> Enum.flat_map(fn {_step_id, output} ->
        case output do
          %{
            "step_type" => "media.transcode_audio",
            "status" => "ok",
            "audio_track" => %{} = track
          } ->
            [track]

          %{"step_type" => "media.transcode_audio", "status" => "ok", "audio_tracks" => tracks}
          when is_list(tracks) ->
            Enum.filter(tracks, &is_map/1)

          %{
            "step_type" => "media.package_hls_audio",
            "status" => "ok",
            "audio_track" => %{} = track
          } ->
            [track]

          %{"step_type" => "media.package_hls_audio", "status" => "ok", "audio_tracks" => tracks}
          when is_list(tracks) ->
            Enum.filter(tracks, &is_map/1)

          _ ->
            []
        end
      end)

    (declared_tracks ++ derived_tracks)
    |> Enum.filter(&is_map/1)
    |> Enum.reduce(%{}, fn track, acc ->
      track_key = {
        map_get(track, "id"),
        map_get(track, "label"),
        map_get(track, "language"),
        map_get(track, "filename"),
        map_get(track, "src")
      }

      merged_track =
        acc
        |> Map.get(track_key, %{})
        |> merge_track(track)

      Map.put(acc, track_key, merged_track)
    end)
    |> Map.values()
  end

  defp merge_track(base, incoming) when is_map(base) and is_map(incoming) do
    Map.merge(base, incoming, fn _key, base_value, incoming_value ->
      if is_nil(incoming_value), do: base_value, else: incoming_value
    end)
  end

  defp resolve_subtitles(run_input, dependency_outputs) do
    declared_subtitles = ensure_list(Map.get(run_input, "subtitles"))

    derived_subtitles =
      dependency_outputs
      |> Enum.flat_map(fn {_step_id, output} ->
        case output do
          %{
            "step_type" => step_type,
            "status" => "ok",
            "subtitle" => %{} = subtitle
          }
          when step_type in ["ai.transcribe_audio", "ai.translate_subtitles"] ->
            [subtitle]

          %{"step_type" => step_type, "status" => "ok", "subtitles" => subtitles}
          when step_type in ["ai.transcribe_audio", "ai.translate_subtitles"] and
                 is_list(subtitles) ->
            Enum.filter(subtitles, &is_map/1)

          _ ->
            []
        end
      end)

    (declared_subtitles ++ derived_subtitles)
    |> Enum.filter(&is_map/1)
    |> Enum.uniq_by(fn subtitle ->
      {
        map_get(subtitle, "id"),
        map_get(subtitle, "language"),
        map_get(subtitle, "label"),
        map_get(subtitle, "path"),
        map_get(subtitle, "src")
      }
    end)
  end

  defp resolve_poster_output(dependency_outputs) do
    Enum.find_value(dependency_outputs, %{}, fn {_step_id, output} ->
      if is_map(output) and output["step_type"] == "media.extract_frame" and
           output["status"] == "ok" and map_get(output, "role") == "poster" do
        output
      else
        nil
      end
    end)
  end

  defp resolve_inspect_output(dependency_outputs) do
    Map.get(dependency_outputs, "inspect_media") ||
      Enum.find_value(dependency_outputs, %{}, fn {_step_id, output} ->
        if is_map(output) and output["step_type"] == "media.inspect" do
          output
        else
          nil
        end
      end) ||
      %{}
  end

  defp map_get(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        map
        |> Map.keys()
        |> Enum.find_value(&atom_string_map_value(map, &1, key))
    end
  end

  defp map_get(_map, _key), do: nil

  defp to_existing_atom_or_nil(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp atom_string_map_value(map, map_key, key) when is_atom(map_key) do
    if Atom.to_string(map_key) == key, do: Map.get(map, map_key), else: nil
  end

  defp atom_string_map_value(_map, _map_key, _key), do: nil

  defp require_binary(value, _field) when is_binary(value) and value != "", do: {:ok, value}
  defp require_binary(_, field), do: {:error, {:missing_field, field}}
end
