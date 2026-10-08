defmodule MaveCore.Embeds do
  @moduledoc """
  Dashboard read/write helpers for video and folder pages.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias MaveCore.Analytics.Video, as: VideoAnalytics
  alias MaveCore.Assets.{Asset, AudioTrack, Video}
  alias MaveCore.Collections.{Collection, CollectionEmbed}
  alias MaveCore.EmbedId
  alias MaveCore.Embeds.{Embed, EmbedSettings, Events, ManifestPublisher, SettingsSerializer}
  alias MaveCore.Flow.{Definition, Run, StepRun}
  alias MaveCore.Languages
  alias MaveCore.LegacyShortUUID
  alias MaveCore.Media.RenditionSizing
  alias MaveCore.Media.Storage
  alias MaveCore.Repo
  alias MaveCore.Spaces
  alias MaveCore.Spaces.Space
  alias MaveCore.UsageLimits

  @embed_hash_regex ~r/^[0-9A-Za-z]{10}$/
  @hash_chars "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
  @hash_length 10
  @settings_fields EmbedSettings.dashboard_fields()
  @search_suggestion_limit 8

  @resolution_labels %{
    {176, 144} => "QCIF",
    {352, 240} => "240p",
    {426, 240} => "240p",
    {352, 288} => "CIF",
    {640, 360} => "360p",
    {640, 480} => "480p",
    {854, 480} => "480p",
    {704, 576} => "576i",
    {720, 480} => "480i",
    {1280, 720} => "720p",
    {1440, 1080} => "HDV",
    {1920, 1080} => "1080p",
    {2560, 1440} => "2k",
    {3200, 1800} => "1800p",
    {3840, 2160} => "4k",
    {5120, 2880} => "5K",
    {7680, 4320} => "8K",
    {10_240, 5760} => "10K"
  }

  @size_labels %{
    "sd" => "480p",
    "hd" => "720p",
    "fhd" => "1080p",
    "qhd" => "2k",
    "uhd" => "4k"
  }

  @codec_labels %{
    "h264" => "H.264",
    "hevc" => "H.265",
    "h265" => "H.265",
    "av1" => "AV1",
    "vp9" => "VP9",
    "jpg" => "JPG",
    "webp" => "WEBP",
    "png" => "PNG"
  }
  @ready_video_statuses ~w(ready playable)
  @dashboard_per_page 15
  @hls_transcode_phase_complete_progress 85.0
  @hls_combined_progress_cap 99.0

  @type dashboard_tab :: :all | :archive

  @spec create_video_embed(Space.t(), map()) ::
          {:ok, Embed.t()} | {:error, Changeset.t() | term()}
  def create_video_embed(%Space{} = space, attrs \\ %{}) when is_map(attrs) do
    archived =
      case Map.get(attrs, :archived, Map.get(attrs, "archived", false)) do
        value when value in [true, "true", 1, "1"] -> true
        _ -> false
      end

    name = Map.get(attrs, :name) || Map.get(attrs, "name")

    parent_folder_id = parent_folder_id(attrs)

    Repo.transaction(fn ->
      with {:ok, current_space} <- lock_active_space(space.id),
           :ok <- UsageLimits.can_create_video_embed?(current_space),
           {:ok, asset} <-
             %Asset{}
             |> Asset.changeset(%{space_id: current_space.id, name: name})
             |> Repo.insert(),
           {:ok, embed} <-
             %Embed{}
             |> Embed.changeset(%{
               space_id: current_space.id,
               asset_id: asset.id,
               hash: generate_hash(),
               type: :video,
               version: 2,
               archived: archived
             })
             |> Repo.insert(),
           :ok <- maybe_attach_to_parent(embed, current_space.id, parent_folder_id) do
        preload_embed(embed)
      else
        {:error, %Changeset{} = changeset} -> Repo.rollback(changeset)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> maybe_enqueue_embed_event(space, :video_created)
    |> maybe_broadcast_embed_updated(%{"action" => "created"})
  end

  defp lock_active_space(space_id) do
    Space
    |> where([space], space.id == ^space_id and is_nil(space.deleted_at))
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> case do
      %Space{} = space -> {:ok, space}
      nil -> {:error, :space_deleted}
    end
  end

  @spec begin_video_upload(String.t(), String.t(), map()) :: {:ok, Embed.t()} | {:error, term()}
  def begin_video_upload(space_hash, embed_hash, attrs \\ %{})
      when is_binary(space_hash) and is_binary(embed_hash) and is_map(attrs) do
    case get_embed_by_hashes(space_hash, embed_hash) do
      %Embed{type: :video} = embed ->
        embed = preload_embed(embed)

        Repo.transaction(fn ->
          asset_name = upload_asset_name(Map.get(attrs, "title") || Map.get(attrs, :title))
          file_name = upload_file_name(Map.get(attrs, "title") || Map.get(attrs, :title))
          maybe_update_upload_asset_name(embed, asset_name)
          maybe_reset_upload_replacement(embed)

          video = create_upload_video!(embed.asset_id, attrs, file_name)
          set_current_video!(embed.asset, video.id)

          reload_embed(embed.id)
        end)
        |> unwrap_repo_result()
        |> maybe_broadcast_embed_updated(%{"status" => "uploading"})

      %Embed{} ->
        {:error, :invalid_type}

      nil ->
        {:error, :not_found}
    end
  end

  @spec create_folder_embed(Space.t(), map()) :: {:ok, Embed.t()} | {:error, Changeset.t()}
  def create_folder_embed(%Space{} = space, attrs \\ %{}) when is_map(attrs) do
    archived =
      case Map.get(attrs, :archived, Map.get(attrs, "archived", false)) do
        value when value in [true, "true", 1, "1"] -> true
        _ -> false
      end

    name = Map.get(attrs, :name) || Map.get(attrs, "name")

    parent_folder_id = parent_folder_id(attrs)

    Repo.transaction(fn ->
      with {:ok, collection} <-
             %Collection{}
             |> Collection.changeset(%{
               space_id: space.id,
               name: normalize_folder_name(name),
               type: :folder
             })
             |> Repo.insert(),
           {:ok, embed} <-
             %Embed{}
             |> Embed.changeset(%{
               space_id: space.id,
               collection_id: collection.id,
               hash: generate_hash(),
               type: :collection,
               version: 2,
               archived: archived
             })
             |> Repo.insert(),
           :ok <- maybe_attach_to_parent(embed, space.id, parent_folder_id) do
        preload_embed(embed)
      else
        {:error, %Changeset{} = changeset} -> Repo.rollback(changeset)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> maybe_broadcast_embed_updated(%{"action" => "created"})
  end

  @spec move_embed(Embed.t(), Embed.t() | nil) :: {:ok, Embed.t()} | {:error, term()}
  def move_embed(%Embed{} = embed, target_folder)
      when is_nil(target_folder) or is_struct(target_folder, Embed) do
    Repo.transaction(fn ->
      # Opposite moves lock different embeds, so serialize the shared space graph.
      Repo.one!(
        from(s in Space, where: s.id == ^embed.space_id, lock: "FOR UPDATE", select: s.id)
      )

      embed = reload_embed(embed.id)
      target_folder = reload_move_target(target_folder)

      with :ok <- validate_move_target(embed, target_folder),
           :ok <- replace_folder_membership(embed.id, target_folder) do
        reload_embed(embed.id)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_repo_result()
    |> maybe_broadcast_embed_updated(%{"action" => "moved"})
  end

  @spec remove_embed_from_folder(Embed.t()) :: {:ok, Embed.t()} | {:error, term()}
  def remove_embed_from_folder(%Embed{} = embed), do: move_embed(embed, nil)

  @spec list_folder_targets(Space.t(), dashboard_tab(), Embed.t() | nil) :: [map()]
  def list_folder_targets(space, tab \\ :all, exclude_embed \\ nil)

  def list_folder_targets(%Space{} = space, tab, exclude_embed) when tab in [:all, :archive] do
    archived = tab == :archive
    excluded_ids = exclude_embed |> move_excluded_embed_ids() |> MapSet.to_list()

    from(e in Embed,
      left_join: c in assoc(e, :collection),
      where: e.space_id == ^space.id,
      where: e.type == :collection and is_nil(e.deleted_at),
      where: e.archived == ^archived,
      where: e.id not in ^excluded_ids,
      order_by: [asc: c.name, asc: e.inserted_at],
      preload: [collection: c]
    )
    |> Repo.all()
    |> Enum.map(fn folder ->
      %{
        id: folder.id,
        dashboard_id: dashboard_embed_id(folder),
        name: folder_name(folder)
      }
    end)
  end

  @spec resolve_dashboard_embed(Space.t(), String.t()) :: {:ok, Embed.t()} | {:error, :not_found}
  def resolve_dashboard_embed(%Space{} = space, raw_id) when is_binary(raw_id) do
    with {:ok, lookup} <- normalize_dashboard_lookup(space, String.trim(raw_id)),
         %Embed{} = embed <- fetch_embed(space, lookup) do
      {:ok, preload_embed(embed)}
    else
      _ -> {:error, :not_found}
    end
  end

  @spec get_embed_by_hashes(String.t(), String.t()) :: Embed.t() | nil
  def get_embed_by_hashes(space_hash, embed_hash)
      when is_binary(space_hash) and is_binary(embed_hash) do
    from(e in Embed,
      join: s in assoc(e, :space),
      where: s.hash == ^space_hash,
      where: e.hash == ^embed_hash and is_nil(e.deleted_at),
      preload: [space: s]
    )
    |> Repo.one()
    |> case do
      %Embed{} = embed -> preload_embed(embed)
      nil -> nil
    end
  end

  @spec list_root_items(Space.t(), dashboard_tab(), keyword()) :: map()
  def list_root_items(space, tab \\ :all, opts \\ [])

  def list_root_items(%Space{} = space, tab, opts) when tab in [:all, :archive] do
    archived = tab == :archive
    page = normalize_dashboard_page(Keyword.get(opts, :page, 1))
    per_page = normalize_dashboard_per_page(Keyword.get(opts, :per_page, @dashboard_per_page))
    in_collection_ids = from(ce in CollectionEmbed, select: ce.embed_id)

    query =
      from(e in Embed,
        left_join: a in assoc(e, :asset),
        left_join: v in assoc(a, :current_video),
        left_join: c in assoc(e, :collection),
        where: e.space_id == ^space.id,
        where: e.type in [:video, :collection],
        where: e.archived == ^archived and is_nil(e.deleted_at),
        where: e.id not in subquery(in_collection_ids),
        order_by: [asc: is_nil(e.collection_id), desc: e.inserted_at],
        preload: [asset: {a, [current_video: v]}, collection: c]
      )

    total_items = Repo.aggregate(query, :count, :id)
    total_pages = pages(total_items, per_page)

    embeds =
      query
      |> offset(^((page - 1) * per_page))
      |> limit(^per_page)
      |> Repo.all()

    serialize_dashboard_items(space, embeds)
    |> Map.merge(%{
      page: page,
      total_pages: total_pages,
      total_items: total_items,
      per_page: per_page
    })
  end

  @spec search_video_suggestions(Space.t(), String.t(), keyword()) :: [map()]
  def search_video_suggestions(%Space{} = space, query, opts \\ []) when is_binary(query) do
    archived = Keyword.get(opts, :archived, false)
    limit = Keyword.get(opts, :limit, @search_suggestion_limit)
    normalized_query = String.trim(query)

    if byte_size(normalized_query) < 2 do
      []
    else
      like_query = "%" <> escape_ilike(normalized_query) <> "%"
      embed_hash_query = embed_hash_query(space, normalized_query)
      dashboard_uuid_query = dashboard_uuid_query(normalized_query)

      match_query =
        dynamic(
          [e, a, v],
          ilike(a.name, ^like_query) or
            ilike(v.file_name, ^like_query) or
            e.hash == ^embed_hash_query
        )

      match_query =
        if is_binary(dashboard_uuid_query) do
          dynamic([e, a, v], ^match_query or e.id == ^dashboard_uuid_query)
        else
          match_query
        end

      embeds =
        from(e in Embed,
          left_join: a in assoc(e, :asset),
          left_join: v in assoc(a, :current_video),
          where: e.space_id == ^space.id,
          where: e.type == :video and e.archived == ^archived and is_nil(e.deleted_at),
          where: ^match_query,
          order_by: [desc: e.inserted_at],
          limit: ^(limit * 4),
          preload: [asset: {a, [current_video: v]}]
        )
        |> Repo.all()
        |> Enum.sort_by(&search_rank(space, &1, normalized_query))
        |> Enum.take(limit)

      thumbnail_cache_busters = thumbnail_cache_busters(embeds)

      Enum.map(embeds, fn embed ->
        row = serialize_video_row(space, embed, thumbnail_cache_busters)

        %{
          id: row.id,
          uuid: row.uuid,
          name: row.name,
          thumb: row.thumb,
          public_id: public_embed_id(space, embed),
          hash: embed.hash
        }
      end)
    end
  end

  @spec list_folder_items(Space.t(), Embed.t(), keyword()) :: map()
  def list_folder_items(space, folder_embed, opts \\ [])

  def list_folder_items(
        %Space{} = space,
        %Embed{type: :collection, collection_id: collection_id},
        opts
      )
      when is_binary(collection_id) do
    page = normalize_dashboard_page(Keyword.get(opts, :page, 1))
    per_page = normalize_dashboard_per_page(Keyword.get(opts, :per_page, @dashboard_per_page))

    query =
      from(ce in CollectionEmbed,
        join: e in assoc(ce, :embed),
        left_join: a in assoc(e, :asset),
        left_join: v in assoc(a, :current_video),
        left_join: c in assoc(e, :collection),
        where: ce.collection_id == ^collection_id,
        where: e.space_id == ^space.id,
        where: e.type in [:video, :collection] and is_nil(e.deleted_at),
        order_by: [asc: is_nil(e.collection_id), desc: e.inserted_at],
        preload: [embed: {e, [asset: {a, [current_video: v]}, collection: c]}]
      )

    total_items = Repo.aggregate(query, :count, :id)
    total_pages = pages(total_items, per_page)

    embeds =
      query
      |> offset(^((page - 1) * per_page))
      |> limit(^per_page)
      |> Repo.all()
      |> Enum.map(& &1.embed)

    serialize_dashboard_items(space, embeds)
    |> Map.merge(%{
      page: page,
      total_pages: total_pages,
      total_items: total_items,
      per_page: per_page
    })
  end

  def list_folder_items(_space, _folder_embed, opts) do
    page = normalize_dashboard_page(Keyword.get(opts, :page, 1))
    per_page = normalize_dashboard_per_page(Keyword.get(opts, :per_page, @dashboard_per_page))

    %{
      folders: [],
      videos: [],
      page: page,
      total_pages: 0,
      total_items: 0,
      per_page: per_page
    }
  end

  @spec pages(non_neg_integer(), pos_integer()) :: non_neg_integer()
  def pages(count, per_page \\ @dashboard_per_page)

  def pages(count, per_page) when is_integer(count) and count >= 0 do
    per_page = normalize_dashboard_per_page(per_page)

    if count == 0 do
      0
    else
      ceil(count / per_page)
    end
  end

  @spec folder_paths(Space.t(), Embed.t()) :: [Embed.t()]
  def folder_paths(%Space{} = space, %Embed{type: :collection} = folder_embed) do
    folder_embed
    |> parent_folder(space)
    |> do_folder_paths(space, [], MapSet.new([folder_embed.id]))
  end

  def folder_paths(_space, _folder_embed), do: []

  @spec folder_video_counts(Space.t(), [String.t()]) :: %{
          optional(String.t()) => non_neg_integer()
        }
  def folder_video_counts(%Space{} = space, folder_embed_ids) when is_list(folder_embed_ids) do
    folder_embed_ids = folder_embed_ids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    if folder_embed_ids == [] do
      %{}
    else
      from(e in Embed,
        where: e.space_id == ^space.id,
        where: e.id in ^folder_embed_ids,
        where: e.type == :collection and is_nil(e.deleted_at),
        select: {e.id, e.collection_id}
      )
      |> Repo.all()
      |> Enum.reduce(%{}, fn {embed_id, collection_id}, acc ->
        Map.put(acc, embed_id, collection_video_count(collection_id, space.id))
      end)
    end
  end

  @spec get_video_dashboard_payload(Space.t(), Embed.t(), map() | nil) :: map()
  def get_video_dashboard_payload(
        %Space{} = space,
        %Embed{} = video_embed,
        settings_override \\ nil
      ) do
    build_video_dashboard_payload(
      space,
      video_embed,
      settings_override,
      video_analytics(space.hash, video_embed.hash),
      true
    )
  end

  @spec get_preloaded_video_dashboard_payload(Space.t(), Embed.t(), map() | nil) :: map()
  @doc false
  def get_preloaded_video_dashboard_payload(
        %Space{} = space,
        %Embed{} = video_embed,
        settings_override \\ nil
      ) do
    build_video_dashboard_payload(
      space,
      video_embed,
      settings_override,
      video_analytics(space.hash, video_embed.hash),
      false
    )
  end

  @spec refresh_video_dashboard_processing_payload(Space.t(), Embed.t(), map()) :: map()
  def refresh_video_dashboard_processing_payload(
        %Space{} = space,
        %Embed{} = video_embed,
        previous_payload
      )
      when is_map(previous_payload) do
    build_video_dashboard_payload(
      space,
      video_embed,
      nil,
      dashboard_payload_analytics(previous_payload),
      false
    )
  end

  defp build_video_dashboard_payload(
         space,
         video_embed,
         settings_override,
         analytics,
         reload_embed?
       ) do
    video_embed = preload_dashboard_embed(video_embed, reload_embed?)

    current_video = current_video_from_embed(video_embed)
    current_version = current_video_version(current_video)
    flow_run = latest_flow_run(space.hash, video_embed.hash)
    audio_tracks = audio_tracks_for(current_video)
    audio_only? = audio_only_source?(current_video, flow_run, current_version, audio_tracks)
    effective_settings = effective_settings(video_embed, settings_override)
    thumbnail_cache_buster = thumbnail_cache_buster(current_video && current_video.id)

    %{
      id: dashboard_embed_id(video_embed),
      public_id: SettingsSerializer.public_embed_id(space, video_embed),
      hash: video_embed.hash,
      name: embed_name(video_embed),
      archived: video_embed.archived,
      thumbnail: thumbnail_url(space, video_embed, thumbnail_cache_buster),
      preview_poster:
        preview_poster_url(space, video_embed, effective_settings, thumbnail_cache_buster),
      snippet_player_poster: snippet_thumbnail_url(space, video_embed, thumbnail_cache_buster),
      snippet_clip_poster: snippet_object_url(space, video_embed, "poster.jpg"),
      resolution: resolution_label(current_video, audio_only?),
      fps: fps_value(current_video),
      aspect_ratio: aspect_ratio_value(current_video),
      inserted_at: format_date(video_embed.inserted_at),
      status: current_video && current_video.status,
      views_today: analytics.views.today,
      views_month: analytics.views.month,
      views_year: analytics.views.year,
      sources: analytics.sources,
      engagement: analytics.dropoff.per_second,
      settings: SettingsSerializer.form_values(effective_settings),
      player_attributes: SettingsSerializer.player_attributes(effective_settings),
      player_attributes_string:
        effective_settings
        |> SettingsSerializer.player_attributes()
        |> SettingsSerializer.attributes_to_string(),
      iframe_url: SettingsSerializer.iframe_url(space, video_embed),
      iframe_dimensions: SettingsSerializer.iframe_dimensions(effective_settings),
      component_config_src: SettingsSerializer.component_config_src(),
      component_src: SettingsSerializer.component_src(),
      component_config_required: SettingsSerializer.component_config_required?(),
      component_config_json: SettingsSerializer.component_config_json(),
      processing_player_ready: processing_player_ready_for_version?(flow_run, current_version),
      original: %{
        audio_only: audio_only?,
        width: int_or_zero(current_video && current_video.max_width),
        height: int_or_zero(current_video && current_video.max_height),
        file_size: int_or_zero(current_video && current_video.original_file_size),
        duration: current_video && current_video.duration,
        fps: fps_value(current_video) || 0,
        bitrate: bitrate_mbit(current_video && current_video.max_bitrate)
      },
      thumbnail_preview:
        thumbnail_preview(
          space,
          video_embed,
          current_video,
          flow_run,
          current_version,
          audio_only?
        ),
      audio_tracks: audio_tracks,
      subtitles: subtitles_for(space, video_embed, current_video, current_version),
      renditions: renditions_for(current_video, flow_run),
      flow: flow_summary_for(flow_run)
    }
  end

  defp dashboard_payload_analytics(payload) do
    %{
      views: %{
        today: Map.get(payload, :views_today, 0),
        month: Map.get(payload, :views_month, 0),
        year: Map.get(payload, :views_year, 0)
      },
      sources: Map.get(payload, :sources, []),
      dropoff: %{per_second: Map.get(payload, :engagement, [])}
    }
  end

  @spec processing_player_ready?(String.t(), String.t()) :: boolean()
  def processing_player_ready?(space_hash, embed_hash)
      when is_binary(space_hash) and is_binary(embed_hash) do
    case latest_flow_run(space_hash, embed_hash) do
      %Run{} = run ->
        processing_player_ready?(run)

      _ ->
        false
    end
  end

  @spec processing_upload_ready?(String.t(), String.t()) :: boolean()
  def processing_upload_ready?(space_hash, embed_hash),
    do: processing_player_ready?(space_hash, embed_hash)

  @spec processing_run_active?(String.t(), String.t()) :: boolean()
  def processing_run_active?(space_hash, embed_hash)
      when is_binary(space_hash) and is_binary(embed_hash) do
    match?(%Run{}, latest_processing_run(space_hash, embed_hash))
  end

  @spec change_settings(Embed.t(), map()) :: Changeset.t()
  def change_settings(%Embed{} = embed, attrs \\ %{}) do
    embed
    |> ensure_settings_struct()
    |> EmbedSettings.changeset(sanitize_settings_attrs(attrs, embed.space_id))
  end

  @spec update_settings(Embed.t(), map() | Changeset.t()) ::
          {:ok, Embed.t()} | {:error, Changeset.t()}
  def update_settings(%Embed{} = embed, attrs_or_changeset) do
    changeset = normalize_settings_changeset(embed, attrs_or_changeset)

    Repo.transaction(fn ->
      case persist_settings(changeset) do
        {:ok, settings} ->
          {:ok, attach_settings(embed, settings)}

        {:error, %Changeset{} = changeset} ->
          Repo.rollback({:changeset, changeset})
      end
    end)
    |> unwrap_repo_result()
  end

  @spec publish_settings(Embed.t(), map() | Changeset.t()) :: {:ok, Embed.t()} | {:error, term()}
  def publish_settings(%Embed{} = embed, attrs_or_changeset) do
    with {:ok, embed} <- update_settings(embed, attrs_or_changeset),
         :ok <- MaveCore.Assets.publish_selected_thumbnail(embed),
         {:ok, _manifest} <- ManifestPublisher.publish(embed) do
      {:ok, preload_embed(embed)}
      |> maybe_broadcast_embed_updated(%{"action" => "settings_published"})
    end
  end

  @spec delete_external_poster(Embed.t()) :: {:ok, Embed.t()} | {:error, term()}
  def delete_external_poster(%Embed{} = embed) do
    :ok = MaveCore.Assets.delete_custom_thumbnail(embed)
    _ = MaveCore.Assets.restore_default_thumbnail(embed)
    publish_settings(embed, %{external_poster: nil})
  end

  @spec rename_embed(Embed.t(), String.t() | nil) :: {:ok, Embed.t()} | {:error, term()}
  def rename_embed(%Embed{} = embed, name) do
    embed = preload_embed(embed)

    Repo.transaction(fn ->
      case embed.type do
        :video ->
          value = normalize_video_name(name)

          embed.asset
          |> Asset.changeset(%{name: value})
          |> Repo.update!()

        :collection ->
          embed.collection
          |> Collection.changeset(%{name: normalize_folder_name(name)})
          |> Repo.update!()
      end

      reload_embed(embed.id)
    end)
    |> unwrap_repo_result()
    |> publish_renamed_manifest()
    |> maybe_broadcast_embed_updated(%{"action" => "renamed"})
  end

  defp publish_renamed_manifest({:ok, %Embed{type: :video} = embed}) do
    with {:ok, _manifest} <- ManifestPublisher.publish(embed) do
      {:ok, embed}
    end
  end

  defp publish_renamed_manifest(result), do: result

  @spec archive_embed(Embed.t()) :: {:ok, Embed.t()} | {:error, term()}
  def archive_embed(%Embed{} = embed) do
    embed = preload_embed(embed)
    archived = !embed.archived
    now = now_utc()

    Repo.transaction(fn ->
      case embed.type do
        :video -> archive_video_embed!(embed, archived)
        :collection -> archive_collection_embed!(embed, archived, now)
      end

      reload_embed(embed.id)
    end)
    |> unwrap_repo_result()
    |> maybe_enqueue_embed_event(
      embed.space || %Space{id: embed.space_id},
      if(archived, do: :video_archived, else: :video_unarchived)
    )
    |> maybe_broadcast_embed_updated(%{
      "action" => if(archived, do: "archived", else: "unarchived"),
      "archived" => archived
    })
  end

  @spec delete_space_videos(Space.t()) :: {:ok, [Embed.t()]} | {:error, term()}
  def delete_space_videos(%Space{id: space_id}) do
    embeds =
      from(embed in Embed,
        where: embed.space_id == ^space_id and embed.type == :video and is_nil(embed.deleted_at),
        order_by: [asc: embed.inserted_at, asc: embed.id]
      )
      |> Repo.all()

    embeds
    |> Enum.reduce_while({:ok, []}, fn embed, {:ok, deleted_embeds} ->
      case delete_embed(embed) do
        {:ok, deleted_embed} -> {:cont, {:ok, [deleted_embed | deleted_embeds]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, deleted_embeds} -> {:ok, Enum.reverse(deleted_embeds)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec delete_embed(Embed.t()) :: {:ok, Embed.t()} | {:error, term()}
  def delete_embed(%Embed{} = embed) do
    embed = preload_embed(embed)
    storage = storage_module()

    with :ok <- maybe_hide_embed_assets(storage, embed) do
      Repo.transaction(fn ->
        delete_embed_record!(embed)

        embed
      end)
      |> unwrap_repo_result()
      |> maybe_enqueue_embed_event(embed.space || %Space{id: embed.space_id}, :video_deleted)
      |> maybe_broadcast_embed_updated(%{"action" => "deleted"})
    end
  end

  defp maybe_hide_embed_assets(_storage, %Embed{type: :collection}), do: :ok

  defp maybe_hide_embed_assets(storage, %Embed{type: :video} = embed) do
    storage.update_embed_visibility(embed.space, embed.hash, "private", embed.space.region)
  end

  defp storage_module do
    Application.get_env(:mave_core, :storage_module, Storage)
  end

  defp maybe_broadcast_embed_updated({:ok, %Embed{} = embed} = result, payload)
       when is_map(payload) do
    Events.broadcast_updated(embed.space_id, embed.id, payload)
    result
  end

  defp maybe_broadcast_embed_updated(result, _payload), do: result

  @spec dashboard_embed_id(Embed.t()) :: String.t()
  def dashboard_embed_id(%Embed{id: id}) when is_binary(id), do: id

  @spec current_video_version(Embed.t() | Video.t() | nil) :: non_neg_integer()
  def current_video_version(%Embed{} = embed) do
    case current_video_from_embed(preload_embed(embed)) do
      %Video{} = video -> current_video_version(video)
      _ -> 0
    end
  end

  def current_video_version(%Video{inserted_at: inserted_at, asset_id: asset_id}) do
    Video
    |> where([video], video.asset_id == ^asset_id and video.inserted_at <= ^inserted_at)
    |> Repo.aggregate(:count)
    |> Kernel.-(1)
    |> max(0)
  end

  def current_video_version(_), do: 0

  @spec get_subtitles(Embed.t()) :: list()
  def get_subtitles(%Embed{asset: %{current_video: %{id: video_id}}}) do
    MaveCore.Assets.subtitles_for_video(video_id)
  end

  def get_subtitles(_), do: []

  @spec get_audio_tracks(Embed.t()) :: list()
  def get_audio_tracks(%Embed{asset: %{current_video: %{id: video_id}}}) do
    MaveCore.Assets.audio_tracks_for_video(video_id)
  end

  def get_audio_tracks(_), do: []

  defp serialize_dashboard_items(space, embeds) do
    folders = Enum.filter(embeds, &(&1.type == :collection))

    videos =
      embeds
      |> Enum.filter(&(&1.type == :video))
      |> Repo.preload(asset: [current_video: :audio_tracks])

    counts = folder_video_counts(space, Enum.map(folders, & &1.id))
    thumbnail_cache_busters = thumbnail_cache_busters(videos)

    %{
      folders: Enum.map(folders, &serialize_folder(space, &1, Map.get(counts, &1.id, 0))),
      videos: Enum.map(videos, &serialize_video_row(space, &1, thumbnail_cache_busters))
    }
  end

  defp maybe_enqueue_embed_event(
         {:ok, %Embed{type: :video} = embed},
         %Space{} = space,
         event_type
       ) do
    _ = Spaces.enqueue_webhook_event_for_embed(space, embed, event_type, %{enqueue: true})
    {:ok, embed}
  end

  defp maybe_enqueue_embed_event(result, _space, _event_type), do: result

  defp serialize_folder(_space, embed, count) do
    %{
      id: dashboard_embed_id(embed),
      uuid: embed.id,
      hash: embed.hash,
      name: folder_name(embed),
      video_count: count,
      archived: embed.archived
    }
  end

  defp serialize_video_row(space, embed, thumbnail_cache_busters) do
    current_video = current_video_from_embed(embed)
    thumbnail_cache_buster = current_video && Map.get(thumbnail_cache_busters, current_video.id)
    row_state = video_row_state(space, embed, current_video)
    empty_video? = is_nil(current_video) and is_nil(row_state)
    pending? = not is_nil(row_state)
    thumbnail_ready? = not is_nil(thumbnail_cache_buster)

    %{
      id: dashboard_embed_id(embed),
      uuid: embed.id,
      hash: embed.hash,
      name: embed_name(embed),
      thumb:
        if(pending? and not thumbnail_ready?,
          do: nil,
          else: thumbnail_url(space, embed, thumbnail_cache_buster)
        ),
      empty: empty_video?,
      processing: row_state in [:queued, :processing],
      state: row_state,
      resolution: if(pending?, do: nil, else: resolution_label(current_video)),
      fps: if(pending?, do: nil, else: fps_value(current_video)),
      inserted_at: if(empty_video?, do: nil, else: format_date(embed.inserted_at)),
      archived: embed.archived
    }
  end

  defp public_embed_id(%Space{} = space, %Embed{version: 2} = embed),
    do: SettingsSerializer.public_embed_id(space, embed)

  defp public_embed_id(_space, %Embed{hash: hash}), do: hash

  defp search_rank(%Space{} = space, %Embed{} = embed, query) do
    downcased_query = String.downcase(query)
    public_id = public_embed_id(space, embed)
    dashboard_id = dashboard_embed_id(embed)
    title = embed_name(embed) |> String.downcase()

    file_name =
      case current_video_from_embed(embed) do
        %Video{file_name: name} when is_binary(name) -> String.downcase(name)
        _ -> nil
      end

    {
      exact_match_rank(public_id, dashboard_id, embed.hash, title, file_name, downcased_query),
      prefix_match_rank(title, file_name, downcased_query),
      -DateTime.to_unix(embed.inserted_at)
    }
  end

  defp exact_match_rank(public_id, dashboard_id, embed_hash, title, file_name, query) do
    cond do
      String.downcase(public_id) == query -> 0
      String.downcase(dashboard_id) == query -> 1
      String.downcase(embed_hash) == query -> 2
      title == query -> 3
      file_name == query -> 4
      true -> 5
    end
  end

  defp prefix_match_rank(title, file_name, query) do
    cond do
      String.starts_with?(title, query) -> 0
      is_binary(file_name) and String.starts_with?(file_name, query) -> 1
      true -> 2
    end
  end

  defp embed_hash_query(%Space{hash: space_hash}, query) do
    case EmbedId.split(query) do
      {:ok, %{space_hash: ^space_hash, embed_hash: embed_hash}} -> embed_hash
      _ -> query
    end
  end

  defp dashboard_uuid_query(query) do
    case LegacyShortUUID.cast(query) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  defp escape_ilike(query) do
    query
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp fetch_embed(%Space{} = space, {:id, id}) do
    from(e in Embed,
      where: e.space_id == ^space.id,
      where: e.id == ^id and is_nil(e.deleted_at)
    )
    |> Repo.one()
  end

  defp fetch_embed(%Space{} = space, {:hash, hash}) do
    from(e in Embed,
      where: e.space_id == ^space.id,
      where: e.hash == ^hash and is_nil(e.deleted_at)
    )
    |> Repo.one()
  end

  defp normalize_dashboard_lookup(%Space{} = _space, ""), do: {:error, :not_found}

  defp normalize_dashboard_lookup(%Space{} = space, raw_id) do
    case LegacyShortUUID.cast(raw_id) do
      {:ok, id} -> {:ok, {:id, id}}
      :error -> normalize_hash_lookup(space, raw_id)
    end
  end

  defp normalize_hash_lookup(%Space{hash: current_space_hash}, raw_id) do
    case EmbedId.split(raw_id) do
      {:ok, %{space_hash: ^current_space_hash, embed_hash: embed_hash}} ->
        {:ok, {:hash, embed_hash}}

      {:ok, _other_space} ->
        {:error, :not_found}

      :error ->
        if raw_id =~ @embed_hash_regex do
          {:ok, {:hash, raw_id}}
        else
          {:error, :not_found}
        end
    end
  end

  defp preload_embed(%Embed{} = embed) do
    Repo.preload(embed, [:space, :settings, :collection, asset: [:current_video]], force: true)
  end

  defp preload_embed_once(%Embed{} = embed) do
    Repo.preload(embed, [:space, :settings, :collection, asset: [:current_video]])
  end

  defp preload_dashboard_embed(%Embed{} = embed, true), do: preload_embed(embed)
  defp preload_dashboard_embed(%Embed{} = embed, false), do: preload_embed_once(embed)

  defp reload_embed(id) when is_binary(id) do
    Embed
    |> Repo.get!(id)
    |> preload_embed()
  end

  defp ensure_settings_struct(%Embed{} = embed) do
    embed
    |> preload_embed()
    |> SettingsSerializer.settings_struct()
  end

  defp effective_settings(%Embed{} = embed, nil), do: SettingsSerializer.settings_struct(embed)

  defp effective_settings(%Embed{} = embed, settings_override) when is_map(settings_override) do
    embed
    |> change_settings(settings_override)
    |> Changeset.apply_changes()
    |> SettingsSerializer.settings_struct()
  end

  defp normalize_settings_changeset(%Embed{} = embed, %Changeset{} = changeset) do
    settings = ensure_settings_struct(embed)

    if Map.get(changeset.data, :id) == settings.id do
      changeset
    else
      EmbedSettings.changeset(settings, Changeset.apply_changes(changeset) |> Map.from_struct())
    end
  end

  defp normalize_settings_changeset(%Embed{} = embed, attrs) when is_map(attrs) do
    change_settings(embed, attrs)
  end

  defp persist_settings(%Changeset{} = changeset) do
    case Map.get(changeset.data, :id) do
      nil -> Repo.insert(changeset)
      _id -> Repo.update(changeset)
    end
  end

  defp attach_settings(%Embed{} = embed, %EmbedSettings{} = settings) do
    embed = preload_embed(embed)

    updated_embed =
      if embed.embed_settings_id == settings.id do
        embed
      else
        embed
        |> Embed.changeset(%{embed_settings_id: settings.id})
        |> Repo.update!()
      end

    reload_embed(updated_embed.id)
  end

  defp sanitize_settings_attrs(attrs, space_id) when is_map(attrs) do
    attrs =
      attrs
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        case normalize_settings_key(key) do
          nil -> acc
          atom_key -> Map.put(acc, atom_key, value)
        end
      end)

    Map.put_new(attrs, :space_id, space_id)
  end

  defp normalize_settings_key(key) when is_atom(key) and key in @settings_fields, do: key

  defp normalize_settings_key(key) when is_binary(key) do
    key
    |> String.trim()
    |> maybe_existing_atom()
    |> case do
      atom when atom in @settings_fields -> atom
      _ -> nil
    end
  end

  defp normalize_settings_key(_), do: nil

  defp maybe_existing_atom(""), do: nil

  defp maybe_existing_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp normalize_video_name(nil), do: nil

  defp normalize_video_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_folder_name(nil), do: ""
  defp normalize_folder_name(name) when is_binary(name), do: String.trim(name)

  defp parent_folder_id(attrs) when is_map(attrs) do
    Map.get(attrs, :parent_folder_id) || Map.get(attrs, "parent_folder_id")
  end

  defp maybe_attach_to_parent(_embed, _space_id, parent_folder_id)
       when parent_folder_id in [nil, ""] do
    :ok
  end

  defp maybe_attach_to_parent(%Embed{id: embed_id}, space_id, parent_folder_id)
       when is_binary(embed_id) and is_binary(parent_folder_id) do
    case fetch_folder_by_id(space_id, parent_folder_id) do
      %Embed{collection_id: collection_id} when is_binary(collection_id) ->
        insert_folder_membership(collection_id, embed_id)

      _ ->
        {:error, :invalid_parent_folder}
    end
  end

  defp maybe_update_upload_asset_name(%Embed{asset: asset}, asset_name)
       when is_binary(asset_name) and not is_nil(asset) and asset.name != asset_name do
    asset
    |> Asset.changeset(%{name: asset_name})
    |> Repo.update!()
  end

  defp maybe_update_upload_asset_name(_embed, _asset_name), do: :ok

  defp maybe_reset_upload_replacement(%Embed{asset: %{current_video: %Video{}}} = embed) do
    maybe_reset_poster_for_replacement(embed)
  end

  defp maybe_reset_upload_replacement(_embed), do: :ok

  defp create_upload_video!(asset_id, attrs, file_name)
       when is_binary(asset_id) and is_map(attrs) do
    %Video{}
    |> Video.changeset(%{
      asset_id: asset_id,
      status: "uploading",
      file_name: file_name,
      source_url: Map.get(attrs, "source_url") || Map.get(attrs, :source_url),
      original_file_size:
        parse_upload_integer(Map.get(attrs, "upload_size") || Map.get(attrs, :upload_size))
    })
    |> Repo.insert!()
  end

  defp set_current_video!(asset, video_id) do
    asset
    |> Asset.changeset(%{current_video_id: video_id})
    |> Repo.update!()
  end

  defp reload_move_target(nil), do: nil

  defp reload_move_target(%Embed{id: id}) do
    Repo.get(Embed, id) || Repo.rollback(:invalid_target_folder)
  end

  defp validate_move_target(%Embed{} = embed, nil), do: validate_move_root(embed)

  defp validate_move_target(%Embed{} = embed, %Embed{} = target_folder) do
    cond do
      target_folder.type != :collection ->
        {:error, :invalid_target_folder}

      not is_nil(target_folder.deleted_at) ->
        {:error, :invalid_target_folder}

      embed.space_id != target_folder.space_id ->
        {:error, :cross_space_move}

      not is_binary(target_folder.collection_id) ->
        {:error, :invalid_target_folder}

      embed.id == target_folder.id ->
        {:error, :invalid_target_folder}

      embed.type == :collection and
          MapSet.member?(move_excluded_embed_ids(embed), target_folder.id) ->
        {:error, :invalid_target_folder}

      true ->
        :ok
    end
  end

  defp validate_move_root(%Embed{}), do: :ok

  defp attach_embed_to_target_folder(%Embed{} = folder, embed_id) do
    insert_folder_membership(folder.collection_id, embed_id)
  end

  defp attach_embed_to_target_folder(nil, _embed_id), do: :ok

  defp replace_folder_membership(embed_id, target_folder) do
    remove_embed_memberships(embed_id)
    attach_embed_to_target_folder(target_folder, embed_id)
  end

  defp fetch_folder_by_id(space_id, folder_id)
       when is_binary(space_id) and is_binary(folder_id) do
    from(e in Embed,
      where: e.space_id == ^space_id,
      where: e.id == ^folder_id and e.type == :collection and is_nil(e.deleted_at)
    )
    |> Repo.one()
    |> case do
      %Embed{} = folder -> preload_embed(folder)
      nil -> nil
    end
  end

  defp parent_folder(%Embed{id: embed_id}, %Space{} = space) when is_binary(embed_id) do
    from(ce in CollectionEmbed,
      join: e in Embed,
      on: e.collection_id == ce.collection_id,
      where: ce.embed_id == ^embed_id,
      where: e.space_id == ^space.id,
      where: e.type == :collection and is_nil(e.deleted_at),
      limit: 1,
      select: e
    )
    |> Repo.one()
    |> case do
      %Embed{} = folder -> preload_embed(folder)
      nil -> nil
    end
  end

  defp parent_folder(_embed, _space), do: nil

  defp do_folder_paths(nil, _space, acc, _visited), do: acc

  defp do_folder_paths(%Embed{} = folder, %Space{} = space, acc, visited) do
    if MapSet.member?(visited, folder.id) do
      acc
    else
      do_folder_paths(
        parent_folder(folder, space),
        space,
        [folder | acc],
        MapSet.put(visited, folder.id)
      )
    end
  end

  defp insert_folder_membership(collection_id, embed_id)
       when is_binary(collection_id) and is_binary(embed_id) do
    %CollectionEmbed{}
    |> CollectionEmbed.changeset(%{
      collection_id: collection_id,
      embed_id: embed_id,
      position: next_collection_position(collection_id)
    })
    |> Repo.insert()
    |> case do
      {:ok, _row} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp next_collection_position(collection_id) when is_binary(collection_id) do
    from(ce in CollectionEmbed,
      where: ce.collection_id == ^collection_id,
      select: max(ce.position)
    )
    |> Repo.one()
    |> case do
      nil -> 1.0
      position when is_number(position) -> position + 1.0
      _ -> 1.0
    end
  end

  defp remove_embed_memberships(embed_id) when is_binary(embed_id) do
    Repo.delete_all(from(ce in CollectionEmbed, where: ce.embed_id == ^embed_id))
  end

  defp move_excluded_embed_ids(nil), do: MapSet.new()

  defp move_excluded_embed_ids(%Embed{} = embed) do
    excluded =
      if embed.type == :collection do
        descendant_folder_embed_ids(embed.id, embed.space_id, MapSet.new())
      else
        MapSet.new()
      end

    excluded
    |> MapSet.put(embed.id)
  end

  defp descendant_folder_embed_ids(embed_id, _space_id, visited)
       when not is_binary(embed_id) do
    visited
  end

  defp descendant_folder_embed_ids(embed_id, space_id, visited) do
    case MapSet.member?(visited, embed_id) do
      true ->
        visited

      false ->
        visited
        |> MapSet.put(embed_id)
        |> collect_descendant_folder_embed_ids(embed_id, space_id)
    end
  end

  defp toggle_collection_tree(collection_id, _space_id, _archived, visited, _now)
       when not is_binary(collection_id) do
    visited
  end

  defp toggle_collection_tree(collection_id, space_id, archived, visited, now) do
    case MapSet.member?(visited, collection_id) do
      true ->
        visited

      false ->
        visited
        |> MapSet.put(collection_id)
        |> toggle_collection_rows(collection_id, space_id, archived, now)
    end
  end

  defp unwrap_repo_result({:ok, {:ok, result}}), do: {:ok, result}
  defp unwrap_repo_result({:ok, result}), do: {:ok, result}
  defp unwrap_repo_result({:error, {:changeset, changeset}}), do: {:error, changeset}
  defp unwrap_repo_result({:error, reason}), do: {:error, reason}

  defp now_utc do
    DateTime.utc_now() |> DateTime.truncate(:microsecond)
  end

  defp count_collection_videos(collection_id, _space_id, visited)
       when not is_binary(collection_id) do
    {0, visited}
  end

  defp count_collection_videos(collection_id, space_id, visited) do
    case MapSet.member?(visited, collection_id) do
      true ->
        {0, visited}

      false ->
        visited
        |> MapSet.put(collection_id)
        |> count_collection_video_rows(collection_id, space_id)
    end
  end

  defp embed_name(%Embed{} = embed) do
    asset_name =
      case embed.asset do
        %{name: name} when is_binary(name) and name != "" -> name
        _ -> nil
      end

    file_name =
      case current_video_from_embed(embed) do
        %{file_name: name} when is_binary(name) and name != "" -> name
        _ -> nil
      end

    first_present_name([asset_name, file_name])
  end

  defp folder_name(%Embed{} = embed) do
    name =
      case embed.collection do
        %{name: value} -> value
        _ -> nil
      end

    if is_binary(name) and name != "" do
      name
    else
      "Untitled"
    end
  end

  defp preview_poster_url(%Space{} = space, %Embed{} = embed, settings, cache_buster) do
    url =
      if generated_thumbnail_poster_settings?(settings) and not is_nil(cache_buster) do
        thumbnail_url(space, embed, cache_buster)
      else
        SettingsSerializer.preview_poster_url(space, embed, settings)
      end

    if uploaded_poster_settings?(settings) do
      with_cache_buster(url, cache_buster)
    else
      url
    end
  end

  defp uploaded_poster_settings?(settings_like) do
    settings = SettingsSerializer.settings_struct(settings_like)

    settings.poster == :upload and is_binary(settings.external_poster) and
      settings.external_poster != ""
  end

  defp generated_thumbnail_poster_settings?(settings_like) do
    settings = SettingsSerializer.settings_struct(settings_like)

    not uploaded_poster_settings?(settings) and
      not (settings.poster == :timecode and is_number(settings.poster_time_seconds) and
             settings.poster_time_seconds > 0)
  end

  defp thumbnail_url(
         %Space{hash: space_hash} = space,
         %Embed{hash: embed_hash} = embed,
         cache_buster
       )
       when is_binary(space_hash) and is_binary(embed_hash) do
    space
    |> snippet_object_url(embed, "thumbnail.jpg")
    |> with_cache_buster(cache_buster)
  end

  defp thumbnail_url(%Space{}, %Embed{}, _cache_buster) do
    nil
  end

  defp thumbnail_url(_space, _embed, _cache_buster), do: nil

  defp snippet_object_url(%Space{} = space, %Embed{} = embed, filename)
       when is_binary(filename) do
    case current_video_from_embed(embed) do
      %Video{} ->
        bucket = Storage.bucket_for_space(space.hash, space.region)
        SettingsSerializer.storage_object_url(bucket, "#{embed.hash}/#{filename}")

      _ ->
        nil
    end
  end

  defp snippet_thumbnail_url(%Space{} = space, %Embed{} = embed, cache_buster) do
    case current_video_from_embed(embed) do
      %Video{} ->
        space
        |> snippet_object_url(embed, "thumbnail.jpg")
        |> with_cache_buster(cache_buster)

      _ ->
        nil
    end
  end

  defp thumbnail_cache_buster(video_id) when is_binary(video_id) do
    from(r in "renditions",
      where: r.video_id == type(^video_id, MaveCore.Ecto.LegacyShortUUID),
      where: r.type in ["thumbnail", "custom_thumbnail"],
      where: r.container == "jpg" or r.codec == "jpg",
      where: r.progress >= 100,
      order_by: [desc: r.inserted_at],
      limit: 1,
      select: r.inserted_at
    )
    |> Repo.one()
    |> case do
      nil -> nil
      inserted_at -> inserted_at_cache_buster(inserted_at)
    end
  end

  defp thumbnail_cache_buster(_video_id), do: nil

  defp thumbnail_cache_busters(embeds) when is_list(embeds) do
    video_ids =
      embeds
      |> Enum.map(&current_video_id/1)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    if video_ids == [] do
      %{}
    else
      dumped_video_ids = Enum.map(video_ids, &LegacyShortUUID.dump!/1)

      from(r in "renditions",
        where: r.video_id in ^dumped_video_ids,
        where: r.type in ["thumbnail", "custom_thumbnail"],
        where: r.container == "jpg" or r.codec == "jpg",
        where: r.progress >= 100,
        order_by: [desc: r.inserted_at],
        select: {
          type(r.video_id, MaveCore.Ecto.LegacyShortUUID),
          r.inserted_at
        }
      )
      |> Repo.all()
      |> Enum.reduce(%{}, fn {video_id, inserted_at}, acc ->
        Map.put_new(acc, video_id, inserted_at_cache_buster(inserted_at))
      end)
    end
  end

  defp current_video_id(%Embed{} = embed) do
    case current_video_from_embed(embed) do
      %Video{id: id} -> id
      _ -> nil
    end
  end

  defp inserted_at_cache_buster(%DateTime{} = datetime),
    do: DateTime.to_unix(datetime, :microsecond)

  defp inserted_at_cache_buster(%NaiveDateTime{} = datetime) do
    datetime |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:microsecond)
  end

  defp inserted_at_cache_buster(_inserted_at), do: nil

  defp with_cache_buster(url, timestamp) when is_binary(url) and is_integer(timestamp) do
    separator = if String.contains?(url, "?"), do: "&", else: "?"
    "#{url}#{separator}e=#{timestamp}"
  end

  defp with_cache_buster(url, _timestamp), do: url

  defp thumbnail_preview(
         %Space{} = space,
         %Embed{} = embed,
         %Video{} = video,
         flow_run,
         version,
         false
       ) do
    duration = max(video.duration || 0.0, 0.0)
    original_src = original_preview_src(space, embed, version)
    hls_src = hls_preview_src(video, space, embed, flow_run)

    %{
      duration: duration,
      preferred_src: hls_src || original_src,
      fallback_src: original_src,
      frame_srcs: preview_frame_srcs(space, embed, duration, version)
    }
  end

  defp thumbnail_preview(_space, _embed, _video, _flow_run, _version, _audio_only), do: nil

  defp original_preview_src(%Space{} = space, %Embed{} = embed, version) do
    bucket = Storage.bucket_for_space(space.hash, space.region)

    key =
      if version > 0 do
        "#{embed.hash}/v#{version}/original"
      else
        "#{embed.hash}/original"
      end

    SettingsSerializer.storage_object_url(bucket, key)
  end

  defp hls_preview_src(
         %Video{id: video_id},
         %Space{} = space,
         %Embed{},
         flow_run
       ) do
    bucket = Storage.bucket_for_space(space.hash, space.region)

    stable_key =
      from(r in "renditions",
        where: r.video_id == type(^video_id, MaveCore.Ecto.LegacyShortUUID),
        where: r.type == "video",
        where: r.container == "hls",
        where: r.size == "sd",
        where: r.progress >= 100,
        order_by: [desc: r.inserted_at],
        limit: 1,
        select: r.rendition_key
      )
      |> Repo.one()

    if is_binary(stable_key) and stable_key != "" do
      SettingsSerializer.storage_object_url(bucket, stable_key)
    else
      processing_hls_preview_src(space, flow_run)
    end
  end

  defp hls_preview_src(_video, _space, _embed, _flow_run), do: nil

  defp processing_hls_preview_src(%Space{} = space, %Run{status: status} = run)
       when status in ["queued", "running"] do
    bucket = Storage.bucket_for_space(space.hash, space.region)

    run.step_runs
    |> Enum.find_value(fn
      %StepRun{
        step_type: "media.package_hls_variant",
        status: "succeeded",
        output: %{"playlist_key" => key, "rendition" => %{"size" => "sd"}}
      }
      when is_binary(key) and key != "" ->
        SettingsSerializer.storage_object_url(bucket, key)

      _ ->
        nil
    end)
  end

  defp processing_hls_preview_src(_space, _flow_run), do: nil

  defp preview_frame_srcs(%Space{} = space, %Embed{} = embed, duration, version) do
    frame_count = 6
    bucket = Storage.bucket_for_space(space.hash, space.region)

    0..(frame_count - 1)
    |> Enum.map(fn index ->
      timestamp =
        cond do
          duration <= 0 -> 0.0
          index == 0 -> 0.0
          true -> Float.round(duration * index / frame_count, 3)
        end

      %{
        time: timestamp,
        src: preview_thumbnail_src(bucket, embed.hash, version, index)
      }
    end)
  end

  defp preview_thumbnail_src(bucket, embed_hash, version, index) do
    key =
      if version > 0 do
        "#{embed_hash}/v#{version}/thumbnail_#{index}.jpg"
      else
        "#{embed_hash}/thumbnail_#{index}.jpg"
      end

    SettingsSerializer.storage_object_url(bucket, key)
  end

  defp resolution_label(video, audio_only? \\ false)
  defp resolution_label(_video, true), do: "Audio"

  defp resolution_label(%Video{max_width: width, max_height: height}, _audio_only?)
       when is_integer(width) and width > 0 and is_integer(height) and height > 0 do
    Map.get(@resolution_labels, {width, height}, "Custom")
  end

  defp resolution_label(%Video{audio_tracks: [_ | _]}, _audio_only?), do: "Audio"
  defp resolution_label(_video, _audio_only?), do: nil

  defp fps_value(nil), do: nil

  defp fps_value(%Video{max_frame_rate: frame_rate}) when is_number(frame_rate) do
    frame_rate |> Float.round(0) |> trunc()
  end

  defp fps_value(_video), do: nil

  defp aspect_ratio_value(%Video{aspect_ratio: ratio}) when is_binary(ratio) and ratio != "" do
    ratio
    |> String.replace(":", "/")
    |> String.replace(" ", "")
  end

  defp aspect_ratio_value(%Video{max_width: width, max_height: height})
       when is_integer(width) and width > 0 and is_integer(height) and height > 0 do
    "#{width}/#{height}"
  end

  defp aspect_ratio_value(_), do: "16/9"

  defp bitrate_mbit(nil), do: 0

  defp bitrate_mbit(value) when is_integer(value) do
    value
    |> Kernel./(1_000_000)
    |> Float.round(1)
  end

  defp bitrate_mbit(_), do: 0

  defp audio_only_source?(video, run, current_version, audio_tracks) do
    metadata =
      if match?(%Run{}, run) and flow_run_version(run) == current_version do
        inspected_source_metadata(run.step_runs)
      end

    case metadata do
      %{"has_audio" => has_audio, "has_video" => has_video} ->
        has_audio == true and has_video == false

      _ ->
        match?(
          %Video{max_width: width, max_height: height}
          when width in [nil, 0] and height in [nil, 0],
          video
        ) and audio_tracks != []
    end
  end

  defp audio_tracks_for(nil), do: []

  defp audio_tracks_for(%Video{id: video_id}) do
    AudioTrack
    |> where([track], track.video_id == ^video_id)
    |> order_by([track], asc: track.inserted_at)
    |> Repo.all()
    |> Enum.map(&serialize_audio_track/1)
  end

  defp subtitles_for(_space, _video_embed, nil, _version), do: []

  defp subtitles_for(
         %Space{} = space,
         %Embed{} = video_embed,
         %Video{id: video_id},
         version
       ) do
    bucket = Storage.bucket_for_space(space.hash, space.region)

    video_id
    |> MaveCore.Assets.all_subtitles_for_video()
    |> Enum.map(&serialize_subtitle(&1, bucket, video_embed.hash, version))
  end

  defp renditions_for(nil, _flow_run), do: []

  defp renditions_for(%Video{}, %Run{status: status} = run)
       when status in ["queued", "running", "failed"] do
    flow_renditions_for(run)
  end

  defp renditions_for(%Video{status: status, id: video_id}, _flow_run)
       when status in @ready_video_statuses do
    from(r in "renditions",
      where: r.video_id == type(^video_id, MaveCore.Ecto.LegacyShortUUID),
      order_by: [desc: r.inserted_at],
      select: %{
        id: type(r.id, MaveCore.Ecto.LegacyShortUUID),
        type: r.type,
        codec: r.codec,
        container: r.container,
        size: r.size,
        progress: r.progress
      }
    )
    |> Repo.all()
    |> Enum.map(&serialize_rendition/1)
    |> Enum.filter(&dashboard_rendition_visible?/1)
  end

  defp renditions_for(%Video{}, %Run{} = run), do: flow_renditions_for(run)

  defp renditions_for(%Video{}, nil), do: []

  defp flow_renditions_for(%Run{} = run) do
    runtime_plan = flow_rendition_runtime_plan(run.step_runs)
    transcode_progress_by_variant = transcode_progress_by_variant(run.step_runs, runtime_plan)

    pending =
      run.step_runs
      |> Enum.flat_map(&planned_flow_renditions(&1, transcode_progress_by_variant, runtime_plan))
      |> Enum.map(&serialize_flow_rendition(&1, &1.progress || 0))

    finished =
      run.step_runs
      |> Enum.flat_map(&successful_flow_renditions/1)
      |> Enum.map(&serialize_flow_rendition(&1, 100))

    (pending ++ finished)
    |> Enum.reduce(%{}, fn rendition, acc ->
      Map.put(acc, flow_rendition_signature(rendition), rendition)
    end)
    |> Map.values()
    |> Enum.filter(&dashboard_rendition_visible?/1)
    |> Enum.sort_by(fn rendition ->
      {processing_type_index(rendition.type), size_index(rendition.size_key), rendition.id}
    end)
  end

  defp flow_summary_for(%Run{} = run), do: serialize_flow_summary(run)
  defp flow_summary_for(nil), do: nil

  defp serialize_flow_summary(%Run{} = run) do
    definition =
      case run.flow_version do
        %{definition: definition} when is_map(definition) -> definition
        _ -> %{}
      end

    definition_steps = Definition.steps(definition)

    step_order =
      definition_steps
      |> Enum.with_index()
      |> Map.new(fn {step, index} -> {step["id"], index} end)

    definition_by_id = Map.new(definition_steps, &{&1["id"], &1})

    steps =
      run.step_runs
      |> Enum.map(&serialize_flow_step(&1, definition_by_id, step_order))
      |> Enum.sort_by(fn step -> {step.position, step.name, step.id} end)

    active_step =
      steps
      |> Enum.find(&(&1.status == "executing")) ||
        Enum.find(steps, &(&1.status == "scheduled")) ||
        Enum.find(steps, &(&1.status == "queued"))

    last_completed_step =
      steps
      |> Enum.filter(&(&1.status in ["succeeded", "failed", "skipped", "cancelled"]))
      |> Enum.sort_by(&flow_step_completed_sort/1, :desc)
      |> List.first()

    summary =
      Enum.reduce(steps, %{total: length(steps)}, fn step, acc ->
        increment_flow_summary(acc, step.status)
      end)

    %{
      id: run.id,
      status: run.status,
      error: run.error,
      template_slug: run.flow_template && run.flow_template.slug,
      template_name: run.flow_template && run.flow_template.name,
      version: run.flow_version && run.flow_version.version,
      active_step: active_step,
      last_completed_step: last_completed_step,
      summary:
        Map.merge(
          %{
            queued: 0,
            scheduled: 0,
            executing: 0,
            succeeded: 0,
            failed: 0,
            skipped: 0,
            cancelled: 0
          },
          summary
        ),
      steps: steps
    }
  end

  defp serialize_flow_step(%StepRun{} = step_run, definition_by_id, step_order) do
    step_definition = Map.get(definition_by_id, step_run.step_id, %{})

    depends_on =
      step_definition
      |> Map.get("depends_on", [])
      |> Enum.map(&serialize_flow_dependency(&1, definition_by_id))

    %{
      id: step_run.step_id,
      name: Map.get(step_definition, "name", step_run.step_id),
      type: step_run.step_type,
      status: step_run.status,
      position: Map.get(step_order, step_run.step_id, 9999),
      lane: Map.get(step_definition, "lane", "normal"),
      depends_on: depends_on,
      required: Definition.required?(step_definition),
      attempt: step_run.attempt,
      error: step_run.error,
      updated_at: step_run.updated_at,
      completed_at: step_run.completed_at
    }
  end

  defp increment_flow_summary(acc, "queued"), do: Map.update(acc, :queued, 1, &(&1 + 1))
  defp increment_flow_summary(acc, "scheduled"), do: Map.update(acc, :scheduled, 1, &(&1 + 1))
  defp increment_flow_summary(acc, "executing"), do: Map.update(acc, :executing, 1, &(&1 + 1))
  defp increment_flow_summary(acc, "succeeded"), do: Map.update(acc, :succeeded, 1, &(&1 + 1))
  defp increment_flow_summary(acc, "failed"), do: Map.update(acc, :failed, 1, &(&1 + 1))
  defp increment_flow_summary(acc, "skipped"), do: Map.update(acc, :skipped, 1, &(&1 + 1))
  defp increment_flow_summary(acc, "cancelled"), do: Map.update(acc, :cancelled, 1, &(&1 + 1))
  defp increment_flow_summary(acc, _), do: acc

  defp flow_step_completed_sort(step) do
    step.completed_at || step.updated_at || ~U[1970-01-01 00:00:00Z]
  end

  defp latest_processing_run(space_hash, embed_hash) do
    latest_matching_run(space_hash, embed_hash, ["queued", "running"])
  end

  defp latest_flow_run(space_hash, embed_hash) do
    latest_matching_run(space_hash, embed_hash, nil)
  end

  defp latest_matching_run(space_hash, embed_hash, statuses) do
    query =
      from(run in Run,
        where:
          fragment("?->>'space_hash' = ?", run.input, ^space_hash) and
            fragment("?->>'embed_hash' = ?", run.input, ^embed_hash),
        order_by: [desc: run.inserted_at],
        limit: 1,
        preload: [:step_runs, :flow_template, :flow_version]
      )

    query =
      if is_list(statuses) do
        from(run in query, where: run.status in ^statuses)
      else
        query
      end

    Repo.one(query)
  end

  defp processing_player_ready_for_version?(%Run{} = run, current_version) do
    if flow_run_version(run) == current_version do
      processing_player_ready?(run)
    else
      false
    end
  end

  defp processing_player_ready_for_version?(_run, _current_version), do: false

  defp flow_run_version(%Run{input: input}) when is_map(input) do
    case Map.get(input, "version", 0) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, _rest} -> parsed
          :error -> 0
        end

      _ ->
        0
    end
  end

  defp flow_run_version(_run), do: 0

  defp processing_player_ready?(%Run{
         step_runs: step_runs
       }) do
    processing_player_published?(step_runs)
  end

  defp processing_player_ready?(_run), do: false

  defp processing_player_published?(step_runs) when is_list(step_runs) do
    Enum.any?(step_runs, fn
      %StepRun{
        status: "succeeded",
        execution_metadata: %{"processing_player" => %{"ready" => true}}
      } ->
        true

      _ ->
        false
    end)
  end

  defp processing_player_published?(_step_runs), do: false

  defp video_row_state(_space, _embed, %Video{status: status})
       when status in @ready_video_statuses,
       do: nil

  defp video_row_state(%Space{} = space, %Embed{} = embed, current_video) do
    flow_state =
      space.hash
      |> latest_flow_run(embed.hash)
      |> flow_run_row_state()

    cond do
      flow_state in [:queued, :processing, :failed] ->
        flow_state

      failed_video?(current_video) ->
        :failed

      processing_video_row?(space, embed, current_video) ->
        :processing

      true ->
        nil
    end
  end

  defp flow_run_row_state(%Run{status: "failed"}), do: :failed
  defp flow_run_row_state(%Run{status: "cancelled"}), do: :failed

  defp flow_run_row_state(%Run{status: status, step_runs: step_runs} = run)
       when status in ["queued", "running"] and is_list(step_runs) do
    cond do
      Enum.any?(step_runs, &required_step_failed?(run, &1)) ->
        :failed

      Enum.any?(step_runs, &(&1.status == "executing")) ->
        :processing

      Enum.any?(step_runs, &(&1.status in ["queued", "scheduled"])) ->
        :queued

      true ->
        nil
    end
  end

  defp flow_run_row_state(_run), do: nil

  defp required_step_failed?(%Run{flow_version: %{definition: definition}}, %StepRun{} = step)
       when is_map(definition) do
    step.status == "failed" and
      definition
      |> Map.get("steps", [])
      |> Enum.find(&(Map.get(&1, "id") == step.step_id))
      |> Definition.required?()
  end

  defp required_step_failed?(_run, %StepRun{status: "failed"}), do: true
  defp required_step_failed?(_run, _step), do: false

  defp failed_video?(%Video{status: "failed"}), do: true
  defp failed_video?(_video), do: false

  defp processing_video_row?(_space, _embed, %Video{status: status})
       when status not in @ready_video_statuses,
       do: true

  defp processing_video_row?(_space, _embed, %Video{}), do: false

  defp processing_video_row?(%Space{} = space, %Embed{} = embed, _current_video) do
    match?(%Run{}, latest_processing_run(space.hash, embed.hash))
  end

  defp planned_flow_renditions(
         %StepRun{status: status} = step_run,
         transcode_progress_by_variant,
         runtime_plan
       )
       when status in ["queued", "scheduled", "executing", "failed"] do
    progress = planned_step_progress(step_run)
    params = get_in(step_run.input || %{}, ["params"]) || %{}

    planned_flow_renditions_for_type(
      step_run.step_type,
      step_run,
      params,
      progress,
      status,
      transcode_progress_by_variant,
      runtime_plan
    )
  end

  defp planned_flow_renditions(_step_run, _transcode_progress_by_variant, _runtime_plan), do: []

  defp planned_flow_renditions_for_type(
         "media.transcode_video",
         step_run,
         params,
         progress,
         status,
         _transcode_progress_by_variant,
         runtime_plan
       ) do
    case planned_transcode_rendition(step_run, params, progress, status, runtime_plan) do
      nil -> []
      rendition -> [rendition]
    end
  end

  defp planned_flow_renditions_for_type(
         "media.transcode_h264_ladder",
         step_run,
         params,
         progress,
         status,
         _transcode_progress_by_variant,
         runtime_plan
       ) do
    planned_h264_ladder_renditions(step_run, params, progress, status, runtime_plan)
  end

  defp planned_flow_renditions_for_type(
         "media.package_hls_variant",
         step_run,
         params,
         _progress,
         status,
         transcode_progress_by_variant,
         runtime_plan
       ) do
    case planned_hls_rendition(
           step_run,
           params,
           planned_hls_step_progress(step_run),
           status,
           transcode_progress_by_variant,
           runtime_plan
         ) do
      nil -> []
      rendition -> [rendition]
    end
  end

  defp planned_flow_renditions_for_type(
         "media.extract_frame",
         step_run,
         params,
         progress,
         status,
         _transcode_progress_by_variant,
         runtime_plan
       ) do
    planned_image_renditions(step_run, params, progress, status, runtime_plan)
  end

  defp planned_flow_renditions_for_type(
         "media.generate_storyboard",
         step_run,
         params,
         progress,
         status,
         _transcode_progress_by_variant,
         runtime_plan
       ) do
    planned_storyboard_renditions(step_run, params, progress, status, runtime_plan)
  end

  defp planned_flow_renditions_for_type(
         "ai.transcribe_audio",
         step_run,
         _params,
         progress,
         status,
         _transcode_progress_by_variant,
         runtime_plan
       ) do
    planned_transcription_renditions(step_run, progress, status, runtime_plan)
  end

  defp planned_flow_renditions_for_type(
         "ai.translate_subtitles",
         step_run,
         params,
         progress,
         status,
         _transcode_progress_by_variant,
         runtime_plan
       ) do
    planned_translation_renditions(step_run, params, progress, status, runtime_plan)
  end

  defp planned_flow_renditions_for_type(
         _step_type,
         _step_run,
         _params,
         _progress,
         _status,
         _transcode_progress_by_variant,
         _runtime_plan
       ),
       do: []

  defp planned_step_progress(%StepRun{status: status} = step_run)
       when status in ["queued", "scheduled", "executing"] do
    fallback = if status == "executing", do: 1.0, else: 0.0
    step_progress(step_run, fallback)
  end

  defp planned_step_progress(_step_run), do: 0.0

  defp planned_hls_step_progress(%StepRun{status: "executing"} = step_run) do
    step_progress(step_run, 1.0)
  end

  defp planned_hls_step_progress(_step_run), do: 0.0

  defp step_progress(%StepRun{execution_metadata: metadata}, fallback) when is_map(metadata) do
    case normalize_progress(get_in(metadata, ["progress", "percent"])) do
      0 -> fallback
      progress -> progress * 1.0
    end
  end

  defp step_progress(_step_run, fallback), do: fallback

  defp flow_rendition_runtime_plan(step_runs) when is_list(step_runs) do
    %{
      source_metadata: inspected_source_metadata(step_runs),
      h264_ladder_sizes_by_step_id: h264_ladder_sizes_by_step_id(step_runs),
      step_runs_by_id: Map.new(step_runs, &{&1.step_id, &1})
    }
  end

  defp flow_rendition_runtime_plan(_step_runs) do
    %{source_metadata: nil, h264_ladder_sizes_by_step_id: %{}, step_runs_by_id: %{}}
  end

  defp inspected_source_metadata(step_runs) do
    step_runs
    |> Enum.find(fn
      %StepRun{step_id: "inspect_media", status: "succeeded", output: output} -> is_map(output)
      _ -> false
    end)
    |> case do
      %StepRun{output: output} -> output
      _ -> nil
    end
  end

  defp h264_ladder_sizes_by_step_id(step_runs) do
    step_runs
    |> Enum.reduce(%{}, fn
      %StepRun{step_type: "media.transcode_h264_ladder", output: %{} = output} = step_run, acc ->
        case h264_ladder_output_sizes(output) do
          [] -> acc
          sizes -> Map.put(acc, step_run.step_id, sizes)
        end

      _step_run, acc ->
        acc
    end)
  end

  defp h264_ladder_output_sizes(output) do
    output_sizes =
      output
      |> map_get_any("sizes")
      |> normalize_h264_ladder_size_list()

    if output_sizes != [] do
      output_sizes
    else
      output
      |> map_get_any("variants")
      |> list_value()
      |> Enum.filter(&(map_get_any(&1, "status") in [nil, "ok"]))
      |> Enum.map(&normalize_h264_ladder_size(map_get_any(&1, "size")))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
    end
  end

  defp transcode_progress_by_variant(step_runs, runtime_plan) when is_list(step_runs) do
    step_runs
    |> Enum.reduce(%{}, fn step_run, acc ->
      case downstream_hls_progress(step_run) do
        nil -> acc
        progress -> put_transcode_progress_by_variant(step_run, acc, progress, runtime_plan)
      end
    end)
  end

  defp transcode_progress_by_variant(_step_runs, _runtime_plan), do: %{}

  defp downstream_hls_progress(%StepRun{status: status} = step_run)
       when status in ["scheduled", "executing"] do
    fallback = if status == "executing", do: 1.0, else: 0.0
    progress = step_progress(step_run, fallback)

    cond do
      progress <= 0 ->
        nil

      step_progress_stage(step_run) == "package_hls" ->
        combined_hls_progress(@hls_transcode_phase_complete_progress, progress)

      true ->
        hls_transcode_phase_progress(progress)
    end
  end

  defp downstream_hls_progress(%StepRun{status: "succeeded"}),
    do: @hls_transcode_phase_complete_progress

  defp downstream_hls_progress(_step_run), do: nil

  defp step_progress_stage(%StepRun{execution_metadata: metadata}) when is_map(metadata) do
    normalize_rendition_value(get_in(metadata, ["progress", "stage"]))
  end

  defp step_progress_stage(_step_run), do: nil

  defp hls_transcode_phase_progress(progress) do
    progress
    |> clamp_progress()
    |> Kernel.*(@hls_transcode_phase_complete_progress / 100.0)
    |> min(@hls_transcode_phase_complete_progress)
  end

  defp put_transcode_progress_by_variant(
         %StepRun{step_type: "media.transcode_video"} = step_run,
         acc,
         progress,
         _runtime_plan
       ) do
    params = get_in(step_run.input || %{}, ["params"]) || %{}

    key =
      {normalize_rendition_value(Map.get(params, "codec") || "h264"),
       normalize_rendition_value(Map.get(params, "size") || "sd")}

    Map.put(acc, key, progress)
  end

  defp put_transcode_progress_by_variant(
         %StepRun{step_type: "media.transcode_h264_ladder"} = step_run,
         acc,
         progress,
         runtime_plan
       ) do
    params = get_in(step_run.input || %{}, ["params"]) || %{}

    step_run
    |> h264_ladder_sizes(params, runtime_plan)
    |> Enum.reduce(acc, fn size, acc ->
      Map.put(acc, {"h264", size}, progress)
    end)
  end

  defp put_transcode_progress_by_variant(_step_run, acc, _progress, _runtime_plan), do: acc

  defp successful_flow_renditions(%StepRun{
         status: "succeeded",
         step_type: step_type,
         output: %{"status" => "ok", "subtitles" => subtitles}
       })
       when step_type in ["ai.transcribe_audio", "ai.translate_subtitles"] and
              is_list(subtitles) do
    Enum.flat_map(subtitles, fn
      %{} = subtitle ->
        [
          subtitle
          |> Map.put("type", "subtitle")
          |> Map.put("codec", "vtt")
          |> Map.put("container", "vtt")
          |> Map.put("progress", 100)
        ]

      _subtitle ->
        []
    end)
  end

  defp successful_flow_renditions(
         %StepRun{status: "succeeded", output: %{"status" => "ok"}} = step_run
       ) do
    case step_run.output["renditions"] do
      renditions when is_list(renditions) -> Enum.filter(renditions, &is_map/1)
      _ -> []
    end
  end

  defp successful_flow_renditions(_step_run), do: []

  defp serialize_flow_rendition(rendition, progress_override) do
    type = flow_rendition_type(rendition)
    container = normalize_rendition_value(map_get_any(rendition, "container"))
    size = normalize_rendition_value(map_get_any(rendition, "size"))
    codec = normalize_rendition_value(map_get_any(rendition, "codec"))
    phase = normalize_rendition_value(map_get_any(rendition, "phase"))
    language = normalize_rendition_value(map_get_any(rendition, "language"))

    %{
      id: map_get_any(rendition, "id") || Ecto.UUID.generate(),
      type: type,
      container: container,
      container_label: rendition_container_label(container),
      size: rendition_size_label(size),
      size_key: size,
      codec: rendition_codec_label(type, codec, container),
      codec_key: codec,
      language: language,
      label: normalize_rendition_value(map_get_any(rendition, "label")),
      status: flow_rendition_status(rendition, progress_override),
      phase: phase,
      progress: normalize_progress(progress_override)
    }
  end

  defp flow_rendition_status(rendition, progress) do
    case normalize_rendition_value(map_get_any(rendition, "status")) do
      status when status in ["queued", "scheduled", "executing", "failed", "succeeded"] ->
        status

      _ ->
        if normalize_progress(progress) >= 100, do: "succeeded", else: "queued"
    end
  end

  defp flow_rendition_type(%{"type" => "image", "role" => role}), do: image_role_type(role)
  defp flow_rendition_type(%{"type" => type}) when is_binary(type), do: type
  defp flow_rendition_type(%{type: "image", role: role}), do: image_role_type(role)
  defp flow_rendition_type(%{type: type}) when is_binary(type), do: type
  defp flow_rendition_type(_), do: "video"

  defp image_role_type("poster"), do: "poster"
  defp image_role_type("thumbnail"), do: "thumbnail"
  defp image_role_type("placeholder"), do: "placeholder"
  defp image_role_type("custom_thumbnail"), do: "custom_thumbnail"
  defp image_role_type(_), do: "image"

  defp flow_rendition_signature(rendition) do
    {rendition.type, rendition.size_key, rendition.codec_key, rendition.container,
     rendition.language}
  end

  defp map_get_any(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp map_get_any(_map, _key), do: nil

  defp list_value(value) when is_list(value), do: value
  defp list_value(_value), do: []

  defp processing_type_index("video"), do: 0
  defp processing_type_index("audio"), do: 1
  defp processing_type_index("clip"), do: 2
  defp processing_type_index("clip_keyframes"), do: 3
  defp processing_type_index("subtitle"), do: 4
  defp processing_type_index("poster"), do: 5
  defp processing_type_index("thumbnail"), do: 6
  defp processing_type_index("placeholder"), do: 7
  defp processing_type_index("storyboard"), do: 8
  defp processing_type_index("segments"), do: 9
  defp processing_type_index(_), do: 99

  defp processing_rendition_type(_codec, 2), do: "clip_keyframes"

  defp processing_rendition_type(codec, _keyframe_interval) when codec in ["hevc", "av1"],
    do: "clip"

  defp processing_rendition_type(_codec, _keyframe_interval), do: "video"

  defp processing_integer_value(value) when is_integer(value), do: value

  defp processing_integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  defp processing_integer_value(_value), do: nil

  defp serialize_audio_track(%AudioTrack{} = track) do
    %{
      id: track.id,
      label: track.label || "Original",
      language: track.language,
      default: track.default,
      codec: track.codec && String.upcase(track.codec),
      file_size: track.file_size,
      filename: track.filename
    }
  end

  defp serialize_subtitle(subtitle, bucket, embed_hash, version) do
    %{
      id: subtitle.id,
      language: subtitle.language,
      label:
        Languages.spoken_language(subtitle.language) || String.upcase(subtitle.language || ""),
      path: subtitle_public_url(bucket, subtitle.path, embed_hash, version, subtitle.language)
    }
  end

  defp subtitle_public_url(bucket, path, embed_hash, version, language) do
    if external_subtitle_url?(path) do
      path
    else
      SettingsSerializer.storage_object_url(
        bucket,
        subtitle_storage_key(path, embed_hash, version, language)
      )
    end
  end

  defp collection_video_count(nil, _space_id), do: 0

  defp collection_video_count(collection_id, space_id) do
    collection_id
    |> count_collection_videos(space_id, MapSet.new())
    |> elem(0)
  end

  defp archive_video_embed!(%Embed{} = embed, archived) do
    Repo.delete_all(from(ce in CollectionEmbed, where: ce.embed_id == ^embed.id))

    embed
    |> Embed.changeset(%{archived: archived})
    |> Repo.update!()
  end

  defp archive_collection_embed!(%Embed{} = embed, archived, now) do
    maybe_toggle_collection_tree(embed, archived, now)

    embed
    |> Embed.changeset(%{archived: archived})
    |> Repo.update!()
  end

  defp maybe_toggle_collection_tree(
         %Embed{collection_id: collection_id, space_id: space_id},
         archived,
         now
       )
       when is_binary(collection_id) do
    toggle_collection_tree(collection_id, space_id, archived, MapSet.new(), now)
  end

  defp maybe_toggle_collection_tree(_embed, _archived, _now), do: :ok

  defp delete_embed_record!(%Embed{type: :video} = embed) do
    cancel_video_embed_runs!(embed)

    embed
    |> Embed.changeset(%{deleted_at: now_utc()})
    |> Repo.update!()
  end

  defp delete_embed_record!(%Embed{type: :collection} = embed) do
    maybe_delete_embed_collection(embed)
    Repo.delete!(embed)
  end

  defp cancel_video_embed_runs!(embed) do
    case MaveCore.Flow.cancel_runs_for_embed(embed.space.hash, embed.hash) do
      {:ok, _count} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp maybe_delete_embed_collection(%Embed{collection: nil}), do: :ok
  defp maybe_delete_embed_collection(%Embed{collection: collection}), do: Repo.delete!(collection)

  defp collect_descendant_folder_embed_ids(visited, embed_id, space_id) do
    from(ce in CollectionEmbed,
      join: parent in Collection,
      on: ce.collection_id == parent.id,
      join: e in assoc(ce, :embed),
      where: parent.space_id == ^space_id,
      where: e.type == :collection and is_nil(e.deleted_at),
      join: container in Embed,
      on: container.collection_id == parent.id,
      where: container.id == ^embed_id,
      select: e.id
    )
    |> Repo.all()
    |> Enum.reduce(visited, fn child_id, acc ->
      descendant_folder_embed_ids(child_id, space_id, acc)
    end)
  end

  defp toggle_collection_rows(visited, collection_id, space_id, archived, now) do
    collection_rows(collection_id, space_id)
    |> Enum.reduce(visited, fn row, acc ->
      toggle_collection_row(row, space_id, archived, acc, now)
    end)
  end

  defp collection_rows(collection_id, space_id) do
    from(ce in CollectionEmbed,
      join: e in assoc(ce, :embed),
      where: ce.collection_id == ^collection_id,
      where: e.space_id == ^space_id and is_nil(e.deleted_at),
      select: {e.id, e.type, e.collection_id}
    )
    |> Repo.all()
  end

  defp toggle_collection_row(
         {embed_id, type, nested_collection_id},
         space_id,
         archived,
         visited,
         now
       ) do
    from(e in Embed, where: e.id == ^embed_id)
    |> Repo.update_all(set: [archived: archived, updated_at: now])

    if type == :collection do
      toggle_collection_tree(nested_collection_id, space_id, archived, visited, now)
    else
      visited
    end
  end

  defp count_collection_video_rows(visited, collection_id, space_id) do
    collection_video_rows(collection_id, space_id)
    |> Enum.reduce({0, visited}, &count_collection_video_row(&1, space_id, &2))
  end

  defp collection_video_rows(collection_id, space_id) do
    from(ce in CollectionEmbed,
      join: e in assoc(ce, :embed),
      where: ce.collection_id == ^collection_id,
      where: e.space_id == ^space_id and is_nil(e.deleted_at),
      select: {e.type, e.collection_id}
    )
    |> Repo.all()
  end

  defp count_collection_video_row({:video, _collection_id}, _space_id, {count, visited}) do
    {count + 1, visited}
  end

  defp count_collection_video_row({:collection, nested_collection_id}, space_id, {count, visited}) do
    {nested_count, next_visited} =
      count_collection_videos(nested_collection_id, space_id, visited)

    {count + nested_count, next_visited}
  end

  defp count_collection_video_row(_row, _space_id, acc), do: acc

  defp first_present_name(names) do
    Enum.find(names, &is_binary/1) || "Untitled"
  end

  defp serialize_flow_dependency(dependency_id, definition_by_id) do
    dependency_definition = Map.get(definition_by_id, dependency_id, %{})

    %{
      id: dependency_id,
      name: Map.get(dependency_definition, "name", dependency_id)
    }
  end

  defp planned_transcode_rendition(step_run, params, progress, status, runtime_plan) do
    codec = normalize_rendition_value(Map.get(params, "codec") || "h264")
    keyframe_interval = processing_integer_value(Map.get(params, "keyframe_interval"))
    size = normalize_rendition_value(Map.get(params, "size") || "sd")

    if transcode_size_plannable?(params, size, runtime_plan) do
      %{
        id: "pending-#{step_run.id}",
        type: processing_rendition_type(codec, keyframe_interval),
        codec: codec,
        container: normalize_rendition_value(Map.get(params, "container") || "mp4"),
        size: size,
        status: status,
        progress: progress
      }
    end
  end

  defp transcode_size_plannable?(params, size, runtime_plan) do
    conditional_size? =
      Map.get(params, "conditional_size", Map.get(params, "conditional_sizes", true)) in [
        true,
        "true",
        1,
        "1"
      ]

    source_metadata = Map.get(runtime_plan, :source_metadata)

    cond do
      not conditional_size? -> true
      size == "sd" -> is_nil(source_metadata) or inspected_video?(runtime_plan)
      is_nil(source_metadata) -> false
      not inspected_video?(runtime_plan) -> false
      true -> RenditionSizing.source_allows_size?(source_metadata, size)
    end
  end

  defp planned_image_renditions(step_run, params, progress, status, runtime_plan) do
    if inspected_video?(runtime_plan) do
      role = normalize_rendition_value(Map.get(params, "role")) || "image"
      codec = normalize_rendition_value(Map.get(params, "codec")) || "jpg"

      [
        %{
          id: "pending-#{step_run.id}",
          type: "image",
          role: role,
          codec: codec,
          container: codec,
          status: status,
          progress: progress
        }
      ]
    else
      []
    end
  end

  defp planned_storyboard_renditions(step_run, params, progress, status, runtime_plan) do
    if inspected_video?(runtime_plan) do
      codec = normalize_rendition_value(Map.get(params, "codec")) || "jpg"

      [
        %{
          id: "pending-#{step_run.id}",
          type: "storyboard",
          codec: codec,
          container: codec,
          status: status,
          progress: progress
        }
      ]
    else
      []
    end
  end

  defp planned_transcription_renditions(step_run, progress, status, runtime_plan) do
    if inspected_audio?(runtime_plan) do
      [
        %{
          id: "pending-#{step_run.id}",
          type: "subtitle",
          codec: "vtt",
          container: "vtt",
          label: "Subtitles",
          status: status,
          progress: progress
        }
      ]
    else
      []
    end
  end

  defp planned_translation_renditions(step_run, params, progress, status, runtime_plan) do
    if inspected_audio?(runtime_plan) and status != "queued" do
      language = normalize_rendition_value(Map.get(params, "target_language")) || "en"

      [
        %{
          id: "pending-#{step_run.id}",
          type: "subtitle",
          codec: "vtt",
          container: "vtt",
          language: language,
          label: Languages.spoken_language(language) || String.upcase(language),
          status: status,
          progress: progress
        }
      ]
    else
      []
    end
  end

  defp inspected_video?(runtime_plan) do
    case Map.get(runtime_plan, :source_metadata) do
      %{} = metadata -> Map.get(metadata, "has_video", is_number(Map.get(metadata, "width")))
      _metadata -> false
    end
  end

  defp inspected_audio?(runtime_plan) do
    case Map.get(runtime_plan, :source_metadata) do
      %{} = metadata -> Map.get(metadata, "has_audio", false)
      _metadata -> false
    end
  end

  defp planned_h264_ladder_renditions(step_run, params, progress, status, runtime_plan) do
    step_run
    |> h264_ladder_sizes(params, runtime_plan)
    |> Enum.map(fn size ->
      %{
        id: "pending-#{step_run.id}-#{size}",
        type: "video",
        codec: "h264",
        container: normalize_rendition_value(Map.get(params, "container") || "mp4"),
        size: size,
        status: status,
        progress: progress
      }
    end)
  end

  defp h264_ladder_sizes(%StepRun{} = step_run, params, runtime_plan) do
    output_sizes =
      runtime_plan
      |> Map.get(:h264_ladder_sizes_by_step_id, %{})
      |> Map.get(step_run.step_id, [])

    case output_sizes do
      [] -> h264_ladder_sizes(params, runtime_plan)
      sizes -> sizes
    end
  end

  defp h264_ladder_sizes(params, runtime_plan) do
    source_metadata = Map.get(runtime_plan, :source_metadata)

    if source_resolution_plan_ready?(params, source_metadata) do
      params
      |> h264_ladder_sizes()
      |> source_resolution_filtered_sizes(
        source_metadata,
        Map.get(params, "require_source_resolution", false)
      )
    else
      []
    end
  end

  defp source_resolution_plan_ready?(params, nil),
    do: not Map.get(params, "require_source_resolution", false)

  defp source_resolution_plan_ready?(_params, _source_metadata), do: true

  defp h264_ladder_sizes(params) when is_map(params) do
    params
    |> Map.get("sizes", Map.get(params, "variants", Map.get(params, "size")))
    |> normalize_h264_ladder_sizes()
  end

  defp h264_ladder_sizes(_params), do: ["sd", "hd"]

  defp normalize_h264_ladder_sizes(nil), do: ["sd", "hd"]

  defp normalize_h264_ladder_sizes(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> normalize_h264_ladder_sizes()
  end

  defp normalize_h264_ladder_sizes(values) when is_list(values) do
    values = normalize_h264_ladder_size_list(values)

    values
    |> case do
      [] -> ["sd", "hd"]
      sizes -> sizes
    end
  end

  defp normalize_h264_ladder_sizes(value), do: normalize_h264_ladder_sizes([value])

  defp normalize_h264_ladder_size(%{"size" => size}), do: normalize_h264_ladder_size(size)
  defp normalize_h264_ladder_size(%{size: size}), do: normalize_h264_ladder_size(size)
  defp normalize_h264_ladder_size(size) when is_atom(size), do: Atom.to_string(size)

  defp normalize_h264_ladder_size(size) when is_binary(size) do
    size
    |> normalize_rendition_value()
  end

  defp normalize_h264_ladder_size(_size), do: nil

  defp normalize_h264_ladder_size_list(values) when is_list(values) do
    values
    |> Enum.map(&normalize_h264_ladder_size/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_h264_ladder_size_list(_values), do: []

  defp planned_hls_rendition(
         step_run,
         params,
         progress,
         status,
         transcode_progress_by_variant,
         runtime_plan
       ) do
    codec = normalize_rendition_value(Map.get(params, "codec") || "h264")
    size = normalize_rendition_value(Map.get(params, "size") || "sd")

    if hls_variant_plannable?(params, codec, size, runtime_plan) do
      upstream_progress = Map.get(transcode_progress_by_variant, {codec, size})
      phase = planned_hls_phase(status, upstream_progress)
      {progress, status} = apply_upstream_hls_progress(progress, status, upstream_progress)

      %{
        id: "pending-#{step_run.id}",
        type: "video",
        codec: codec,
        container: "hls",
        size: size,
        status: status,
        phase: phase,
        progress: progress
      }
    end
  end

  defp planned_hls_phase("executing", _upstream_progress), do: "packaging"

  defp planned_hls_phase(status, upstream_progress)
       when status in ["queued", "scheduled"] and is_number(upstream_progress) and
              upstream_progress > 0 and upstream_progress < @hls_transcode_phase_complete_progress,
       do: "encoding"

  defp planned_hls_phase(status, upstream_progress)
       when status in ["queued", "scheduled"] and is_number(upstream_progress) and
              upstream_progress >= @hls_transcode_phase_complete_progress,
       do: "packaging"

  defp planned_hls_phase(status, _upstream_progress) when status in ["queued", "scheduled"],
    do: "queued"

  defp planned_hls_phase(_status, _upstream_progress), do: nil

  defp hls_variant_plannable?(params, codec, size, runtime_plan) do
    source_step_id = normalize_rendition_value(Map.get(params, "source_step_id"))

    cond do
      codec != "h264" ->
        true

      is_binary(source_step_id) and
          h264_ladder_output_sizes_known?(runtime_plan, source_step_id) ->
        size in h264_ladder_output_sizes(runtime_plan, source_step_id)

      true ->
        hls_size_allowed_by_source?(size, Map.get(runtime_plan, :source_metadata))
    end
  end

  defp h264_ladder_output_sizes_known?(runtime_plan, step_id) do
    runtime_plan
    |> Map.get(:h264_ladder_sizes_by_step_id, %{})
    |> Map.has_key?(step_id)
  end

  defp h264_ladder_output_sizes(runtime_plan, step_id) do
    runtime_plan
    |> Map.get(:h264_ladder_sizes_by_step_id, %{})
    |> Map.get(step_id, [])
  end

  defp source_resolution_filtered_sizes(sizes, source_metadata, require_source_resolution?) do
    RenditionSizing.filter_sizes(sizes, source_metadata, require_source_resolution?)
  end

  defp hls_size_allowed_by_source?("sd", _source_metadata), do: true
  defp hls_size_allowed_by_source?(_size, nil), do: false

  defp hls_size_allowed_by_source?(size, source_metadata) do
    RenditionSizing.source_allows_size?(source_metadata, size)
  end

  defp apply_upstream_hls_progress(progress, status, upstream_progress)
       when progress in [0, 0.0] and is_number(upstream_progress) and upstream_progress > 0 do
    status = if status in ["queued", "scheduled"], do: "executing", else: status
    {upstream_progress, status}
  end

  defp apply_upstream_hls_progress(progress, status, upstream_progress)
       when is_number(progress) and is_number(upstream_progress) and upstream_progress > 0 do
    {combined_hls_progress(upstream_progress, progress), status}
  end

  defp apply_upstream_hls_progress(progress, status, _upstream_progress), do: {progress, status}

  defp combined_hls_progress(upstream_progress, packaging_progress) do
    upstream_progress =
      upstream_progress
      |> clamp_progress()
      |> min(@hls_transcode_phase_complete_progress)

    packaging_progress = clamp_progress(packaging_progress)
    packaging_start = max(upstream_progress, @hls_transcode_phase_complete_progress)

    packaging_start
    |> Kernel.+((@hls_combined_progress_cap - packaging_start) * (packaging_progress / 100.0))
    |> min(@hls_combined_progress_cap)
  end

  defp clamp_progress(progress) when is_number(progress) do
    progress
    |> max(0.0)
    |> min(100.0)
  end

  defp external_subtitle_url?(path) do
    is_binary(path) and
      (String.starts_with?(path, "http://") or String.starts_with?(path, "https://"))
  end

  defp subtitle_storage_key(path, _embed_hash, _version, _language)
       when is_binary(path) and path != "" do
    path
  end

  defp subtitle_storage_key(_path, embed_hash, version, language) when version > 0 do
    "#{embed_hash}/v#{version}/subtitle_#{language}.vtt"
  end

  defp subtitle_storage_key(_path, embed_hash, _version, language) do
    "#{embed_hash}/subtitle_#{language}.vtt"
  end

  defp size_index("sd"), do: 0
  defp size_index("hd"), do: 1
  defp size_index("fhd"), do: 2
  defp size_index("qhd"), do: 3
  defp size_index("uhd"), do: 4
  defp size_index(_), do: 99

  defp serialize_rendition(rendition) do
    %{
      id: rendition.id,
      type: normalize_rendition_value(rendition.type),
      container: normalize_rendition_value(rendition.container),
      container_label: rendition_container_label(rendition.container),
      size: rendition_size_label(rendition.size),
      size_key: normalize_rendition_value(rendition.size),
      codec: rendition_codec_label(rendition.type, rendition.codec, rendition.container),
      codec_key: normalize_rendition_value(rendition.codec),
      status: "succeeded",
      progress: normalize_progress(rendition.progress)
    }
  end

  defp rendition_size_label(size) when is_binary(size),
    do: Map.get(@size_labels, size, String.upcase(size))

  defp rendition_size_label(_), do: nil

  defp rendition_codec_label(type, _codec, _container) when type in ["hls", "hls_audio"],
    do: "HLS"

  defp rendition_codec_label(_type, codec, _container) when is_binary(codec) do
    Map.get(@codec_labels, codec, String.upcase(codec))
  end

  defp rendition_codec_label(type, _codec, container)
       when type in ["poster", "thumbnail", "placeholder", "storyboard", "custom_thumbnail"] and
              is_binary(container) do
    rendition_container_label(container)
  end

  defp rendition_codec_label(_type, _codec, _container), do: nil

  defp rendition_container_label(container) when is_binary(container) do
    case container do
      "webp" -> "WebP"
      "webm" -> "WebM"
      "jpg" -> "JPG"
      "mp4" -> "MP4"
      "avif" -> "AVIF"
      "hls" -> "HLS"
      "mp3" -> "MP3"
      other -> String.upcase(other)
    end
  end

  defp rendition_container_label(_container), do: nil

  defp normalize_rendition_value(nil), do: nil
  defp normalize_rendition_value(value) when is_binary(value), do: value
  defp normalize_rendition_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_rendition_value(_value), do: nil

  defp normalize_dashboard_page(page) when is_integer(page) and page > 0, do: page

  defp normalize_dashboard_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {parsed, _rest} when parsed > 0 -> parsed
      _ -> 1
    end
  end

  defp normalize_dashboard_page(_page), do: 1

  defp normalize_dashboard_per_page(per_page) when is_integer(per_page) and per_page > 0,
    do: per_page

  defp normalize_dashboard_per_page(_per_page), do: @dashboard_per_page

  defp normalize_progress(nil), do: 0

  defp normalize_progress(progress) when is_integer(progress) do
    progress
    |> min(100)
    |> max(0)
  end

  defp normalize_progress(progress) when is_float(progress) do
    progress
    |> Float.round(0)
    |> trunc()
    |> min(100)
    |> max(0)
  end

  defp normalize_progress(_progress), do: 0

  defp dashboard_rendition_visible?(%{type: "video", container: "hls", size_key: size_key})
       when size_key in [nil, "master"] do
    false
  end

  defp dashboard_rendition_visible?(_rendition), do: true

  defp int_or_zero(nil), do: 0
  defp int_or_zero(value) when is_integer(value), do: value
  defp int_or_zero(_), do: 0

  defp format_date(nil), do: "-"

  defp format_date(datetime) do
    Calendar.strftime(datetime, "%d %b %Y")
  end

  defp video_analytics(space_hash, embed_hash) do
    case VideoAnalytics.data(space_hash, embed_hash) do
      {:ok, analytics} ->
        analytics

      _ ->
        %{views: %{today: 0, month: 0, year: 0}, sources: [], dropoff: %{per_second: []}}
    end
  end

  defp check_available_hash(hash) when is_binary(hash) do
    from(e in Embed, where: e.hash == ^hash, select: count(e.id))
    |> Repo.one()
    |> Kernel.==(0)
  end

  defp generate_hash do
    hash = generate_hash_unsafe()

    if check_available_hash(hash) do
      hash
    else
      generate_hash()
    end
  end

  defp generate_hash_unsafe do
    for _ <- 1..@hash_length, into: "" do
      <<:binary.at(@hash_chars, :rand.uniform(byte_size(@hash_chars)) - 1)>>
    end
  end

  defp upload_asset_name(nil), do: nil

  defp upload_asset_name(value) when is_binary(value) do
    value
    |> Path.rootname()
    |> String.trim()
    |> case do
      "" -> nil
      name -> name
    end
  end

  defp upload_asset_name(_value), do: nil

  defp upload_file_name(nil), do: nil

  defp upload_file_name(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      name -> name
    end
  end

  defp upload_file_name(_value), do: nil

  defp parse_upload_integer(value) when is_integer(value), do: value

  defp parse_upload_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_upload_integer(_value), do: nil

  defp maybe_reset_poster_for_replacement(%Embed{settings: %EmbedSettings{} = settings}) do
    if is_binary(settings.external_poster) and settings.external_poster != "" do
      :ok
    else
      settings
      |> EmbedSettings.changeset(%{
        poster: :upload,
        external_poster: nil,
        poster_time_seconds: nil,
        poster_time_hour: nil,
        poster_time_minute: nil,
        poster_time_second: nil
      })
      |> Repo.update!()

      :ok
    end
  end

  defp maybe_reset_poster_for_replacement(_embed), do: :ok

  defp current_video_from_embed(%Embed{asset: %{current_video: current_video}}), do: current_video
  defp current_video_from_embed(_embed), do: nil
end
