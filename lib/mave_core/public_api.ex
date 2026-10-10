defmodule MaveCore.PublicApi do
  @moduledoc false

  import Ecto.Query, warn: false

  alias MaveCore.Assets.{AudioTrack, Subtitle, Video}
  alias MaveCore.Collections.CollectionEmbed
  alias MaveCore.Embeds
  alias MaveCore.Embeds.{Embed, Events, SettingsSerializer}
  alias MaveCore.Flow
  alias MaveCore.Languages
  alias MaveCore.Media.Storage
  alias MaveCore.Playback.Media, as: PlaybackMedia
  alias MaveCore.Playback.URLs
  alias MaveCore.PublicHttpUrl
  alias MaveCore.Repo
  alias MaveCore.Spaces.Space

  @default_per_page 15
  @max_per_page 100

  def get_embed_by_hash(%Space{} = space, hash) when is_binary(hash) do
    from(e in Embed,
      left_join: a in assoc(e, :asset),
      left_join: v in assoc(a, :current_video),
      left_join: c in assoc(e, :collection),
      left_join: s in assoc(e, :settings),
      where: e.space_id == ^space.id and e.hash == ^hash and is_nil(e.deleted_at),
      preload: [asset: {a, [current_video: v]}, collection: c, settings: s]
    )
    |> Repo.one()
  end

  def get_embed(%Space{} = space, identifier) when is_binary(identifier) do
    case get_embed_by_hash(space, identifier) do
      %Embed{} = embed ->
        embed

      nil ->
        case public_id_to_hash(space, identifier) do
          nil -> nil
          hash -> get_embed_by_hash(space, hash)
        end
    end
  end

  def resolve_collection_id(%Space{} = _space, nil), do: {:ok, nil}
  def resolve_collection_id(%Space{} = _space, ""), do: {:ok, nil}

  def resolve_collection_id(%Space{} = space, collection_hash) when is_binary(collection_hash) do
    case resolve_collection_embed(space, collection_hash) do
      {:ok, %Embed{collection_id: collection_id}} when is_binary(collection_id) ->
        {:ok, collection_id}

      _ ->
        {:error, "This collection does not seem to be part of your space."}
    end
  end

  def resolve_collection_embed(%Space{} = _space, nil), do: {:ok, nil}
  def resolve_collection_embed(%Space{} = _space, ""), do: {:ok, nil}

  def resolve_collection_embed(%Space{} = space, collection_hash)
      when is_binary(collection_hash) do
    case get_embed(space, collection_hash) do
      %Embed{type: :collection} = embed ->
        {:ok, embed}

      _ ->
        {:error, "This collection does not seem to be part of your space."}
    end
  end

  def list_videos(%Space{} = space, opts \\ []) do
    types =
      if Keyword.get(opts, :show_collections, false), do: [:video, :collection], else: [:video]

    list_embeds(space, Keyword.put(opts, :types, types))
  end

  def count_videos(%Space{} = space, opts \\ []) do
    types =
      if Keyword.get(opts, :show_collections, false), do: [:video, :collection], else: [:video]

    count_embeds(space, Keyword.put(opts, :types, types))
  end

  def list_collections(%Space{} = space, opts \\ []) do
    list_embeds(space, Keyword.put(opts, :types, [:collection]))
  end

  def count_collections(%Space{} = space, opts \\ []) do
    count_embeds(space, Keyword.put(opts, :types, [:collection]))
  end

  def jwt_collection_response(%Space{} = space, root, embed_identifier \\ nil) do
    with {:ok, root} <- resolve_jwt_collection_root(space, root),
         {:ok, collection_root} <-
           maybe_resolve_jwt_nested_collection(space, root, embed_identifier) do
      items = list_jwt_collection_items(space, collection_root)

      videos =
        items
        |> Enum.filter(&video_with_current_video?/1)
        |> Enum.map(&video_response(space, &1))

      collections =
        items
        |> Enum.filter(&match?(%Embed{type: :collection}, &1))
        |> Enum.map(&collection_response(space, &1))

      embeds =
        items
        |> Enum.filter(&video_with_current_video?/1)
        |> Enum.map(&embed_payload(space, &1))

      {:ok,
       %{
         name: jwt_collection_name(collection_root),
         embeds: embeds,
         videos: videos,
         collections: collections,
         metrics_key: nil
       }}
    end
  end

  def jwt_scoped_video_deletable?(%Space{} = space, %Embed{type: :video} = embed, root) do
    case resolve_jwt_collection_root(space, root) do
      {:ok, nil} ->
        embed.space_id == space.id

      {:ok, %Embed{type: :collection} = root_embed} ->
        embed_in_collection_scope?(embed, root_embed)

      _ ->
        false
    end
  end

  def video_response(%Space{} = space, %Embed{type: :video} = embed) do
    current_video = current_video(embed)

    if embed.version == 2 do
      %{
        id: public_embed_id(space, embed),
        visibility: embed.playback_visibility,
        visibility_status: embed.playback_status,
        sources: playback_sources(space, embed, current_video),
        name: embed_name(embed),
        duration: current_video && current_video.duration,
        width: current_video && current_video.max_width,
        height: current_video && current_video.max_height,
        size: current_video && current_video.original_file_size,
        poster_image: poster_image(space, embed),
        object: "video",
        last_upload: maybe_unix(current_video && current_video.inserted_at),
        language: current_video && current_video.language,
        created: maybe_unix(embed.inserted_at),
        subtitles: subtitle_languages(embed),
        renditions: video_renditions(current_video)
      }
    else
      %{
        id: public_embed_id(space, embed),
        visibility: embed.playback_visibility,
        visibility_status: embed.playback_status,
        sources: playback_sources(space, embed, current_video),
        embed_url: embed_url(space, embed),
        poster_image: poster_image(space, embed),
        object: "video",
        last_upload: maybe_unix(current_video && current_video.inserted_at),
        created: maybe_unix(embed.inserted_at)
      }
    end
  end

  def webhook_video_response(%Space{} = space, %Embed{type: :video} = embed) do
    current_video = current_video(embed)

    if embed.version == 2 do
      %{
        id: public_embed_id(space, embed),
        name: embed_name(embed),
        duration: current_video && current_video.duration,
        width: current_video && current_video.max_width,
        height: current_video && current_video.max_height,
        size: current_video && current_video.original_file_size,
        poster_image: poster_image(space, embed),
        object: "video",
        last_upload: maybe_unix(current_video && current_video.inserted_at),
        language: current_video && current_video.language,
        created: maybe_unix(embed.inserted_at),
        subtitles: subtitle_languages(embed),
        renditions: video_renditions(current_video)
      }
    else
      %{
        id: public_embed_id(space, embed),
        embed_url: embed_url(space, embed),
        poster_image: poster_image(space, embed),
        object: "video",
        last_upload: maybe_unix(current_video && current_video.inserted_at),
        created: maybe_unix(embed.inserted_at)
      }
    end
  end

  def collection_response(%Space{} = space, %Embed{type: :collection} = embed) do
    counts = Embeds.folder_video_counts(space, [embed.id])

    %{
      id: public_embed_id(space, embed),
      name: folder_name(embed),
      video_count: Map.get(counts, embed.id, 0),
      object: "collection",
      created: maybe_unix(embed.inserted_at)
    }
  end

  def list_response(data, page, per_page, total_items) do
    total_pages = pages(total_items, per_page)

    %{
      object: "list",
      data: data,
      total_pages: total_pages,
      current_page: page,
      total_items: total_items,
      has_more: page != total_pages
    }
  end

  def pages(count, per_page \\ @default_per_page) do
    per_page = normalize_per_page(per_page)
    ceil(count / per_page)
  end

  def start_input_url_upload(%Space{} = space, %Embed{} = embed, input_url, params \\ %{})
      when is_binary(input_url) and input_url != "" and is_map(params) do
    with {:ok, updated_embed} <-
           Embeds.begin_video_upload(space.hash, embed.hash, %{
             "title" => input_url_title(input_url, params),
             "source_url" => input_url,
             "content_type" => Map.get(params, "filetype") || Map.get(params, "content_type")
           }),
         {:ok, _run} <-
           Flow.start_run(
             remote_input_template(space),
             build_run_input(space, updated_embed, input_url, params),
             []
           ) do
      Events.broadcast_updated(updated_embed.space_id, updated_embed.id, %{"status" => "queued"})
      :ok
    end
  end

  def validate_input_url(input_url) when is_binary(input_url) and input_url != "" do
    case input_url_probe_options(input_url) do
      {:ok, req_options} -> probe_input_url(req_options)
      {:error, reason} -> {:error, input_url_validation_error(reason)}
    end
  end

  def validate_input_url(_input_url), do: {:error, "input_url is required."}

  defp input_url_title(input_url, params) do
    case Map.get(params, "name") do
      name when is_binary(name) and name != "" -> name
      _ -> Path.basename(input_url)
    end
  end

  defp list_embeds(%Space{} = space, opts) do
    page = normalize_page(Keyword.get(opts, :page, 1))
    per_page = normalize_per_page(Keyword.get(opts, :per_page))

    query =
      case Keyword.get(opts, :collection_id) do
        collection_id when is_binary(collection_id) ->
          collection_query(space, collection_id, opts)

        _ ->
          root_query(space, opts)
      end

    query
    |> offset(^((page - 1) * per_page))
    |> limit(^per_page)
    |> Repo.all()
  end

  defp list_jwt_collection_items(%Space{} = space, nil) do
    space
    |> root_query(types: [:video, :collection], archived: false)
    |> Repo.all()
  end

  defp list_jwt_collection_items(%Space{} = space, %Embed{collection_id: collection_id})
       when is_binary(collection_id) do
    space
    |> collection_query(collection_id, types: [:video, :collection], archived: false)
    |> Repo.all()
  end

  defp list_jwt_collection_items(_space, _root), do: []

  defp input_url_probe_options(input_url) do
    PublicHttpUrl.req_options(input_url,
      method: :get,
      headers: [{"range", "bytes=0-0"}],
      into: &halt_after_first_chunk/2,
      retry: false,
      connect_options: [timeout: 5_000],
      receive_timeout: 10_000
    )
  end

  defp probe_input_url(req_options) do
    case Req.request(req_options) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{}} ->
        {:error, "Could not fetch input_url."}

      {:error, _reason} ->
        {:error, "Could not fetch input_url."}
    end
  end

  defp halt_after_first_chunk({:data, _data}, acc), do: {:halt, acc}

  defp input_url_validation_error(:invalid_http_url),
    do: "input_url must be a valid http or https URL."

  defp input_url_validation_error({:blocked_address, _address}),
    do: "input_url host is not allowed."

  defp input_url_validation_error(_reason), do: "Could not fetch input_url."

  defp count_embeds(%Space{} = space, opts) do
    case Keyword.get(opts, :collection_id) do
      collection_id when is_binary(collection_id) ->
        collection_count_query(space, collection_id, opts)

      _ ->
        root_count_query(space, opts)
    end
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp root_query(%Space{} = space, opts) do
    types = Keyword.get(opts, :types, [:video])
    uploaded = Keyword.get(opts, :uploaded)
    archived = Keyword.get(opts, :archived, false)
    in_collection_ids = from(ce in CollectionEmbed, select: ce.embed_id)

    from(e in Embed,
      left_join: a in assoc(e, :asset),
      left_join: v in assoc(a, :current_video),
      left_join: c in assoc(e, :collection),
      left_join: s in assoc(e, :settings),
      where: e.space_id == ^space.id,
      where: e.type in ^types and is_nil(e.deleted_at),
      order_by: [desc: e.inserted_at],
      preload: [asset: {a, [current_video: v]}, collection: c, settings: s]
    )
    |> maybe_filter_root_membership(archived, in_collection_ids)
    |> maybe_filter_uploaded_root(uploaded)
    |> filter_archived_root(archived)
  end

  defp root_count_query(%Space{} = space, opts) do
    types = Keyword.get(opts, :types, [:video])
    uploaded = Keyword.get(opts, :uploaded)
    archived = Keyword.get(opts, :archived, false)
    in_collection_ids = from(ce in CollectionEmbed, select: ce.embed_id)

    from(e in Embed,
      left_join: a in assoc(e, :asset),
      left_join: v in assoc(a, :current_video),
      where: e.space_id == ^space.id,
      where: e.type in ^types and is_nil(e.deleted_at),
      select: count(e.id)
    )
    |> maybe_filter_root_membership(archived, in_collection_ids)
    |> maybe_filter_uploaded_root(uploaded)
    |> filter_archived_root(archived)
  end

  defp collection_query(%Space{} = space, collection_id, opts) do
    types = Keyword.get(opts, :types, [:video])
    uploaded = Keyword.get(opts, :uploaded)
    archived = Keyword.get(opts, :archived, false)

    from(e in Embed,
      join: ce in CollectionEmbed,
      on: ce.embed_id == e.id,
      left_join: a in assoc(e, :asset),
      left_join: v in assoc(a, :current_video),
      left_join: c in assoc(e, :collection),
      left_join: s in assoc(e, :settings),
      where: ce.collection_id == ^collection_id,
      where: e.space_id == ^space.id,
      where: e.type in ^types and is_nil(e.deleted_at),
      order_by: [desc: e.inserted_at],
      preload: [asset: {a, [current_video: v]}, collection: c, settings: s]
    )
    |> maybe_filter_uploaded_collection(uploaded)
    |> filter_archived_collection(archived)
  end

  defp collection_count_query(%Space{} = space, collection_id, opts) do
    types = Keyword.get(opts, :types, [:video])
    uploaded = Keyword.get(opts, :uploaded)
    archived = Keyword.get(opts, :archived, false)

    from(e in Embed,
      join: ce in CollectionEmbed,
      on: ce.embed_id == e.id,
      left_join: a in assoc(e, :asset),
      left_join: v in assoc(a, :current_video),
      where: ce.collection_id == ^collection_id,
      where: e.space_id == ^space.id,
      where: e.type in ^types and is_nil(e.deleted_at),
      select: count(e.id)
    )
    |> maybe_filter_uploaded_collection(uploaded)
    |> filter_archived_collection(archived)
  end

  defp maybe_filter_root_membership(query, _archived, in_collection_ids) do
    where(query, [e, _a, _v, _c, _s], e.id not in subquery(in_collection_ids))
  end

  defp maybe_filter_uploaded_root(query, true),
    do: where(query, [_e, _a, v, _c, _s], not is_nil(v.id))

  defp maybe_filter_uploaded_root(query, false),
    do: where(query, [_e, _a, v, _c, _s], is_nil(v.id))

  defp maybe_filter_uploaded_root(query, _uploaded), do: query

  defp maybe_filter_uploaded_collection(query, true),
    do: where(query, [_e, _ce, _a, v, _c, _s], not is_nil(v.id))

  defp maybe_filter_uploaded_collection(query, false),
    do: where(query, [_e, _ce, _a, v, _c, _s], is_nil(v.id))

  defp maybe_filter_uploaded_collection(query, _uploaded), do: query

  defp filter_archived_root(query, true),
    do: where(query, [e, _a, _v, _c, _s], e.archived == true)

  defp filter_archived_root(query, _archived),
    do: where(query, [e, _a, _v, _c, _s], e.archived == false)

  defp filter_archived_collection(query, true),
    do: where(query, [e, _ce, _a, _v, _c, _s], e.archived == true)

  defp filter_archived_collection(query, _archived),
    do: where(query, [e, _ce, _a, _v, _c, _s], e.archived == false)

  defp normalize_page(page) when is_integer(page) and page > 0, do: page
  defp normalize_page(_page), do: 1

  defp normalize_per_page(per_page) when is_integer(per_page) and per_page > 0 do
    min(per_page, @max_per_page)
  end

  defp normalize_per_page(_per_page), do: @default_per_page

  defp public_embed_id(%Space{} = space, %Embed{version: 2} = embed),
    do: SettingsSerializer.public_embed_id(space, embed)

  defp public_embed_id(_space, %Embed{hash: hash}), do: hash

  defp embed_url(%Space{} = space, %Embed{} = embed) do
    SettingsSerializer.iframe_url(space, embed)
    |> String.replace_suffix("/player.html", "")
  end

  defp poster_image(%Space{} = space, %Embed{} = embed) do
    if MaveCore.Playback.protected?(embed),
      do: playback_source_url(space, embed, "thumbnail.jpg"),
      else: SettingsSerializer.preview_poster_url(space, embed, embed.settings)
  end

  defp playback_sources(_space, _embed, nil), do: []

  defp playback_sources(space, embed, %Video{id: video_id}) do
    renditions =
      from(r in "renditions",
        where: r.video_id == type(^video_id, MaveCore.Ecto.LegacyShortUUID),
        where: r.type == "video" and r.progress >= 100,
        where: r.container in ["hls", "mp4", "webm"],
        order_by: [r.container, r.size, r.codec],
        select: %{container: r.container, key: r.rendition_key}
      )
      |> Repo.all()

    hls =
      if Enum.any?(renditions, &(&1.container == "hls")),
        do: [
          %{
            type: "application/x-mpegURL",
            src: playback_source_url(space, embed, "playlist.m3u8")
          }
        ],
        else: []

    files =
      for %{container: container, key: key} <- renditions,
          container in ["mp4", "webm"],
          is_binary(key),
          String.starts_with?(key, embed.hash <> "/"),
          path = String.replace_prefix(key, embed.hash <> "/", ""),
          PlaybackMedia.valid_path(path) == :ok do
        %{type: "video/" <> container, src: playback_source_url(space, embed, path)}
      end

    Enum.uniq(hls ++ files)
  end

  defp playback_source_url(space, embed, path) do
    if MaveCore.Playback.protected?(embed) do
      endpoint = SettingsSerializer.component_runtime_config()["cdn"]["playback_endpoint"]
      URLs.media_url(endpoint, space.hash, embed.hash, path)
    else
      bucket = Storage.bucket_for_space(space.hash, space.region)
      SettingsSerializer.storage_object_url(bucket, embed.hash <> "/" <> path)
    end
  end

  defp video_renditions(nil), do: []

  defp video_renditions(%Video{id: video_id}) do
    sizes = ~w(sd hd fhd qhd uhd)

    from(r in "renditions",
      where: r.video_id == type(^video_id, MaveCore.Ecto.LegacyShortUUID),
      where: r.type == "video" and r.progress >= 100,
      where: r.size in ^sizes,
      select: r.size
    )
    |> Repo.all()
    |> Enum.uniq()
    |> Enum.sort_by(&Enum.find_index(sizes, fn size -> size == &1 end))
  end

  defp embed_name(%Embed{} = embed) do
    asset_name =
      case embed.asset do
        %{name: name} when is_binary(name) and name != "" -> name
        _ -> nil
      end

    file_name =
      case current_video(embed) do
        %{file_name: file_name} when is_binary(file_name) and file_name != "" -> file_name
        _ -> nil
      end

    asset_name || file_name || "Untitled"
  end

  defp folder_name(%Embed{} = embed) do
    case embed.collection do
      %{name: name} when is_binary(name) and name != "" -> name
      _ -> "Untitled"
    end
  end

  defp current_video(%Embed{} = embed) do
    case embed.asset do
      %{current_video: current_video} -> current_video
      _ -> nil
    end
  end

  defp current_video(_embed), do: nil

  defp embed_payload(%Space{} = space, %Embed{type: :video} = embed) do
    current_video = current_video(embed)
    version = current_video_version(embed)

    %{
      id: public_embed_id(space, embed),
      name: embed_name(embed),
      space_id: space.hash,
      created_at: maybe_unix(embed.inserted_at),
      video: %{
        id: current_video && current_video.id,
        version: version,
        aspect_ratio: current_video && current_video.aspect_ratio,
        src: nil,
        original: nil,
        language: current_video && current_video.language,
        size: current_video && current_video.original_file_size,
        duration: current_video && current_video.duration,
        sources: [],
        filetype: filetype(current_video),
        max_width: current_video && current_video.max_width,
        max_height: current_video && current_video.max_height,
        renditions: detailed_video_renditions(current_video),
        audio: nil,
        status: current_video && current_video.status,
        ready: video_ready?(current_video)
      },
      settings: %{
        aspect_ratio: nil,
        width: nil,
        height: nil,
        loop: nil,
        autoplay: nil,
        color: nil,
        opacity: nil,
        controls: "full",
        poster: nil
      },
      poster: %{
        renditions: detailed_poster_renditions(current_video),
        type: nil,
        initial_frame_src: nil,
        image_src: poster_image(space, embed),
        video_src: nil
      },
      subtitles: detailed_subtitles(space, embed, version),
      audio_tracks: detailed_audio_tracks(space, embed, version)
    }
  end

  defp detailed_video_renditions(nil), do: nil

  defp detailed_video_renditions(%Video{id: video_id}) do
    from(r in "renditions",
      where: r.video_id == type(^video_id, MaveCore.Ecto.LegacyShortUUID),
      where: r.type in ["video", "clip_keyframes", "clip"] and r.progress >= 100,
      select: %{
        size: r.size,
        codec: r.codec,
        container: r.container,
        type: r.type,
        file_size: r.file_size
      }
    )
    |> Repo.all()
  end

  defp detailed_poster_renditions(nil), do: nil

  defp detailed_poster_renditions(%Video{id: video_id}) do
    from(r in "renditions",
      where: r.video_id == type(^video_id, MaveCore.Ecto.LegacyShortUUID),
      where: r.type in ["thumbnail", "poster", "custom_thumbnail"] and r.progress >= 100,
      select: %{
        container: r.container,
        type: r.type,
        date: r.inserted_at,
        file_size: r.file_size
      }
    )
    |> Repo.all()
    |> Enum.map(fn rendition -> %{rendition | date: maybe_unix(rendition.date)} end)
  end

  defp detailed_audio_tracks(%Space{} = space, %Embed{} = embed, version) do
    embed
    |> Embeds.get_audio_tracks()
    |> Enum.map(fn %AudioTrack{} = track ->
      key =
        if version > 0 do
          "#{embed.hash}/v#{version}/#{track.filename}"
        else
          "#{embed.hash}/#{track.filename}"
        end

      %{
        id: track.id,
        label: track.label,
        language: track.language,
        default: track.default,
        codec: track.codec,
        file_size: track.file_size,
        filename: track.filename,
        path: SettingsSerializer.storage_object_url("space-#{space.hash}", key)
      }
    end)
  end

  defp detailed_subtitles(%Space{} = space, %Embed{} = embed, version) do
    embed
    |> Embeds.get_subtitles()
    |> Enum.filter(&is_binary(&1.language))
    |> Enum.map(fn %Subtitle{} = subtitle ->
      %{
        language: subtitle.language,
        path: subtitle_public_url(space, embed, version, subtitle),
        label: Languages.spoken_language(subtitle.language)
      }
    end)
  end

  defp subtitle_public_url(%Space{} = space, %Embed{} = embed, version, %{
         path: path,
         language: language
       }) do
    cond do
      external_url?(path) ->
        path

      is_binary(path) and path != "" ->
        SettingsSerializer.storage_object_url("space-#{space.hash}", path)

      true ->
        key =
          if version > 0 do
            "#{embed.hash}/v#{version}/subtitle_#{language}.vtt"
          else
            "#{embed.hash}/subtitle_#{language}.vtt"
          end

        SettingsSerializer.storage_object_url("space-#{space.hash}", key)
    end
  end

  defp external_url?(value) when is_binary(value),
    do: String.starts_with?(value, "http://") or String.starts_with?(value, "https://")

  defp external_url?(_value), do: false

  defp video_ready?(%Video{status: status}), do: status in ["ready", "playable"]
  defp video_ready?(_video), do: false

  defp filetype(%Video{file_name: file_name}) when is_binary(file_name) do
    file_name
    |> Path.extname()
    |> String.trim_leading(".")
    |> case do
      "" -> nil
      ext -> ext
    end
  end

  defp filetype(_video), do: nil

  defp video_with_current_video?(%Embed{type: :video} = embed),
    do: match?(%Video{}, current_video(embed))

  defp video_with_current_video?(_embed), do: false

  defp resolve_jwt_collection_root(%Space{} = _space, nil), do: {:ok, nil}
  defp resolve_jwt_collection_root(%Space{} = _space, ""), do: {:ok, nil}

  defp resolve_jwt_collection_root(%Space{} = _space, %Embed{type: :collection} = embed),
    do: {:ok, embed}

  defp resolve_jwt_collection_root(%Space{} = space, identifier) when is_binary(identifier) do
    cond do
      identifier in [space.id, space.hash] ->
        {:ok, nil}

      collection_embed = get_embed(space, identifier) ->
        case collection_embed do
          %Embed{type: :collection} -> {:ok, collection_embed}
          _embed -> {:error, "Invalid JWT or collection id (either invalid sub or API key)"}
        end

      true ->
        {:error, "Invalid JWT or collection id (either invalid sub or API key)"}
    end
  end

  defp maybe_resolve_jwt_nested_collection(%Space{} = _space, root, nil), do: {:ok, root}
  defp maybe_resolve_jwt_nested_collection(%Space{} = _space, root, ""), do: {:ok, root}

  defp maybe_resolve_jwt_nested_collection(%Space{} = space, nil, identifier) do
    case get_embed(space, identifier) do
      %Embed{type: :collection} = embed ->
        {:ok, embed}

      _ ->
        {:error, "Invalid JWT or collection id (either invalid sub or API key)"}
    end
  end

  defp maybe_resolve_jwt_nested_collection(%Space{} = space, %Embed{} = root, identifier) do
    case get_embed(space, identifier) do
      %Embed{type: :collection} = embed ->
        if direct_child_of_collection?(embed, root.collection_id) do
          {:ok, embed}
        else
          {:error, "Collection is not part of the specified root collection in JWT"}
        end

      _ ->
        {:error, "Invalid JWT or collection id (either invalid sub or API key)"}
    end
  end

  defp jwt_collection_name(nil), do: ""

  defp jwt_collection_name(%Embed{} = embed), do: folder_name(embed)

  defp embed_in_collection_scope?(%Embed{id: embed_id}, %Embed{collection_id: root_collection_id})
       when is_binary(embed_id) and is_binary(root_collection_id) do
    direct_child_of_collection?(embed_id, root_collection_id) or
      child_of_nested_collection?(embed_id, root_collection_id)
  end

  defp embed_in_collection_scope?(_embed, _root), do: false

  defp direct_child_of_collection?(%Embed{id: embed_id}, collection_id),
    do: direct_child_of_collection?(embed_id, collection_id)

  defp direct_child_of_collection?(embed_id, collection_id)
       when is_binary(embed_id) and is_binary(collection_id) do
    from(ce in CollectionEmbed,
      where: ce.embed_id == ^embed_id and ce.collection_id == ^collection_id
    )
    |> Repo.exists?()
  end

  defp direct_child_of_collection?(_embed_id, _collection_id), do: false

  defp child_of_nested_collection?(embed_id, root_collection_id)
       when is_binary(embed_id) and is_binary(root_collection_id) do
    from(child in CollectionEmbed,
      join: folder in Embed,
      on: folder.collection_id == child.collection_id,
      join: parent in CollectionEmbed,
      on: parent.embed_id == folder.id,
      where: child.embed_id == ^embed_id,
      where: parent.collection_id == ^root_collection_id,
      where: folder.type == :collection and is_nil(folder.deleted_at)
    )
    |> Repo.exists?()
  end

  defp child_of_nested_collection?(_embed_id, _root_collection_id), do: false

  defp subtitle_languages(%Embed{} = embed) do
    embed
    |> Embeds.get_subtitles()
    |> Enum.map(& &1.language)
    |> Enum.filter(&is_binary/1)
  end

  defp current_video_version(%Embed{} = embed) do
    case current_video(embed) do
      %Video{} = video -> current_video_version(video)
      _ -> 0
    end
  end

  defp current_video_version(%Video{inserted_at: inserted_at, asset_id: asset_id}) do
    Video
    |> where([video], video.asset_id == ^asset_id and video.inserted_at <= ^inserted_at)
    |> Repo.aggregate(:count)
    |> Kernel.-(1)
    |> max(0)
  end

  defp public_id_to_hash(%Space{hash: space_hash}, identifier) when is_binary(identifier) do
    if String.starts_with?(identifier, space_hash) and
         byte_size(identifier) > byte_size(space_hash) do
      binary_part(
        identifier,
        byte_size(space_hash),
        byte_size(identifier) - byte_size(space_hash)
      )
    end
  end

  defp maybe_unix(nil), do: nil
  defp maybe_unix(%DateTime{} = datetime), do: DateTime.to_unix(datetime)

  defp maybe_unix(%NaiveDateTime{} = datetime),
    do: DateTime.from_naive!(datetime, "Etc/UTC") |> DateTime.to_unix()

  defp default_template(%Space{default_flow_template: template})
       when is_binary(template) and template != "",
       do: template

  defp default_template(_space) do
    Application.get_env(:mave_core, :upload, [])
    |> Keyword.get(:default_template, "publish_default")
  end

  defp remote_input_template(space) do
    case default_template(space) do
      "publish_default" -> "publish_remote"
      "publish_local" -> "publish_remote_local"
      template -> template
    end
  end

  defp build_run_input(%Space{} = space, %Embed{} = embed, input_url, params) do
    %{
      "space_hash" => space.hash,
      "embed_hash" => embed.hash,
      "region" => space.region,
      "input_url" => input_url,
      "source_url" => input_url,
      "source_content_type" => Map.get(params, "filetype") || Map.get(params, "content_type"),
      "language" => Map.get(params, "language"),
      "priority" => input_url_priority(space, params),
      "durable_source_required" => true,
      "version" => current_video_version(embed)
    }
  end

  defp input_url_priority(%Space{} = space, params) do
    Application.get_env(:mave_core, :public_api_input_url_priority_provider)
    |> dispatch_input_url_priority(space, params)
    |> normalize_input_url_priority()
  end

  defp dispatch_input_url_priority({module, function}, %Space{} = space, params)
       when is_atom(module) and is_atom(function) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, 2) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(module, function, [space, params])
    end
  end

  defp dispatch_input_url_priority(module, %Space{} = space, params) when is_atom(module) do
    if Code.ensure_loaded?(module) and
         function_exported?(module, :public_api_input_url_priority, 2) do
      module.public_api_input_url_priority(space, params)
    end
  end

  defp dispatch_input_url_priority(_provider, _space, _params), do: nil

  defp normalize_input_url_priority(priority)
       when priority in ["high", "urgent", "normal", "default", "import", "low", "background"],
       do: priority

  defp normalize_input_url_priority(priority)
       when priority in [:high, :urgent, :normal, :default, :import, :low, :background],
       do: Atom.to_string(priority)

  defp normalize_input_url_priority(_priority), do: "low"
end
