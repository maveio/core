defmodule MaveCore.Embeds.ManifestPublisher do
  @moduledoc false

  import Ecto.Query

  alias MaveCore.Assets.{AudioTrack, Video}
  alias MaveCore.Embeds
  alias MaveCore.Embeds.{Embed, SettingsSerializer}
  alias MaveCore.Languages
  alias MaveCore.LegacyShortUUID
  alias MaveCore.Media.CdnCache
  alias MaveCore.Media.Storage
  alias MaveCore.Repo

  @spec publish(Embed.t(), map()) :: {:ok, map()} | {:error, term()}
  def publish(%Embed{} = embed, opts \\ %{}) do
    :global.trans({{__MODULE__, embed.id}, self()}, fn ->
      do_publish(embed, opts)
    end)
  end

  defp do_publish(%Embed{} = embed, opts) do
    embed = Repo.preload(embed, [:space, :settings, asset: [:current_video]])
    storage = Application.get_env(:mave_core, :flow_storage_adapter, Storage)
    bucket = Storage.bucket_for_space(embed.space.hash, embed.space.region)
    region = embed.space.region

    with {:ok, manifest, version} <- fetch_or_build_manifest(storage, bucket, embed, region),
         updated_manifest <- update_manifest(manifest, embed, version, opts),
         json <- Jason.encode!(updated_manifest),
         :ok <- put_manifest(storage, bucket, embed.hash, version, json, region) do
      purge_manifest_cache(embed.space.hash, region, embed.hash, version)
      {:ok, updated_manifest}
    end
  end

  @spec current(Embed.t(), map()) :: {:ok, map()} | {:error, term()}
  def current(%Embed{} = embed, opts \\ %{}) do
    embed = Repo.preload(embed, [:space, :settings, asset: [:current_video]])
    storage = Application.get_env(:mave_core, :flow_storage_adapter, Storage)
    bucket = Storage.bucket_for_space(embed.space.hash, embed.space.region)
    region = embed.space.region

    with {:ok, manifest, version} <- fetch_or_build_manifest(storage, bucket, embed, region) do
      {:ok, update_manifest(manifest, embed, version, opts)}
    end
  end

  defp fetch_or_build_manifest(storage, bucket, %Embed{} = embed, region) do
    version = Embeds.current_video_version(embed)

    storage
    |> find_existing_manifest(bucket, embed.hash, version, region)
    |> case do
      {:ok, manifest, manifest_version} ->
        {:ok, manifest, manifest_version}

      {:error, reason} ->
        {:error, reason}

      nil ->
        {:ok, fallback_manifest(embed, version, %{}), version}
    end
  end

  defp update_manifest(manifest, %Embed{} = embed, version, opts) do
    current_video = current_video(embed)

    name =
      case embed.asset do
        %{name: value} when is_binary(value) and value != "" ->
          value

        %{current_video: %{file_name: value}} when is_binary(value) and value != "" ->
          value

        _ ->
          embed.hash
      end

    created_at =
      Map.get(manifest, "created_at") || DateTime.to_unix(embed.inserted_at || DateTime.utc_now())

    status = manifest_video_status(embed, opts)
    original_url = original_video_url(opts)
    audio_tracks = manifest_audio_tracks(embed, version, map_get_any(opts, "audio_tracks"))
    has_audio = manifest_has_audio?(audio_tracks, manifest, opts)

    hls_ready? = manifest_hls_ready?(manifest, opts, status, current_video)

    %{
      "audio_tracks" => audio_tracks,
      "waveform" => manifest_waveform(opts, manifest, version),
      "created_at" => created_at,
      "id" => SettingsSerializer.public_embed_id(embed.space, embed),
      "name" => name,
      "poster" => manifest_poster(embed, version, manifest["poster"]),
      "settings" => SettingsSerializer.manifest_settings(embed.settings),
      "space_id" => embed.space.hash,
      "subtitles" => manifest_subtitles(embed, version),
      "video" =>
        manifest_video(
          embed,
          current_video,
          version,
          manifest["video"] || %{},
          original_url,
          has_audio,
          status,
          hls_ready?
        )
    }
  end

  defp manifest_waveform(opts, manifest, version) do
    previous = if get_in(manifest, ["video", "version"]) == version, do: manifest["waveform"]
    map_get_any(opts, "waveform") || previous
  end

  defp put_manifest(storage, bucket, embed_hash, version, json, region) do
    candidate_keys(embed_hash, version)
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn key, :ok ->
      case put_manifest_object(storage, bucket, key, json, region) do
        {:ok, _body} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:manifest_upload_failed, reason}}}
      end
    end)
  end

  defp put_manifest_object(storage, bucket, key, json, region) do
    case storage.put_public(bucket, key, json, "application/json", region) do
      {:error, :not_found} ->
        # A draft can be renamed before the first upload provisions its bucket.
        with :ok <- storage.ensure_bucket(bucket, region) do
          storage.put_public(bucket, key, json, "application/json", region)
        end

      result ->
        result
    end
  end

  defp purge_manifest_cache(space_hash, region, embed_hash, version) do
    paths =
      embed_hash
      |> candidate_keys(version)
      |> Enum.map(&elem(&1, 0))
      |> Kernel.++(["#{embed_hash}/"])

    CdnCache.purge_best_effort(space_hash, region, paths)
  end

  defp fallback_manifest(%Embed{} = embed, version, opts) do
    current_video =
      case embed.asset do
        %{current_video: video} -> video
        _ -> nil
      end

    status = manifest_video_status(embed, opts)
    has_audio = manifest_has_audio?([], %{}, opts)

    %{
      "audio_tracks" => [],
      "created_at" => DateTime.to_unix(embed.inserted_at || DateTime.utc_now()),
      "id" => SettingsSerializer.public_embed_id(embed.space, embed),
      "name" => embed.hash,
      "poster" => manifest_poster(embed, version, %{}),
      "settings" => SettingsSerializer.manifest_settings(embed.settings),
      "space_id" => embed.space.hash,
      "subtitles" => manifest_subtitles(embed, version),
      "video" => %{
        "aspect_ratio" => manifest_video_aspect_ratio(current_video, embed.settings),
        "audio" => has_audio,
        "duration" => current_video && current_video.duration,
        "filetype" => filetype(current_video),
        "id" => embed.hash,
        "original" => original_video_url(opts),
        "language" => current_video && current_video.language,
        "renditions" => [],
        "src" => original_video_url(opts),
        "status" => status,
        "ready" => status in ["ready", "playable"],
        "sources" => [],
        "size" => current_video && current_video.original_file_size,
        "version" => version,
        "max_width" => current_video && current_video.max_width,
        "max_height" => current_video && current_video.max_height
      }
    }
  end

  defp current_video_status(%Embed{asset: %{current_video: %{status: status}}})
       when is_binary(status) and status != "",
       do: status

  defp current_video_status(_), do: nil

  defp manifest_video_status(embed, opts) do
    case map_get_any(opts, "status") do
      status when is_binary(status) and status != "" -> status
      _ -> current_video_status(embed)
    end
  end

  defp original_video_url(opts) when is_map(opts) do
    explicit_url = map_get_any(opts, "original_url")
    bucket = map_get_any(opts, "bucket")
    key = map_get_any(opts, "original_key")

    cond do
      is_binary(explicit_url) and explicit_url != "" ->
        explicit_url

      is_binary(bucket) and bucket != "" and is_binary(key) and key != "" ->
        SettingsSerializer.storage_object_url(bucket, key)

      true ->
        nil
    end
  end

  defp original_video_url(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp map_get_any(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, String.to_existing_atom(key))
    end
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp map_get_any(_map, _key), do: nil

  defp filetype(%{file_name: file_name}) when is_binary(file_name) and file_name != "" do
    file_name
    |> Path.extname()
    |> String.trim_leading(".")
    |> case do
      "" -> "mp4"
      ext -> String.downcase(ext)
    end
  end

  defp filetype(_), do: "mp4"

  defp current_video(%Embed{asset: %{current_video: %Video{} = video}}), do: video
  defp current_video(_embed), do: nil

  defp manifest_video(
         %Embed{} = embed,
         %Video{} = current_video,
         version,
         current_video_manifest,
         original_url,
         has_audio,
         status,
         hls_ready?
       ) do
    renditions = manifest_video_renditions(current_video, hls_ready?)
    existing_original = Map.get(current_video_manifest, "original")
    existing_src = Map.get(current_video_manifest, "src")
    original = playback_original_url(current_video, renditions, original_url || existing_original)
    src = playback_original_url(current_video, renditions, original_url || existing_src)

    %{
      "id" => public_shortuuid(current_video.id),
      "version" => version,
      "audio" => has_audio,
      "aspect_ratio" => manifest_video_aspect_ratio(current_video, embed.settings),
      "filetype" => filetype(current_video),
      "original" => original,
      "size" => current_video.original_file_size,
      "duration" => current_video.duration,
      "language" => current_video.language,
      "status" => status,
      "ready" => status in ["ready", "playable"],
      "sources" => Map.get(current_video_manifest, "sources", []),
      "renditions" => renditions,
      "src" => src,
      "max_width" => current_video.max_width,
      "max_height" => current_video.max_height
    }
  end

  defp manifest_video(
         %Embed{} = embed,
         nil,
         version,
         current_video_manifest,
         original_url,
         has_audio,
         status,
         _hls_ready?
       ) do
    %{
      "id" => Map.get(current_video_manifest, "id") || embed.hash,
      "version" => version,
      "audio" => has_audio,
      "aspect_ratio" => Map.get(current_video_manifest, "aspect_ratio"),
      "filetype" => Map.get(current_video_manifest, "filetype") || "mp4",
      "original" => original_url || Map.get(current_video_manifest, "original"),
      "size" => Map.get(current_video_manifest, "size"),
      "duration" => Map.get(current_video_manifest, "duration"),
      "language" => Map.get(current_video_manifest, "language"),
      "status" => status,
      "ready" => status in ["ready", "playable"],
      "sources" => Map.get(current_video_manifest, "sources", []),
      "renditions" => Map.get(current_video_manifest, "renditions", []),
      "src" => original_url || Map.get(current_video_manifest, "src"),
      "max_width" => Map.get(current_video_manifest, "max_width"),
      "max_height" => Map.get(current_video_manifest, "max_height")
    }
  end

  defp manifest_video_aspect_ratio(%Video{aspect_ratio: ratio}, settings)
       when is_binary(ratio) and ratio != "" do
    settings = SettingsSerializer.settings_struct(settings)

    if settings.aspect_ratio_enabled do
      ratio
      |> String.replace(":", " / ")
      |> String.replace("/", " / ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
    else
      nil
    end
  end

  defp manifest_video_aspect_ratio(_current_video, _settings), do: nil

  defp manifest_has_audio?(audio_tracks, manifest, opts) do
    cond do
      is_list(audio_tracks) and audio_tracks != [] ->
        true

      is_boolean(boolean_value(map_get_any(opts, "has_audio"))) ->
        boolean_value(map_get_any(opts, "has_audio"))

      is_boolean(get_in(manifest, ["video", "audio"])) ->
        get_in(manifest, ["video", "audio"])

      true ->
        true
    end
  end

  defp boolean_value(value) when value in [true, "true", 1, "1"], do: true
  defp boolean_value(value) when value in [false, "false", 0, "0"], do: false
  defp boolean_value(_value), do: nil

  defp truthy?(value), do: value in [true, "true", 1, "1"]

  defp manifest_hls_ready?(manifest, opts, status, current_video) do
    truthy?(map_get_any(opts, "hls_ready")) or status == "ready" or
      Enum.any?(get_in(manifest, ["video", "renditions"]) || [], fn rendition ->
        map_get_any(rendition, "type") == "video" and
          map_get_any(rendition, "container") == "hls"
      end) or completed_hls_master?(current_video)
  end

  # The stored manifest may predate HLS publication. Use the persisted master
  # as durable evidence so later publications can recover without a transient hint.
  defp completed_hls_master?(%Video{id: video_id}) do
    from(r in "renditions",
      where: r.video_id == type(^video_id, MaveCore.Ecto.LegacyShortUUID),
      where: r.type == "video" and r.container == "hls" and is_nil(r.size),
      where: r.progress >= 100
    )
    |> Repo.exists?()
  end

  defp completed_hls_master?(_video), do: false

  defp manifest_video_renditions(%Video{id: video_id}, hls_ready?) do
    from(r in "renditions",
      where: r.video_id == type(^video_id, MaveCore.Ecto.LegacyShortUUID),
      where: r.progress >= 100,
      where: r.type in ["video", "clip_keyframes", "clip"],
      where: not (r.type == "video" and r.container == "hls" and is_nil(r.size)),
      where: ^hls_ready? or r.type != "video" or r.container != "hls",
      order_by: [asc: r.inserted_at, asc: r.type, asc: r.size, asc: r.codec, asc: r.container],
      select: %{
        type: r.type,
        size: r.size,
        codec: r.codec,
        container: r.container,
        file_size: r.file_size
      }
    )
    |> Repo.all()
    |> Enum.map(&stringify_keys/1)
  end

  defp manifest_video_renditions(_, _hls_ready?), do: []

  defp playback_original_url(
         %Video{max_width: width, max_height: height},
         renditions,
         original_url
       )
       when width in [nil, 0] and height in [nil, 0] do
    # Keep an audible fallback for older uploads until a waveform MP4 is available.
    mp4_renditions = Enum.filter(renditions, &(map_get_any(&1, "container") == "mp4"))
    if Enum.any?(mp4_renditions, &playable_video_rendition?/1), do: nil, else: original_url
  end

  defp playback_original_url(_video, renditions, original_url) do
    if Enum.any?(renditions, &playable_video_rendition?/1), do: nil, else: original_url
  end

  defp playable_video_rendition?(rendition) do
    map_get_any(rendition, "type") == "video" and
      map_get_any(rendition, "container") in ["mp4", "hls"]
  end

  defp manifest_poster(%Embed{} = embed, version, current_poster) do
    current_poster = current_poster || %{}

    poster =
      SettingsSerializer.manifest_poster(embed.space, embed, embed.settings, current_poster)

    poster
    |> Map.put("renditions", manifest_poster_renditions(embed))
    |> maybe_put("image_src", preferred_poster_image_src(embed, version) || poster["image_src"])
  end

  defp manifest_poster_renditions(%Embed{asset: %{current_video: %Video{id: video_id}}}) do
    from(r in "renditions",
      where: r.video_id == type(^video_id, MaveCore.Ecto.LegacyShortUUID),
      where: r.progress >= 100,
      where: r.type in ["thumbnail", "poster", "custom_thumbnail"],
      order_by: [asc: r.inserted_at, asc: r.type, asc: r.container],
      select: %{
        type: r.type,
        container: r.container,
        date: fragment("EXTRACT(EPOCH FROM ?)", r.inserted_at),
        file_size: r.file_size
      }
    )
    |> Repo.all()
    |> Enum.map(fn rendition ->
      rendition
      |> Map.update!(:date, &unix_trunc/1)
      |> stringify_keys()
    end)
  end

  defp manifest_poster_renditions(_embed), do: []

  defp preferred_poster_image_src(
         %Embed{asset: %{current_video: %Video{id: video_id}}, space: space, hash: embed_hash},
         version
       ) do
    case preferred_poster_rendition(video_id) do
      {"custom_thumbnail", key} when is_binary(key) and key != "" ->
        bucket = Storage.bucket_for_space(space.hash, space.region)
        SettingsSerializer.storage_object_url(bucket, key)

      {type, _key} when type in ["thumbnail", "poster"] ->
        default_poster_image_src(space.hash, space.region, embed_hash, version)

      _ ->
        default_poster_image_src(space.hash, space.region, embed_hash, version)
    end
  end

  defp preferred_poster_image_src(_embed, _version), do: nil

  defp default_poster_image_src(space_hash, region, embed_hash, version) do
    bucket = Storage.bucket_for_space(space_hash, region)
    _ = version
    SettingsSerializer.storage_object_url(bucket, "#{embed_hash}/thumbnail.jpg")
  end

  defp manifest_audio_tracks(%Embed{} = embed, version, nil) do
    case current_video(embed) do
      %Video{id: video_id} ->
        bucket = Storage.bucket_for_space(embed.space.hash, embed.space.region)

        AudioTrack
        |> where([track], track.video_id == ^video_id)
        |> order_by([track], asc: track.inserted_at)
        |> Repo.all()
        |> Enum.map(&serialize_manifest_audio_track(&1, bucket, embed.hash, version))

      _ ->
        []
    end
  end

  defp manifest_audio_tracks(_embed, _version, tracks) when is_list(tracks) do
    Enum.map(tracks, fn track ->
      track
      |> stringify_keys()
      |> Map.drop([
        "src",
        "hls_src",
        "hls_playlist",
        "hls_file_size",
        "hls_codec",
        "hls_group_id",
        "hls_bandwidth",
        "hls_channels"
      ])
    end)
  end

  defp manifest_audio_tracks(_embed, _version, _tracks), do: []

  defp find_existing_manifest(storage, bucket, embed_hash, version, region) do
    embed_hash
    |> candidate_keys(version)
    |> Enum.find_value(&load_manifest_candidate(storage, bucket, &1, region))
  end

  defp load_manifest_candidate(storage, bucket, {key, manifest_version}, region) do
    case storage.get(bucket, key, region) do
      {:ok, manifest} when is_map(manifest) ->
        {:ok, manifest, manifest_version}

      {:ok, body} ->
        decode_manifest_body(body, manifest_version)

      {:error, :not_found} ->
        nil

      {:error, reason} ->
        {:error, {:manifest_read_failed, reason}}
    end
  end

  defp decode_manifest_body(body, manifest_version) do
    case Jason.decode(body) do
      {:ok, manifest} -> {:ok, manifest, manifest_version}
      {:error, reason} -> {:error, {:manifest_decode_failed, reason}}
    end
  end

  defp preferred_poster_rendition(video_id) do
    from(r in "renditions",
      where: r.video_id == type(^video_id, MaveCore.Ecto.LegacyShortUUID),
      where: r.progress >= 100,
      where: r.container == "jpg",
      where: r.type in ["thumbnail", "custom_thumbnail", "poster"],
      order_by: [
        asc:
          fragment(
            "CASE WHEN ? = 'custom_thumbnail' THEN 0 WHEN ? = 'thumbnail' THEN 1 ELSE 2 END",
            r.type,
            r.type
          ),
        desc: r.inserted_at
      ],
      select: {r.type, r.rendition_key},
      limit: 1
    )
    |> Repo.one()
  end

  defp serialize_manifest_audio_track(track, bucket, embed_hash, version) do
    %{
      "id" => public_shortuuid(track.id),
      "label" => track.label,
      "language" => track.language,
      "default" => track.default,
      "codec" => track.codec,
      "file_size" => track.file_size,
      "filename" => track.filename,
      "path" =>
        SettingsSerializer.storage_object_url(
          bucket,
          audio_track_key(embed_hash, version, track.filename)
        )
    }
  end

  defp audio_track_key(embed_hash, version, filename) when version > 0 do
    "#{embed_hash}/v#{version}/#{filename}"
  end

  defp audio_track_key(embed_hash, _version, filename) do
    "#{embed_hash}/#{filename}"
  end

  defp manifest_subtitles(%Embed{} = embed, version) do
    bucket = Storage.bucket_for_space(embed.space.hash, embed.space.region)

    embed
    |> Embeds.get_subtitles()
    |> Enum.filter(&is_binary(&1.language))
    |> Enum.map(fn subtitle ->
      %{
        "language" => subtitle.language,
        "label" => Languages.spoken_language(subtitle.language),
        "path" =>
          subtitle_public_url(
            bucket,
            subtitle.path,
            embed.hash,
            version,
            subtitle.language,
            subtitle.updated_at || subtitle.inserted_at
          )
      }
    end)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp unix_trunc(%Decimal{} = value), do: value |> Decimal.to_float() |> trunc()
  defp unix_trunc(value) when is_float(value), do: trunc(value)
  defp unix_trunc(value) when is_integer(value), do: value

  defp candidate_keys(embed_hash, version) do
    if version > 0 do
      [
        {"#{embed_hash}/v#{version}/manifest.json", version},
        {"#{embed_hash}/manifest.json", 0}
      ]
    else
      [{"#{embed_hash}/manifest.json", 0}]
    end
  end

  defp public_shortuuid(id) when is_binary(id) do
    case LegacyShortUUID.encode(id) do
      {:ok, shortuuid} -> shortuuid
      {:error, _reason} -> id
    end
  end

  defp public_shortuuid(id), do: id

  defp subtitle_public_url(bucket, path, embed_hash, version, language, updated_at) do
    cond do
      is_binary(path) and
          (String.starts_with?(path, "http://") or String.starts_with?(path, "https://")) ->
        path

      is_binary(path) and path != "" ->
        bucket
        |> SettingsSerializer.storage_object_url(path)
        |> with_subtitle_cache_buster(updated_at)

      true ->
        key =
          if version > 0 do
            "#{embed_hash}/v#{version}/subtitle_#{language}.vtt"
          else
            "#{embed_hash}/subtitle_#{language}.vtt"
          end

        bucket
        |> SettingsSerializer.storage_object_url(key)
        |> with_subtitle_cache_buster(updated_at)
    end
  end

  defp with_subtitle_cache_buster(url, %DateTime{} = updated_at) do
    "#{url}?e=#{DateTime.to_unix(updated_at, :microsecond)}"
  end

  defp with_subtitle_cache_buster(url, _updated_at), do: url
end
