defmodule MaveCore.Assets do
  @moduledoc """
  Asset-side helpers that sit next to the dashboard read model.
  """

  import Ecto.Query, warn: false

  alias MaveCore.Assets.{AudioTrack, Subtitle, Video}
  alias MaveCore.Embeds
  alias MaveCore.Embeds.{Embed, ManifestPublisher, SettingsSerializer}
  alias MaveCore.EncodingBooster

  alias MaveCore.Flow.Steps.{
    MediaBuildHlsMasterStep,
    MediaExtractFrameStep,
    MediaPackageHlsAudioStep
  }

  alias MaveCore.Languages
  alias MaveCore.Media.CdnCache
  alias MaveCore.Media.ContentType
  alias MaveCore.Media.Signature
  alias MaveCore.Media.Storage
  alias MaveCore.Repo
  alias MaveCore.Workers.ImageProcessor

  @audio_hls_bandwidth 128_000
  @audio_hls_channels "2"
  @custom_thumbnail_containers ~w(jpg webp avif)
  @custom_thumbnail_required_container "jpg"

  def get_audio_track(id) when is_binary(id), do: Repo.get(AudioTrack, id)
  def get_audio_track(_), do: nil

  def get_audio_track_for_video(id, video_id) when is_binary(id) and is_binary(video_id) do
    Repo.get_by(AudioTrack, id: id, video_id: video_id)
  end

  def get_audio_track_for_video(_, _), do: nil

  def get_audio_track_for_embed(id, %Embed{} = embed) when is_binary(id) do
    embed = Repo.preload(embed, :asset)
    video_id = embed.asset && embed.asset.current_video_id
    get_audio_track_for_video(id, video_id)
  end

  def get_audio_track_for_embed(_, _), do: nil

  def audio_tracks_for_video(video_id) when is_binary(video_id) do
    AudioTrack
    |> where([track], track.video_id == ^video_id)
    |> order_by([track], asc: track.inserted_at)
    |> Repo.all()
  end

  def audio_tracks_for_video(_), do: []

  def subtitles_for_video(video_id) when is_binary(video_id) do
    Subtitle
    |> where([subtitle], subtitle.video_id == ^video_id)
    |> order_by([subtitle], asc: subtitle.inserted_at)
    |> Repo.all()
  end

  def subtitles_for_video(_), do: []

  def all_subtitles_for_video(video_id) when is_binary(video_id) do
    Subtitle
    |> where([subtitle], subtitle.video_id == ^video_id)
    |> order_by([subtitle], asc: subtitle.inserted_at)
    |> Repo.all()
  end

  def all_subtitles_for_video(_), do: []

  def get_subtitle(id) when is_binary(id), do: Repo.get(Subtitle, id)
  def get_subtitle(_), do: nil

  def get_subtitle_for_video(id, video_id) when is_binary(id) and is_binary(video_id) do
    Repo.get_by(Subtitle, id: id, video_id: video_id)
  end

  def get_subtitle_for_video(_, _), do: nil

  def get_subtitle_for_embed(id, %Embed{} = embed) when is_binary(id) do
    embed = Repo.preload(embed, :asset)
    video_id = embed.asset && embed.asset.current_video_id
    get_subtitle_for_video(id, video_id)
  end

  def get_subtitle_for_embed(_, _), do: nil

  def create_subtitle(attrs \\ %{}) when is_map(attrs) do
    %Subtitle{}
    |> Subtitle.changeset(attrs)
    |> Repo.insert()
  end

  def update_subtitle(%Subtitle{} = subtitle, attrs \\ %{}) when is_map(attrs) do
    subtitle
    |> Subtitle.changeset(attrs)
    |> Repo.update()
  end

  def delete_subtitle(%Subtitle{} = subtitle), do: Repo.delete(subtitle)

  def update_subtitle_outputs(%Embed{} = embed, %Subtitle{} = subtitle, attrs \\ %{})
      when is_map(attrs) do
    embed = Repo.preload(embed, [:space, asset: [:current_video]])

    with %Video{} = video <- embed.asset && embed.asset.current_video,
         :ok <- ensure_subtitle_for_video(subtitle, video),
         {:ok, region} <- require_binary(embed.space.region || "default", :region) do
      next_language =
        normalize_language(Map.get(attrs, :language) || Map.get(attrs, "language")) ||
          subtitle.language

      subtitle_attrs =
        attrs
        |> Map.new(fn
          {key, value} when is_atom(key) -> {key, value}
          {key, value} -> {String.to_existing_atom(key), value}
        end)
        |> Map.put(:language, next_language)

      with {:ok, subtitle_attrs} <-
             maybe_refresh_subtitle_path(embed, subtitle, subtitle_attrs, region),
           {:ok, updated_subtitle} <- update_subtitle(subtitle, subtitle_attrs),
           {:ok, _playlist} <- rebuild_hls_master_playlist(embed, region),
           {:ok, _manifest} <- ManifestPublisher.publish(embed) do
        {:ok, updated_subtitle}
      end
    else
      nil -> {:error, :missing_current_video}
      {:error, _reason} = error -> error
    end
  end

  def delete_subtitle_outputs(%Embed{} = embed, %Subtitle{} = subtitle) do
    embed = Repo.preload(embed, [:space, asset: [:current_video]])

    with %Video{} = video <- embed.asset && embed.asset.current_video,
         :ok <- ensure_subtitle_for_video(subtitle, video),
         {:ok, _region} <- require_binary(embed.space.region || "default", :region),
         {:ok, deleted_subtitle} <- delete_subtitle(subtitle),
         {:ok, _playlist} <-
           rebuild_hls_master_playlist(embed, embed.space.region || "default"),
         {:ok, _manifest} <- ManifestPublisher.publish(embed) do
      {:ok, deleted_subtitle}
    else
      nil -> {:error, :missing_current_video}
      {:error, _reason} = error -> error
    end
  end

  def create_audio_track(attrs \\ %{}) when is_map(attrs) do
    %AudioTrack{}
    |> AudioTrack.changeset(attrs)
    |> Repo.insert()
  end

  def update_audio_track(%AudioTrack{} = track, attrs \\ %{}) when is_map(attrs) do
    track
    |> AudioTrack.changeset(attrs)
    |> Repo.update()
  end

  def delete_audio_track(%AudioTrack{default: true}),
    do: {:error, :cannot_delete_default_audio_track}

  def delete_audio_track(%AudioTrack{} = track) do
    Repo.delete(track)
  end

  def ingest_uploaded_thumbnail(%Embed{} = embed, source_bucket, source_key, attrs \\ %{})
      when is_binary(source_bucket) and is_binary(source_key) and is_map(attrs) do
    embed = Repo.preload(embed, [:space, :settings, asset: [:current_video]])

    with %Video{} = video <- embed.asset && embed.asset.current_video,
         {:ok, region} <- require_binary(embed.space.region || "default", :region),
         {:ok, renditions} <-
           process_thumbnail_source(
             embed,
             source_bucket,
             source_key,
             region,
             upload_source_storage_profile(),
             attrs
           ),
         :ok <- replace_custom_thumbnail_renditions(video, renditions),
         {:ok, poster} <- required_thumbnail_rendition(renditions),
         {:ok, updated_embed} <-
           Embeds.publish_settings(embed, %{
             poster: :upload,
             external_poster: poster.public_url
           }),
         :ok <- purge_custom_thumbnail_cache(embed, renditions) do
      {:ok, updated_embed}
    else
      nil -> {:error, :missing_current_video}
      {:error, _reason} = error -> error
    end
  end

  def delete_custom_thumbnail(%Embed{} = embed) do
    embed = Repo.preload(embed, asset: [:current_video])

    case embed.asset && embed.asset.current_video do
      %Video{} = video ->
        delete_custom_thumbnail_renditions(video)
        :ok

      _ ->
        :ok
    end
  end

  def restore_default_thumbnail(%Embed{} = embed) do
    embed = Repo.preload(embed, [:space, asset: [:current_video]])

    with %Video{} = video <- embed.asset && embed.asset.current_video,
         {:ok, region} <- require_binary(embed.space.region || "default", :region),
         {:ok, source_key} <- generated_thumbnail_source_key(video.id),
         {:ok, restored} <- copy_generated_thumbnail(embed, source_key, region),
         :ok <- replace_generated_thumbnail_rendition(video, restored) do
      :ok
    else
      nil -> {:error, :missing_current_video}
      {:error, _reason} = error -> error
    end
  end

  def sync_public_thumbnail(%Embed{} = embed) do
    embed = Repo.preload(embed, [:space, :settings, asset: [:current_video]])

    with %Video{} = video <- embed.asset && embed.asset.current_video,
         {:ok, region} <- require_binary(embed.space.region || "default", :region) do
      sync_selected_public_thumbnail(embed, video, region)
    else
      nil -> {:error, :missing_current_video}
      {:error, _reason} = error -> error
    end
  end

  defp sync_selected_public_thumbnail(%Embed{} = embed, %Video{} = video, region) do
    if external_poster?(embed) or custom_thumbnail_renditions?(video) do
      sync_custom_public_thumbnail(embed, video, region)
    else
      sync_generated_public_thumbnail(embed, video, region)
    end
  end

  defp sync_generated_public_thumbnail(%Embed{} = embed, %Video{} = video, region) do
    with {:ok, source_key} <- generated_thumbnail_source_key(video.id),
         {:ok, _restored} <- copy_generated_thumbnail(embed, source_key, region) do
      :ok
    end
  end

  defp sync_custom_public_thumbnail(%Embed{} = embed, %Video{} = video, region) do
    renditions =
      from(r in "renditions",
        where: r.video_id == type(^video.id, MaveCore.Ecto.LegacyShortUUID),
        where: r.type == "custom_thumbnail" and r.progress >= 100,
        where: r.container in ^@custom_thumbnail_containers,
        select: %{key: r.rendition_key, container: r.container}
      )
      |> Repo.all()

    renditions
    |> Enum.reduce_while(:ok, fn rendition, :ok ->
      case sync_custom_public_thumbnail_rendition(embed, region, rendition) do
        :ok ->
          {:cont, :ok}

        {:error, reason}
        when rendition.container == @custom_thumbnail_required_container ->
          {:halt, {:error, reason}}

        {:error, _reason} ->
          {:cont, :ok}
      end
    end)
  end

  defp sync_custom_public_thumbnail_rendition(%Embed{} = embed, region, rendition) do
    root_key = thumbnail_source_key(embed.hash, rendition.container)

    source_key =
      custom_thumbnail_source_key(
        embed.hash,
        Embeds.current_video_version(embed),
        rendition.container
      )

    storage = storage_adapter()
    bucket = Storage.bucket_for_space(embed.space.hash, region)

    with {:ok, body} <- storage.get(bucket, source_key, region),
         {:ok, _body} <-
           storage.put_public(
             bucket,
             root_key,
             body,
             thumbnail_media_type(rendition.container),
             region
           ) do
      :ok
    else
      {:error, _reason} when rendition.key == root_key ->
        :ok

      {:error, reason} ->
        {:error, {:custom_thumbnail_sync_failed, root_key, reason}}
    end
  end

  def publish_selected_thumbnail(%Embed{} = embed) do
    embed = Repo.preload(embed, [:space, :settings, asset: [:current_video]])

    case selected_thumbnail_action(embed) do
      {:timecode, seconds} -> publish_timecode_thumbnail(embed, seconds)
      :restore_default -> restore_default_thumbnail_if_customized(embed)
      :ignore -> :ok
    end
  end

  def ingest_uploaded_audio_track(%Embed{} = embed, attrs, source_bucket, source_key)
      when is_map(attrs) and is_binary(source_bucket) and is_binary(source_key) do
    embed = Repo.preload(embed, [:space, asset: [:current_video]])

    with %Video{} = video <- embed.asset && embed.asset.current_video,
         {:ok, filename} <-
           require_binary(Map.get(attrs, :filename) || Map.get(attrs, "filename"), :filename),
         {:ok, region} <- require_binary(embed.space.region || "default", :region),
         {:ok, copied} <-
           copy_audio_source(
             embed,
             filename,
             source_bucket,
             source_key,
             attrs,
             region,
             upload_source_storage_profile()
           ),
         {:ok, track} <- upsert_uploaded_audio_track(video, attrs, copied),
         {:ok, _packaged} <- package_audio_track(embed, track, copied, region),
         {:ok, _playlist} <- rebuild_hls_master_playlist(embed, region),
         {:ok, _manifest} <- publish_audio_manifest(embed, region) do
      {:ok, track}
    else
      nil -> {:error, :missing_current_video}
      {:error, _reason} = error -> error
    end
  end

  def ingest_uploaded_subtitle(%Embed{} = embed, attrs, source_bucket, source_key)
      when is_map(attrs) and is_binary(source_bucket) and is_binary(source_key) do
    embed = Repo.preload(embed, [:space, asset: [:current_video]])

    with %Video{} = video <- embed.asset && embed.asset.current_video,
         {:ok, language} <-
           require_binary(
             normalize_language(Map.get(attrs, :language) || Map.get(attrs, "language")),
             :language
           ),
         {:ok, region} <- require_binary(embed.space.region || "default", :region),
         {:ok, copied} <-
           copy_subtitle_source(
             embed,
             language,
             source_bucket,
             source_key,
             region,
             upload_source_storage_profile()
           ),
         {:ok, subtitle} <- upsert_uploaded_subtitle(video, attrs, language, copied.key),
         {:ok, _playlist} <- rebuild_hls_master_playlist(embed, region),
         {:ok, _manifest} <- ManifestPublisher.publish(embed) do
      {:ok, subtitle}
    else
      nil -> {:error, :missing_current_video}
      {:error, _reason} = error -> error
    end
  end

  def refresh_audio_outputs(%Embed{} = embed) do
    embed = Repo.preload(embed, [:space, asset: [:current_video]])

    with %Video{} <- embed.asset && embed.asset.current_video,
         {:ok, region} <- require_binary(embed.space.region || "default", :region),
         {:ok, _playlist} <- rebuild_hls_master_playlist(embed, region),
         {:ok, _manifest} <- publish_audio_manifest(embed, region) do
      :ok
    else
      nil -> {:error, :missing_current_video}
      {:error, _reason} = error -> error
    end
  end

  def refresh_hls_master_playlist(%Embed{} = embed) do
    embed = Repo.preload(embed, [:space, asset: [:current_video]])

    with %Video{} <- embed.asset && embed.asset.current_video,
         {:ok, region} <- require_binary(embed.space.region || "default", :region),
         {:ok, _playlist} <- rebuild_hls_master_playlist(embed, region) do
      :ok
    else
      nil -> {:error, :missing_current_video}
      {:error, _reason} = error -> error
    end
  end

  defp maybe_refresh_subtitle_path(%Embed{} = embed, %Subtitle{} = subtitle, attrs, region) do
    next_language = Map.get(attrs, :language)

    cond do
      not is_binary(next_language) or next_language == "" ->
        {:ok, Map.delete(attrs, :language)}

      next_language == subtitle.language ->
        {:ok, attrs}

      true ->
        with {:ok, copied} <-
               copy_existing_subtitle_source(embed, subtitle, next_language, region) do
          {:ok, Map.put(attrs, :path, copied.key)}
        end
    end
  end

  defp copy_audio_source(
         %Embed{} = embed,
         filename,
         source_bucket,
         source_key,
         attrs,
         destination_region,
         source_region
       ) do
    storage = storage_adapter()
    destination_bucket = Storage.bucket_for_space(embed.space.hash, destination_region)
    destination_key = audio_source_key(embed.hash, Embeds.current_video_version(embed), filename)

    content_type =
      (Map.get(attrs, :content_type) || Map.get(attrs, "content_type") || media_type(filename))
      |> ContentType.media()

    with {:ok, body} <- storage.get(source_bucket, source_key, source_region),
         :ok <- Signature.validate_audio(body),
         {:ok, _body} <-
           storage.put_public(
             destination_bucket,
             destination_key,
             body,
             content_type,
             destination_region
           ) do
      {:ok,
       %{
         bucket: destination_bucket,
         key: destination_key,
         uri: "s3://#{destination_bucket}/#{destination_key}",
         public_url: SettingsSerializer.storage_object_url(destination_bucket, destination_key)
       }}
    end
  end

  defp process_thumbnail_source(
         embed,
         source_bucket,
         source_key,
         destination_region,
         source_region,
         attrs
       ) do
    storage = storage_adapter()

    prefix =
      if function_exported?(storage, :get_prefix, 4) do
        storage.get_prefix(
          source_bucket,
          source_key,
          source_region,
          Signature.probe_bytes_limit()
        )
      else
        storage.get(source_bucket, source_key, source_region)
      end

    with {:ok, bytes} <- prefix,
         :ok <- Signature.validate_image(bytes) do
      process_valid_thumbnail_source(
        embed,
        source_bucket,
        source_key,
        destination_region,
        source_region,
        attrs
      )
    end
  end

  defp process_valid_thumbnail_source(
         %Embed{} = embed,
         source_bucket,
         source_key,
         destination_region,
         source_region,
         attrs
       ) do
    destination_bucket = Storage.bucket_for_space(embed.space.hash, destination_region)

    run_input = %{
      "space_hash" => embed.space.hash,
      "embed_hash" => embed.hash,
      "version" => Embeds.current_video_version(embed),
      "region" => destination_region,
      "source_bucket" => source_bucket,
      "source_key" => source_key,
      "source_region" => source_region,
      "source_url" => "s3://#{source_bucket}/#{source_key}",
      "source_content_type" => thumbnail_source_media_type(source_key, attrs),
      "media_extract_frame_mode" => "ffmpeg",
      "media_extract_frame_strict" => true
    }

    @custom_thumbnail_containers
    |> Enum.reduce_while({:ok, []}, fn container, {:ok, renditions} ->
      case run_thumbnail_frame_step(run_input, container) do
        {:ok, rendition} ->
          {:cont, {:ok, [Map.put(rendition, :bucket, destination_bucket) | renditions]}}

        {:error, reason} when container == @custom_thumbnail_required_container ->
          {:halt, {:error, reason}}

        {:error, _reason} ->
          {:cont, {:ok, renditions}}
      end
    end)
    |> case do
      {:ok, renditions} ->
        publish_uploaded_thumbnail_aliases(embed, destination_region, Enum.reverse(renditions))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_thumbnail_frame_step(run_input, container) do
    step_definition = %{
      "id" => "custom_thumbnail_#{container}",
      "type" => "media.extract_frame",
      "params" => %{"role" => "custom_thumbnail", "codec" => container, "strict" => true}
    }

    context = %{run_input: run_input, dependency_outputs: %{}, dependency_artifacts: []}

    # Upload hooks run on API nodes without a media worker's memory budget.
    context =
      if EncodingBooster.enabled?(),
        do: Map.put(context, :encoding_booster_dispatch, :direct),
        else: context

    case MediaExtractFrameStep.run(step_definition, context) do
      {:ok, %{"key" => key, "file_size" => file_size}, _artifacts} ->
        {:ok,
         %{
           key: key,
           public_url:
             run_input
             |> Map.fetch!("region")
             |> then(fn region ->
               bucket = Storage.bucket_for_space(Map.fetch!(run_input, "space_hash"), region)
               SettingsSerializer.storage_object_url(bucket, key)
             end),
           file_size: file_size,
           container: container
         }}

      {:ok, %{"status" => status, "reason" => reason}, _artifacts} when status != "ok" ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp required_thumbnail_rendition(renditions) when is_list(renditions) do
    case Enum.find(renditions, &(&1.container == @custom_thumbnail_required_container)) do
      nil -> {:error, {:missing_custom_thumbnail, @custom_thumbnail_required_container}}
      rendition -> {:ok, rendition}
    end
  end

  defp publish_uploaded_thumbnail_aliases(%Embed{} = embed, region, renditions) do
    renditions
    |> Enum.reduce_while({:ok, []}, fn rendition, {:ok, published} ->
      case publish_uploaded_thumbnail_alias(embed, region, rendition) do
        {:ok, aliased} ->
          {:cont, {:ok, [aliased | published]}}

        {:error, reason}
        when rendition.container == @custom_thumbnail_required_container ->
          {:halt, {:error, reason}}

        {:error, _reason} ->
          {:cont, {:ok, published}}
      end
    end)
    |> case do
      {:ok, published} -> {:ok, Enum.reverse(published)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp publish_uploaded_thumbnail_alias(%Embed{} = embed, region, rendition) do
    storage = storage_adapter()
    bucket = Storage.bucket_for_space(embed.space.hash, region)
    root_key = thumbnail_source_key(embed.hash, rendition.container)
    content_type = thumbnail_media_type(rendition.container)

    with {:ok, body} <- storage.get(bucket, rendition.key, region),
         {:ok, _body} <- storage.put_public(bucket, root_key, body, content_type, region) do
      source_key = rendition.key

      {:ok,
       rendition
       |> Map.put(:source_key, source_key)
       |> Map.put(:key, root_key)
       |> Map.put(:public_url, SettingsSerializer.storage_object_url(bucket, root_key))
       |> Map.put(:purge_keys, Enum.uniq([source_key, root_key]))}
    else
      {:error, reason} ->
        {:error, {:thumbnail_alias_publish_failed, root_key, reason}}
    end
  end

  defp purge_custom_thumbnail_cache(%Embed{space: space}, renditions) when is_list(renditions) do
    paths = Enum.flat_map(renditions, &Map.get(&1, :purge_keys, [&1.key]))
    CdnCache.purge_best_effort(space.hash, space.region, paths)
  end

  defp copy_subtitle_source(
         %Embed{} = embed,
         language,
         source_bucket,
         source_key,
         destination_region,
         source_region
       ) do
    storage = storage_adapter()
    destination_bucket = Storage.bucket_for_space(embed.space.hash, destination_region)

    destination_key =
      subtitle_source_key(embed.hash, Embeds.current_video_version(embed), language)

    with {:ok, body} <- storage.get(source_bucket, source_key, source_region),
         {:ok, _body} <-
           storage.put_public(
             destination_bucket,
             destination_key,
             body,
             "text/vtt",
             destination_region
           ) do
      {:ok,
       %{
         bucket: destination_bucket,
         key: destination_key,
         uri: "s3://#{destination_bucket}/#{destination_key}",
         public_url: SettingsSerializer.storage_object_url(destination_bucket, destination_key)
       }}
    end
  end

  defp copy_existing_subtitle_source(%Embed{} = embed, %Subtitle{} = subtitle, language, region) do
    storage = storage_adapter()
    bucket = Storage.bucket_for_space(embed.space.hash, region)
    source_key = subtitle_storage_key(embed, subtitle)

    destination_key =
      subtitle_source_key(embed.hash, Embeds.current_video_version(embed), language)

    with {:ok, body} <- storage.get(bucket, source_key, region),
         {:ok, _body} <- storage.put_public(bucket, destination_key, body, "text/vtt", region) do
      {:ok,
       %{
         bucket: bucket,
         key: destination_key,
         uri: "s3://#{bucket}/#{destination_key}",
         public_url: SettingsSerializer.storage_object_url(bucket, destination_key)
       }}
    end
  end

  defp copy_generated_thumbnail(%Embed{} = embed, source_key, region) do
    storage = storage_adapter()
    bucket = Storage.bucket_for_space(embed.space.hash, region)
    destination_key = thumbnail_source_key(embed.hash, "jpg")

    with {:ok, body} <- storage.get(bucket, source_key, region),
         {:ok, _body} <- storage.put_public(bucket, destination_key, body, "image/jpeg", region) do
      {:ok,
       %{
         key: destination_key,
         file_size: byte_size(body),
         container: "jpg"
       }}
    end
  end

  defp publish_timecode_thumbnail(%Embed{} = embed, seconds) do
    with %Video{} = video <- embed.asset && embed.asset.current_video,
         {:ok, region} <- require_binary(embed.space.region || "default", :region),
         {:ok, renditions} <- render_timecode_thumbnail_renditions(embed, seconds, region),
         :ok <- replace_custom_thumbnail_renditions(video, renditions),
         :ok <- purge_custom_thumbnail_cache(embed, renditions) do
      :ok
    else
      nil -> {:error, :missing_current_video}
      {:error, _reason} = error -> error
    end
  end

  defp render_timecode_thumbnail_renditions(%Embed{} = embed, seconds, region) do
    @custom_thumbnail_containers
    |> Enum.reduce_while({:ok, []}, fn container, {:ok, renditions} ->
      case render_timecode_thumbnail_rendition(embed, seconds, region, container) do
        {:ok, rendition} ->
          {:cont, {:ok, [rendition | renditions]}}

        {:error, reason} when container == @custom_thumbnail_required_container ->
          {:halt, {:error, reason}}

        {:error, _reason} ->
          {:cont, {:ok, renditions}}
      end
    end)
    |> case do
      {:ok, renditions} -> {:ok, Enum.reverse(renditions)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp render_timecode_thumbnail_rendition(%Embed{} = embed, seconds, region, container) do
    with {:ok, _cache_key, body} <-
           thumbnail_image_processor().process(embed.space.hash, embed.hash, seconds,
             format: container
           ) do
      put_timecode_thumbnail_rendition(embed, body, region, container)
    end
  end

  defp put_timecode_thumbnail_rendition(%Embed{} = embed, body, region, container) do
    storage = storage_adapter()
    bucket = Storage.bucket_for_space(embed.space.hash, region)
    version = Embeds.current_video_version(embed)
    content_type = thumbnail_media_type(container)
    keys = thumbnail_publish_keys(embed.hash, version, container)

    with :ok <- put_thumbnail_keys(storage, bucket, keys, body, content_type, region) do
      root_key = thumbnail_source_key(embed.hash, container)

      {:ok,
       %{
         key: root_key,
         public_url: SettingsSerializer.storage_object_url(bucket, root_key),
         file_size: byte_size(body),
         container: container,
         purge_keys: keys
       }}
    end
  end

  defp put_thumbnail_keys(storage, bucket, keys, body, content_type, region) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      case storage.put_public(bucket, key, body, content_type, region) do
        {:ok, _body} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:thumbnail_upload_failed, key, reason}}}
      end
    end)
  end

  defp thumbnail_publish_keys(embed_hash, version, container) do
    root_key = thumbnail_source_key(embed_hash, container)
    source_key = custom_thumbnail_source_key(embed_hash, version, container)
    Enum.uniq([source_key, root_key])
  end

  defp custom_thumbnail_source_key(embed_hash, version, container) do
    if version > 0 do
      "#{embed_hash}/v#{version}/custom_thumbnail.#{container}"
    else
      "#{embed_hash}/custom_thumbnail.#{container}"
    end
  end

  defp restore_default_thumbnail_if_customized(%Embed{} = embed) do
    case embed.asset && embed.asset.current_video do
      %Video{} = video ->
        if custom_thumbnail_renditions?(video) do
          _ = restore_default_thumbnail(embed)
          delete_custom_thumbnail_renditions(video)
        end

        :ok

      _ ->
        :ok
    end
  end

  defp replace_custom_thumbnail_renditions(%Video{} = video, renditions)
       when is_list(renditions) do
    delete_custom_thumbnail_renditions(video)

    renditions
    |> Enum.map(& &1.key)
    |> Enum.each(&delete_conflicting_thumbnail_renditions(video, &1))

    rows =
      renditions
      |> Enum.filter(&(&1.container in @custom_thumbnail_containers))
      |> Enum.map(&custom_thumbnail_rendition_row(video, &1))

    if rows != [] do
      Repo.insert_all("renditions", rows)
    end

    :ok
  end

  defp custom_thumbnail_rendition_row(%Video{} = video, rendition) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %{
      id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
      video_id: MaveCore.LegacyShortUUID.dump!(video.id),
      rendition_key: rendition.key,
      type: "custom_thumbnail",
      codec: nil,
      container: rendition.container,
      size: nil,
      progress: 100.0,
      file_size: rendition.file_size,
      inserted_at: now,
      updated_at: now
    }
  end

  defp replace_generated_thumbnail_rendition(%Video{} = video, restored) do
    delete_conflicting_thumbnail_renditions(video, restored.key)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all("renditions", [
      %{
        id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
        video_id: MaveCore.LegacyShortUUID.dump!(video.id),
        rendition_key: restored.key,
        type: "thumbnail",
        codec: nil,
        container: restored.container,
        size: nil,
        progress: 100.0,
        file_size: restored.file_size,
        inserted_at: now,
        updated_at: now
      }
    ])

    :ok
  end

  defp delete_conflicting_thumbnail_renditions(%Video{} = video, rendition_key) do
    from(r in "renditions",
      where: r.video_id == type(^video.id, MaveCore.Ecto.LegacyShortUUID),
      where: r.rendition_key == ^rendition_key
    )
    |> Repo.delete_all()

    :ok
  end

  defp delete_custom_thumbnail_renditions(%Video{} = video) do
    from(r in "renditions",
      where: r.video_id == type(^video.id, MaveCore.Ecto.LegacyShortUUID),
      where: r.type == "custom_thumbnail"
    )
    |> Repo.delete_all()

    :ok
  end

  defp custom_thumbnail_renditions?(%Video{} = video) do
    from(r in "renditions",
      where: r.video_id == type(^video.id, MaveCore.Ecto.LegacyShortUUID),
      where: r.type == "custom_thumbnail",
      select: count(r.id)
    )
    |> Repo.one()
    |> Kernel.>(0)
  end

  defp generated_thumbnail_source_key(video_id) do
    query =
      from(r in "renditions",
        where: r.video_id == type(^video_id, MaveCore.Ecto.LegacyShortUUID),
        where: r.progress >= 100,
        where: (r.type == "thumbnail" or r.type == "poster") and r.container == "jpg",
        order_by: [
          asc: fragment("CASE WHEN ? = 'thumbnail' THEN 0 ELSE 1 END", r.type),
          desc: r.inserted_at
        ],
        select: r.rendition_key,
        limit: 1
      )

    case Repo.one(query) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :missing_generated_thumbnail}
    end
  end

  defp upsert_uploaded_audio_track(%Video{} = video, attrs, copied) do
    id = Map.get(attrs, :audio_track_id) || Map.get(attrs, "audio_track_id")

    track_attrs =
      %{
        video_id: video.id,
        filename: Path.basename(copied.key),
        file_size: Map.get(attrs, :file_size) || Map.get(attrs, "file_size"),
        codec: normalize_codec(Map.get(attrs, :codec) || Map.get(attrs, "codec"), copied.key),
        label: blank_to_nil(Map.get(attrs, :label) || Map.get(attrs, "label")),
        language: normalize_language(Map.get(attrs, :language) || Map.get(attrs, "language")),
        default: false
      }

    case audio_track_upload_target(id, video.id) do
      {:ok, %AudioTrack{} = track} -> update_audio_track(track, track_attrs)
      {:ok, nil} -> create_audio_track(track_attrs)
      {:error, _reason} = error -> error
    end
  end

  defp audio_track_upload_target(id, _video_id) when id in [nil, ""], do: {:ok, nil}

  defp audio_track_upload_target(id, video_id) when is_binary(id) do
    case get_audio_track_for_video(id, video_id) do
      %AudioTrack{} = track -> {:ok, track}
      nil -> {:error, :audio_track_not_found}
    end
  end

  defp audio_track_upload_target(_id, _video_id), do: {:error, :audio_track_not_found}

  defp upsert_uploaded_subtitle(%Video{} = video, attrs, language, path) do
    id = Map.get(attrs, :subtitle_id) || Map.get(attrs, "subtitle_id")

    subtitle_attrs = %{
      video_id: video.id,
      language: language,
      path: path
    }

    case get_subtitle_for_video(id, video.id) do
      %Subtitle{} = subtitle ->
        update_subtitle(subtitle, subtitle_attrs)

      nil ->
        existing =
          Subtitle
          |> where([subtitle], subtitle.video_id == ^video.id)
          |> where([subtitle], subtitle.language == ^language)
          |> Repo.one()

        case existing do
          %Subtitle{} = subtitle -> update_subtitle(subtitle, subtitle_attrs)
          nil -> create_subtitle(subtitle_attrs)
        end
    end
  end

  defp ensure_subtitle_for_video(%Subtitle{video_id: video_id}, %Video{id: video_id}), do: :ok
  defp ensure_subtitle_for_video(%Subtitle{}, %Video{}), do: {:error, :subtitle_not_found}

  defp package_audio_track(%Embed{} = embed, %AudioTrack{} = track, copied, region) do
    step_definition = %{
      "id" => "hls_audio_track_#{track.id}",
      "type" => "media.package_hls_audio",
      "params" => %{"source_step_id" => "source_audio"}
    }

    context = %{
      run_input: %{
        "space_hash" => embed.space.hash,
        "embed_hash" => embed.hash,
        "version" => Embeds.current_video_version(embed),
        "region" => region
      },
      dependency_outputs: %{
        "source_audio" => %{
          "step_type" => "media.transcode_audio",
          "status" => "ok",
          "bucket" => copied.bucket,
          "key" => copied.key,
          "uri" => copied.uri,
          "audio_track" => track_payload(track, copied),
          "audio_tracks" => [track_payload(track, copied)]
        }
      }
    }

    case MediaPackageHlsAudioStep.run(step_definition, context) do
      {:ok, output, _artifacts} -> {:ok, output}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rebuild_hls_master_playlist(%Embed{} = embed, region) do
    dependency_outputs =
      (hls_video_variant_outputs(embed, region) ++
         [
           {"hls_audio_tracks",
            %{
              "step_type" => "media.package_hls_audio",
              "status" => "ok",
              "audio_tracks" => manifest_audio_tracks(embed, region)
            }},
           {"hls_subtitles",
            %{
              "step_type" => "subtitle.collect",
              "status" => "ok",
              "subtitles" => hls_subtitles(embed)
            }}
         ])
      |> Map.new()

    step_definition = %{"id" => "hls_master", "type" => "media.build_hls_master"}

    context = %{
      run_input: %{
        "space_hash" => embed.space.hash,
        "embed_hash" => embed.hash,
        "version" => Embeds.current_video_version(embed),
        "region" => region,
        "duration" => embed.asset.current_video.duration
      },
      dependency_outputs: dependency_outputs
    }

    case MediaBuildHlsMasterStep.run(step_definition, context) do
      {:ok, output, _artifacts} -> {:ok, output}
      {:error, reason} -> {:error, reason}
    end
  end

  defp publish_audio_manifest(%Embed{} = embed, region) do
    ManifestPublisher.publish(embed, %{
      "audio_tracks" => manifest_audio_tracks(embed, region)
    })
  end

  defp hls_video_variant_outputs(%Embed{} = embed, region) do
    bucket = Storage.bucket_for_space(embed.space.hash, region)
    video_id = embed.asset.current_video.id
    version = Embeds.current_video_version(embed)

    from(r in "renditions",
      where: r.video_id == type(^video_id, MaveCore.Ecto.LegacyShortUUID),
      where: r.type == "video",
      where: r.container == "hls",
      where: r.size in ["sd", "hd", "fhd", "qhd", "uhd"],
      where: r.progress >= 100,
      select: %{
        codec: r.codec,
        size: r.size,
        rendition_key: r.rendition_key
      }
    )
    |> Repo.all()
    |> Enum.map(fn rendition ->
      playlist_path = relative_playlist_path(rendition.rendition_key, embed.hash, version)

      {"hls_#{rendition.codec}_#{rendition.size}",
       %{
         "step_type" => "media.package_hls_variant",
         "status" => "ok",
         "codec" => rendition.codec,
         "size" => rendition.size,
         "resolution" => hls_variant_resolution(embed.asset.current_video, rendition),
         "playlist_path" => playlist_path,
         "playlist_uri" => "s3://#{bucket}/#{rendition.rendition_key}"
       }}
    end)
  end

  # Audio-only originals have no dimensions. Their generated SD waveform does,
  # and must keep them when a track or subtitle edit rebuilds the master playlist.
  defp hls_variant_resolution(
         %Video{max_width: width, max_height: height},
         %{codec: "h264", size: "sd"}
       )
       when width in [nil, 0] and height in [nil, 0],
       do: "640x360"

  defp hls_variant_resolution(_video, _rendition), do: nil

  defp manifest_audio_tracks(%Embed{} = embed, region) do
    bucket = Storage.bucket_for_space(embed.space.hash, region)
    version = Embeds.current_video_version(embed)

    embed.asset.current_video.id
    |> audio_tracks_for_video()
    |> Enum.map(fn track ->
      source_key = audio_source_key(embed.hash, version, track.filename)
      hls_key = audio_hls_playlist_key(embed.hash, version, track.filename)

      %{
        "id" => track.id,
        "label" => track.label || "Audio track",
        "language" => track.language,
        "default" => track.default,
        "codec" => track.codec,
        "file_size" => track.file_size,
        "filename" => track.filename,
        "path" => SettingsSerializer.storage_object_url(bucket, source_key),
        "src" => SettingsSerializer.storage_object_url(bucket, source_key),
        "hls_playlist" => relative_playlist_path(hls_key, embed.hash, version),
        "hls_src" => SettingsSerializer.storage_object_url(bucket, hls_key),
        "hls_file_size" => nil,
        "hls_codec" => "aac",
        "hls_group_id" => "audio",
        "hls_bandwidth" => @audio_hls_bandwidth,
        "hls_channels" => @audio_hls_channels
      }
    end)
  end

  defp hls_subtitles(%Embed{} = embed) do
    version = Embeds.current_video_version(embed)

    embed.asset.current_video.id
    |> all_subtitles_for_video()
    |> Enum.flat_map(fn subtitle ->
      case hls_subtitle_path(embed, subtitle, version) do
        path when is_binary(path) and path != "" ->
          language = subtitle.language || "und"

          [
            %{
              "id" => subtitle.id,
              "label" => Languages.spoken_language(language) || String.upcase(language),
              "language" => language,
              "path" => path,
              "default" => false
            }
          ]

        _other ->
          []
      end
    end)
  end

  defp hls_subtitle_path(%Embed{} = embed, %Subtitle{path: path}, version)
       when is_binary(path) and path != "" do
    cond do
      String.starts_with?(path, "http://") or String.starts_with?(path, "https://") ->
        path

      String.starts_with?(path, "s3://") ->
        path

      true ->
        relative_playlist_path(path, embed.hash, version)
    end
  end

  defp hls_subtitle_path(_embed, _subtitle, _version), do: nil

  defp track_payload(%AudioTrack{} = track, copied) do
    %{
      "id" => track.id,
      "label" => track.label || "Audio track",
      "language" => track.language,
      "default" => track.default,
      "codec" => track.codec,
      "file_size" => track.file_size,
      "filename" => track.filename,
      "path" => copied.uri,
      "src" => copied.uri,
      "bucket" => copied.bucket,
      "key" => copied.key
    }
  end

  defp audio_source_key(embed_hash, version, filename) do
    if version > 0 do
      "#{embed_hash}/v#{version}/#{filename}"
    else
      "#{embed_hash}/#{filename}"
    end
  end

  defp audio_hls_playlist_key(embed_hash, version, filename) do
    variant_dir =
      filename
      |> Path.basename()
      |> Path.rootname()
      |> Kernel.<>("_hls")

    if version > 0 do
      "#{embed_hash}/v#{version}/#{variant_dir}/playlist.m3u8"
    else
      "#{embed_hash}/#{variant_dir}/playlist.m3u8"
    end
  end

  defp subtitle_source_key(embed_hash, version, language) do
    if version > 0 do
      "#{embed_hash}/v#{version}/subtitle_#{language}.vtt"
    else
      "#{embed_hash}/subtitle_#{language}.vtt"
    end
  end

  defp subtitle_storage_key(%Embed{} = embed, %Subtitle{path: path, language: language}) do
    if local_subtitle_path?(path) do
      path
    else
      subtitle_source_key(embed.hash, Embeds.current_video_version(embed), language || "en")
    end
  end

  defp thumbnail_source_key(embed_hash, extension), do: "#{embed_hash}/thumbnail.#{extension}"

  defp relative_playlist_path(rendition_key, embed_hash, version) when is_binary(rendition_key) do
    prefix =
      if version > 0 do
        "#{embed_hash}/v#{version}/"
      else
        "#{embed_hash}/"
      end

    String.trim_leading(rendition_key, prefix)
  end

  defp normalize_codec(nil, filename),
    do: filename |> Path.extname() |> String.trim_leading(".") |> String.downcase()

  defp normalize_codec(codec, _filename) when is_binary(codec), do: codec |> String.downcase()

  defp normalize_codec(codec, _filename) when is_atom(codec),
    do: codec |> Atom.to_string() |> String.downcase()

  defp normalize_language(nil), do: nil

  defp normalize_language(language) when is_binary(language) do
    normalized =
      language
      |> String.trim()
      |> String.downcase()
      |> String.replace("-", "_")

    cond do
      normalized == "" -> nil
      byte_size(normalized) >= 2 -> String.slice(normalized, 0, 2)
      true -> nil
    end
  end

  defp normalize_language(language) when is_atom(language),
    do: normalize_language(Atom.to_string(language))

  defp normalize_language(_), do: nil

  defp external_poster?(%Embed{settings: settings}) do
    external_poster = settings && settings.external_poster
    is_binary(external_poster) and external_poster != ""
  end

  defp selected_thumbnail_action(%Embed{settings: settings}) do
    settings = SettingsSerializer.settings_struct(settings)

    cond do
      settings.poster == :timecode and is_number(settings.poster_time_seconds) and
          settings.poster_time_seconds > 0 ->
        {:timecode, settings.poster_time_seconds}

      settings.poster == :timecode ->
        :restore_default

      external_poster?(%Embed{settings: settings}) ->
        :ignore

      true ->
        :restore_default
    end
  end

  defp local_subtitle_path?(path) when is_binary(path) do
    path != "" and
      not String.starts_with?(path, "http://") and
      not String.starts_with?(path, "https://")
  end

  defp local_subtitle_path?(_path), do: false

  defp thumbnail_extension(source_key) do
    source_key
    |> Path.extname()
    |> String.trim_leading(".")
    |> String.downcase()
    |> case do
      "jpeg" -> "jpg"
      "jpg" -> "jpg"
      "png" -> "png"
      "webp" -> "webp"
      "avif" -> "avif"
      _ -> "jpg"
    end
  end

  defp thumbnail_source_media_type(source_key, attrs) do
    Map.get(attrs, :content_type) ||
      Map.get(attrs, "content_type") ||
      Map.get(attrs, :filetype) ||
      Map.get(attrs, "filetype") ||
      thumbnail_media_type(thumbnail_extension(source_key))
  end

  defp thumbnail_media_type("jpg"), do: "image/jpeg"
  defp thumbnail_media_type("png"), do: "image/png"
  defp thumbnail_media_type("webp"), do: "image/webp"
  defp thumbnail_media_type("avif"), do: "image/avif"
  defp thumbnail_media_type(_), do: "image/jpeg"

  defp media_type(filename) do
    case Path.extname(filename) |> String.downcase() do
      ".mp3" -> "audio/mpeg"
      ".m4a" -> "audio/mp4"
      ".aac" -> "audio/aac"
      ".wav" -> "audio/wav"
      ".ogg" -> "audio/ogg"
      _ -> "application/octet-stream"
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp require_binary(value, _field) when is_binary(value) and value != "", do: {:ok, value}
  defp require_binary(_, field), do: {:error, {:missing_field, field}}

  defp storage_adapter do
    Application.get_env(:mave_core, :flow_storage_adapter, Storage)
  end

  defp thumbnail_image_processor do
    Application.get_env(:mave_core, :thumbnail_image_processor, ImageProcessor)
  end

  defp upload_source_storage_profile do
    :mave_core
    |> Application.get_env(:upload, [])
    |> Keyword.get(:source_region)
    |> case do
      value when is_binary(value) and value != "" -> value
      _ -> "default"
    end
  end
end
