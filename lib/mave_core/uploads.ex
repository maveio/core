defmodule MaveCore.Uploads do
  @moduledoc """
  Handles upload-complete hook events and starts matching flow runs.
  """
  import Ecto.Query
  require Logger

  alias MaveCore.Assets
  alias MaveCore.EmbedId
  alias MaveCore.Embeds
  alias MaveCore.Embeds.Embed
  alias MaveCore.EncodingBooster
  alias MaveCore.Flow
  alias MaveCore.Flow.Run
  alias MaveCore.Media.Storage
  alias MaveCore.Repo
  alias MaveCore.Spaces
  alias MaveCore.Spaces.Key
  alias MaveCore.Spaces.Space
  alias MaveCore.Uploads.Events
  alias MaveCore.UsageLimits

  @default_template "publish_default"
  @trusted_upload_metadata_prefix "mave_upload_"
  @trusted_upload_key_id "mave_upload_key_id"
  @trusted_upload_space_hash "mave_upload_space_hash"
  @trusted_upload_subject "mave_upload_subject"
  @trusted_upload_expires_at "mave_upload_expires_at"
  @upload_extension_by_content_type %{
    "application/octet-stream" => "bin",
    "audio/aac" => "aac",
    "audio/flac" => "flac",
    "audio/m4a" => "m4a",
    "audio/mp4" => "m4a",
    "audio/mpeg" => "mp3",
    "audio/ogg" => "ogg",
    "audio/opus" => "opus",
    "audio/wav" => "wav",
    "audio/x-wav" => "wav",
    "image/gif" => "gif",
    "image/jpeg" => "jpg",
    "image/png" => "png",
    "image/webp" => "webp",
    "text/srt" => "srt",
    "text/vtt" => "vtt",
    "video/mp2t" => "ts",
    "video/mp4" => "mp4",
    "video/mpeg" => "mpeg",
    "video/ogg" => "ogv",
    "video/quicktime" => "mov",
    "video/webm" => "webm",
    "video/x-flv" => "flv",
    "video/x-m4v" => "m4v",
    "video/x-matroska" => "mkv",
    "video/x-ms-wmv" => "wmv",
    "video/x-msvideo" => "avi"
  }
  @spec authorize_tusd_hook(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def authorize_tusd_hook(payload, opts \\ []) do
    with {:ok, upload} <- fetch_upload(payload),
         metadata <- normalize_metadata(Map.get(upload, "MetaData", %{})),
         {:ok, scope} <- fetch_signed_upload_scope(metadata, opts),
         :ok <- authorize_upload_size(scope, upload) do
      maybe_warm_encoding_boosters(scope, metadata)
      {:ok, scope}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec pre_create_hook_response(map(), map()) :: map()
  def pre_create_hook_response(
        payload,
        %{
          space: %Space{hash: space_hash},
          upload_authorization: upload_authorization
        }
      )
      when is_map(payload) do
    case fetch_upload(payload) do
      {:ok, upload} ->
        metadata = normalize_metadata(Map.get(upload, "MetaData", %{}))
        extension = upload_object_extension(metadata)

        %{
          "ChangeFileInfo" => %{
            "ID" => "#{space_hash}/#{random_upload_object_id()}.#{extension}",
            "MetaData" => sanitized_tusd_metadata(upload, upload_authorization)
          }
        }

      _other ->
        %{}
    end
  end

  @spec process_tusd_hook(map(), keyword()) :: {:ok, :ignored | map()} | {:error, term()}
  def process_tusd_hook(payload, opts \\ [])

  def process_tusd_hook(%{"Type" => "post-receive"} = payload, opts) do
    with {:ok, upload} <- fetch_upload(payload),
         metadata <- normalize_metadata(Map.get(upload, "MetaData", %{})),
         {:ok, scope} <- fetch_upload_scope(metadata, opts),
         :ok <- authorize_upload_size(scope, upload) do
      maybe_warm_encoding_boosters(scope, metadata)
      {:ok, %{action: "encoding_booster_warmup"}}
    end
  end

  def process_tusd_hook(%{"Type" => type}, _opts)
      when type not in [nil, "post-finish"] do
    {:ok, :ignored}
  end

  def process_tusd_hook(payload, opts) when is_map(payload) do
    with {:ok, upload} <- fetch_upload(payload),
         {:ok, bucket} <- fetch_storage_value(upload, "Bucket"),
         {:ok, key} <- fetch_storage_value(upload, "Key"),
         metadata <- normalize_metadata(Map.get(upload, "MetaData", %{})),
         {:ok, scope} <- fetch_upload_scope(metadata, opts),
         :ok <- authorize_upload_size(scope, upload) do
      maybe_warm_encoding_boosters(scope, metadata)
      upload_id = present(metadata, "upload_id") || Map.get(upload, "ID")

      result = dispatch_upload_action_idempotently(scope, bucket, key, metadata, upload)

      case result do
        {:ok, %{action: "custom_thumbnail"} = custom_result} ->
          {:ok, custom_result}

        {:ok, %{space_hash: _space_hash, embed_hash: _embed_hash} = result_map} ->
          {:ok, result_map}

        {:error, reason} = error ->
          broadcast_error(upload_id, reason)
          error
      end
    end
  end

  defp dispatch_upload_action_idempotently(scope, bucket, key, metadata, upload) do
    if standard_upload?(metadata) do
      dispatch_standard_upload_idempotently(scope, bucket, key, metadata, upload)
    else
      dispatch_upload_action(scope, bucket, key, metadata, upload)
    end
  end

  defp dispatch_standard_upload_idempotently(scope, bucket, key, metadata, upload) do
    Repo.transaction(fn ->
      lock_upload_object!(bucket, key)
      dispatch_locked_standard_upload(scope, bucket, key, metadata, upload)
    end)
    |> unwrap_upload_transaction()
  end

  defp dispatch_locked_standard_upload(scope, bucket, key, metadata, upload) do
    case existing_standard_upload_result(bucket, key) do
      nil -> dispatch_new_standard_upload(scope, bucket, key, metadata, upload)
      result -> result
    end
  end

  defp dispatch_new_standard_upload(scope, bucket, key, metadata, upload) do
    case dispatch_upload_action(scope, bucket, key, metadata, upload) do
      {:ok, result} -> result
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp unwrap_upload_transaction({:ok, result}), do: {:ok, result}
  defp unwrap_upload_transaction({:error, reason}), do: {:error, reason}

  defp lock_upload_object!(bucket, key) do
    {:ok, _result} =
      Repo.query("SELECT pg_advisory_xact_lock(hashtext($1))", [
        "tusd_post_finish:#{bucket}:#{key}"
      ])

    :ok
  end

  defp existing_standard_upload_result(bucket, key) do
    Run
    |> join(:inner, [run], template in assoc(run, :flow_template))
    |> where(
      [run, _template],
      fragment("?->>'upload_bucket' = ?", run.input, ^bucket) and
        fragment("?->>'upload_key' = ?", run.input, ^key)
    )
    |> order_by([run, _template], desc: run.inserted_at)
    |> limit(1)
    |> select([run, template], {run, template.slug})
    |> Repo.one()
    |> case do
      {%Run{} = run, template_slug} ->
        %{
          flow_run_id: run.id,
          template: template_slug,
          source_bucket: bucket,
          source_key: key,
          space_hash: Map.get(run.input, "space_hash"),
          embed_hash: Map.get(run.input, "embed_hash")
        }

      nil ->
        nil
    end
  end

  defp dispatch_upload_action(scope, bucket, key, metadata, upload) do
    cond do
      custom_thumbnail?(metadata) ->
        handle_custom_thumbnail(scope, bucket, key, metadata)

      custom_audio_track?(metadata) ->
        handle_custom_audio_track(scope, bucket, key, metadata, upload)

      custom_subtitle?(metadata) ->
        handle_custom_subtitle(scope, bucket, key, metadata)

      true ->
        handle_standard_upload(scope, bucket, key, metadata, upload)
    end
  end

  defp standard_upload?(metadata) do
    not custom_thumbnail?(metadata) and not custom_audio_track?(metadata) and
      not custom_subtitle?(metadata)
  end

  defp maybe_warm_encoding_boosters(%{space: %Space{hash: space_hash}}, metadata) do
    unless custom_thumbnail?(metadata) or custom_audio_track?(metadata) or
             custom_subtitle?(metadata) do
      encoding_booster_prewarmer().warmup_async(space_hash)
    end

    :ok
  end

  defp maybe_warm_encoding_boosters(_scope, _metadata), do: :ok

  defp encoding_booster_prewarmer do
    Application.get_env(:mave_core, :encoding_booster_prewarmer, EncodingBooster)
  end

  defp handle_standard_upload(scope, bucket, key, metadata, upload) do
    source_region = present(metadata, "source_region") || upload_config(:source_region)

    with {:ok, upload_embed} <- resolve_standard_upload_embed(scope, metadata),
         :ok <- maybe_publish_completed_upload(upload_embed, bucket, key, source_region),
         {:ok, source_url} <- resolve_source_url(metadata, bucket, key),
         %Space{hash: space_hash} <- upload_embed.space,
         embed_hash <- upload_embed.hash,
         {:ok, embed} <- begin_video_upload(space_hash, embed_hash, metadata, upload, source_url),
         {:ok, _deliveries_uploaded} <- enqueue_webhook(embed, :video_uploaded),
         {:ok, template_selector} <-
           fetch_template_selector(upload_space(embed, space_hash), metadata),
         {:ok, run_input} <-
           build_run_input(
             upload,
             metadata,
             bucket,
             key,
             source_url,
             space_hash,
             embed_hash,
             embed
           ),
         {:ok, flow_run} <- start_run(template_selector, run_input, metadata) do
      {:ok,
       %{
         flow_run_id: flow_run.id,
         template: template_selector,
         source_bucket: bucket,
         source_key: key,
         space_hash: space_hash,
         embed_hash: embed_hash
       }}
    end
  end

  defp publish_completed_upload(bucket, key, source_region) do
    if upload_config(:object_acl) do
      storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter, Storage)

      if function_exported?(storage_adapter, :set_object_visibility, 4) do
        storage_adapter.set_object_visibility(bucket, key, "public", source_region)
      else
        {:error, :upload_object_acl_not_supported}
      end
    else
      :ok
    end
  end

  defp maybe_publish_completed_upload(embed, bucket, key, region) do
    if MaveCore.Playback.protected?(embed),
      do: :ok,
      else: publish_completed_upload(bucket, key, region)
  end

  defp begin_video_upload(space_hash, embed_hash, metadata, upload, source_url) do
    Embeds.begin_video_upload(space_hash, embed_hash, %{
      "title" => present(metadata, "title"),
      "source_url" => source_url,
      "upload_size" => Map.get(upload, "Size"),
      "content_type" => present(metadata, "filetype") || present(metadata, "content_type")
    })
  end

  defp handle_custom_thumbnail(scope, bucket, key, metadata) do
    with {:ok, %Embed{space: %Space{hash: space_hash}, hash: embed_hash} = embed} <-
           upload_scope_existing_video(scope),
         {:ok, _embed} <-
           Assets.ingest_uploaded_thumbnail(
             embed,
             bucket,
             key,
             %{
               "content_type" =>
                 present(metadata, "filetype") || present(metadata, "content_type")
             }
           ) do
      {:ok,
       %{
         action: "custom_thumbnail",
         source_bucket: bucket,
         source_key: key,
         space_hash: space_hash,
         embed_hash: embed_hash
       }}
    end
  end

  defp handle_custom_audio_track(scope, bucket, key, metadata, upload) do
    with {:ok, %Embed{space: %Space{hash: space_hash}, hash: embed_hash} = embed} <-
           upload_scope_existing_video(scope),
         {:ok, track} <-
           Assets.ingest_uploaded_audio_track(
             embed,
             %{
               "audio_track_id" => present(metadata, "audio_track_id"),
               "filename" => audio_track_filename(key),
               "label" => present(metadata, "label"),
               "language" => present(metadata, "language"),
               "codec" => audio_track_codec(metadata, key),
               "content_type" =>
                 present(metadata, "filetype") || present(metadata, "content_type"),
               "file_size" => Map.get(upload, "Size")
             },
             bucket,
             key
           ) do
      {:ok,
       %{
         action: "custom_audio_track",
         source_bucket: bucket,
         source_key: key,
         space_hash: space_hash,
         embed_hash: embed_hash,
         audio_track_id: track.id
       }}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_custom_subtitle(scope, bucket, key, metadata) do
    with {:ok, %Embed{space: %Space{hash: space_hash}, hash: embed_hash} = embed} <-
           upload_scope_existing_video(scope),
         {:ok, subtitle} <-
           Assets.ingest_uploaded_subtitle(
             embed,
             %{
               "subtitle_id" => present(metadata, "subtitle_id"),
               "language" => present(metadata, "language")
             },
             bucket,
             key
           ) do
      {:ok,
       %{
         action: "custom_subtitle",
         source_bucket: bucket,
         source_key: key,
         space_hash: space_hash,
         embed_hash: embed_hash,
         subtitle_id: subtitle.id
       }}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_upload(%{"Event" => %{"Upload" => upload}}) when is_map(upload), do: {:ok, upload}
  defp fetch_upload(_), do: {:error, :invalid_payload}

  defp authorize_upload_size(%{space: %Space{} = space}, upload) do
    UsageLimits.can_upload_file?(space, authorized_upload_size(upload))
  end

  defp authorized_upload_size(%{"SizeIsDeferred" => deferred})
       when deferred in [true, "true", 1, "1"],
       do: nil

  defp authorized_upload_size(upload), do: parse_upload_size(Map.get(upload, "Size"))

  defp parse_upload_size(size) when is_integer(size) and size >= 0, do: size

  defp parse_upload_size(size) when is_binary(size) do
    case Integer.parse(String.trim(size)) do
      {value, ""} when value >= 0 -> value
      _ -> nil
    end
  end

  defp parse_upload_size(_size), do: nil

  defp fetch_storage_value(upload, key) do
    case get_in(upload, ["Storage", key]) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_storage_key, key}}
    end
  end

  defp normalize_metadata(metadata) when is_map(metadata) do
    Enum.reduce(metadata, %{}, fn {raw_key, raw_value}, acc ->
      key =
        raw_key
        |> to_string()
        |> String.trim()

      value = normalize_metadata_value(raw_value)
      canonical_key = canonical_metadata_key(key)

      acc
      |> Map.put(key, value)
      |> Map.put(canonical_key, value)
    end)
  end

  defp normalize_metadata(_), do: %{}

  defp normalize_metadata_value(value) when is_binary(value), do: String.trim(value)
  defp normalize_metadata_value(value), do: value

  defp canonical_metadata_key(key) do
    key
    |> String.replace("-", "_")
    |> Macro.underscore()
  end

  defp fetch_upload_scope(metadata, opts) do
    case present(metadata, "token") do
      token when is_binary(token) ->
        verify_upload_scope(token, opts)

      _ ->
        if present(metadata, @trusted_upload_key_id) do
          verify_trusted_upload_scope(metadata)
        else
          {:error, :missing_upload_jwt}
        end
    end
  end

  # Only later hooks may trust references written by our successful pre-create.
  defp fetch_signed_upload_scope(metadata, opts) do
    case present(metadata, "token") do
      token when is_binary(token) -> verify_upload_scope(token, opts)
      _ -> {:error, :missing_upload_jwt}
    end
  end

  defp verify_upload_scope(token, _opts) do
    case Spaces.validate_api_jwt(token) do
      {:ok,
       %{
         claims: claims,
         key: %Key{access_level: :read_write} = key,
         space: %Space{} = space
       }} ->
        with {:ok, scope} <- api_jwt_upload_scope(space, claims) do
          {:ok,
           Map.put(scope, :upload_authorization, %{
             key_id: key.id,
             space_hash: space.hash,
             subject: claims["sub"],
             expires_at: claims["exp"]
           })}
        end

      _error ->
        {:error, :invalid_upload_jwt}
    end
  end

  defp verify_trusted_upload_scope(metadata) do
    with key_id when is_binary(key_id) <- present(metadata, @trusted_upload_key_id),
         space_hash when is_binary(space_hash) <- present(metadata, @trusted_upload_space_hash),
         subject when is_binary(subject) <- present(metadata, @trusted_upload_subject),
         expires_at when is_integer(expires_at) <-
           parse_integer(present(metadata, @trusted_upload_expires_at), nil),
         true <- expires_at > System.system_time(:second),
         %Key{access_level: :read_write, space: %Space{} = space} <-
           Spaces.get_key_for_space_hash(space_hash, key_id),
         {:ok, scope} <- api_jwt_upload_scope(space, %{"sub" => subject}) do
      {:ok,
       Map.put(scope, :upload_authorization, %{
         key_id: key_id,
         space_hash: space_hash,
         subject: subject,
         expires_at: expires_at
       })}
    else
      _error -> {:error, :invalid_upload_jwt}
    end
  end

  defp sanitized_tusd_metadata(upload, upload_authorization) do
    upload
    |> Map.get("MetaData", %{})
    |> then(fn
      %{} = metadata -> metadata
      _other -> %{}
    end)
    |> Enum.reduce(%{}, fn {raw_key, raw_value}, acc ->
      key = raw_key |> to_string() |> String.trim()
      canonical_key = canonical_metadata_key(key)

      if canonical_key == "token" or
           String.starts_with?(canonical_key, @trusted_upload_metadata_prefix) do
        acc
      else
        Map.put(acc, key, normalize_metadata_value(raw_value))
      end
    end)
    |> Map.merge(%{
      @trusted_upload_key_id => to_string(upload_authorization.key_id),
      @trusted_upload_space_hash => to_string(upload_authorization.space_hash),
      @trusted_upload_subject => to_string(upload_authorization.subject),
      @trusted_upload_expires_at => to_string(upload_authorization.expires_at)
    })
  end

  defp persisted_upload_metadata(metadata) do
    Map.reject(metadata, fn {raw_key, _value} ->
      canonical_key = raw_key |> to_string() |> canonical_metadata_key()

      canonical_key == "token" or
        String.starts_with?(canonical_key, @trusted_upload_metadata_prefix)
    end)
  end

  defp api_jwt_upload_scope(%Space{} = space, %{"sub" => sub}) when is_binary(sub) do
    case EmbedId.split(sub) do
      {:ok, %{space_hash: space_hash, embed_hash: embed_hash}} ->
        api_jwt_embed_scope(space, space_hash, embed_hash)

      :error ->
        if sub_identifies_space?(space, sub) do
          {:ok, %{action: :create_in_space, space: space}}
        else
          {:error, :invalid_upload_jwt}
        end
    end
  end

  defp api_jwt_upload_scope(_space, _claims), do: {:error, :invalid_upload_jwt}

  defp api_jwt_embed_scope(%Space{id: space_id}, space_hash, embed_hash) do
    case Embeds.get_embed_by_hashes(space_hash, embed_hash) do
      %Embed{space_id: ^space_id, type: :video} = embed ->
        {:ok, %{action: :replace_video, space: embed.space, embed: embed}}

      %Embed{space_id: ^space_id, type: :collection} = embed ->
        {:ok, %{action: :create_in_collection, space: embed.space, collection_embed: embed}}

      _ ->
        {:error, :invalid_upload_jwt}
    end
  end

  defp sub_identifies_space?(%Space{} = space, sub) do
    sub in [space.id, space.hash]
  end

  defp resolve_standard_upload_embed(
         %{action: :replace_video, embed: %Embed{} = embed},
         _metadata
       ),
       do: {:ok, embed}

  defp resolve_standard_upload_embed(
         %{action: :create_in_space, space: %Space{} = space},
         metadata
       ) do
    Embeds.create_video_embed(space, upload_embed_attrs(metadata))
  end

  defp resolve_standard_upload_embed(
         %{
           action: :create_in_collection,
           space: %Space{} = space,
           collection_embed: %Embed{} = folder
         },
         metadata
       ) do
    Embeds.create_video_embed(
      space,
      Map.put(upload_embed_attrs(metadata), "parent_folder_id", folder.id)
    )
  end

  defp upload_embed_attrs(metadata) do
    %{}
    |> maybe_put_upload_title(metadata)
  end

  defp maybe_put_upload_title(attrs, metadata) do
    case present(metadata, "title") do
      title when is_binary(title) -> Map.put(attrs, "name", title)
      _ -> attrs
    end
  end

  defp upload_scope_existing_video(%{
         action: :replace_video,
         embed: %Embed{type: :video} = embed
       }),
       do: {:ok, embed}

  defp upload_scope_existing_video(_scope), do: {:error, :invalid_upload_scope}

  defp resolve_source_url(metadata, bucket, key) do
    case present(metadata, "source_url") do
      value when is_binary(value) ->
        {:ok, value}

      _ ->
        {:ok, upload_storage_url(bucket, key)}
    end
  end

  defp build_storage_url(base_url, bucket, key) do
    trimmed_base = String.trim_trailing(base_url, "/")
    trimmed_key = String.trim_leading(key, "/")
    "#{trimmed_base}/#{bucket}/#{trimmed_key}"
  end

  defp s3_endpoint do
    :mave_core
    |> Application.get_env(:s3, [])
    |> Keyword.get(:endpoint)
  end

  defp fetch_template_selector(space_hash, metadata) do
    selector =
      present(metadata, "template") ||
        present(metadata, "template_slug") ||
        default_flow_template(space_hash) ||
        upload_config(:default_template) ||
        @default_template

    if is_binary(selector) and selector != "" do
      {:ok, selector}
    else
      {:error, :missing_template_selector}
    end
  end

  defp default_flow_template(space_hash) when is_binary(space_hash) do
    case Spaces.get_space_by_hash(space_hash) do
      %{default_flow_template: template} when is_binary(template) and template != "" -> template
      _ -> nil
    end
  end

  defp default_flow_template(%Space{default_flow_template: template})
       when is_binary(template) and template != "",
       do: template

  defp default_flow_template(%Space{}), do: nil

  defp build_run_input(upload, metadata, bucket, key, source_url, space_hash, embed_hash, embed) do
    space = upload_space(embed, space_hash)
    {ffmpeg_url, public_url} = public_upload_urls(embed, bucket, key)

    region =
      case space do
        %Space{region: value} when is_binary(value) and value != "" -> value
        _ -> Spaces.get_storage_profile(space_hash)
      end

    run_input =
      %{
        "space_hash" => space_hash,
        "embed_hash" => embed_hash,
        "region" => region,
        "version" =>
          parse_integer(present(metadata, "version"), Embeds.current_video_version(embed)),
        "source_url" => source_url,
        "upload_ffmpeg_input_url" => ffmpeg_url,
        "upload_public_url" => public_url,
        "source_bucket" => bucket,
        "source_key" => key,
        "source_region" => present(metadata, "source_region") || upload_config(:source_region),
        "source_content_type" =>
          present(metadata, "filetype") || present(metadata, "content_type"),
        "upload_id" => present(metadata, "upload_id") || Map.get(upload, "ID"),
        "upload_size" => Map.get(upload, "Size"),
        "upload_key" => key,
        "upload_bucket" => bucket,
        "upload_metadata" => persisted_upload_metadata(metadata),
        "callback_url" =>
          present(metadata, "callback_url") ||
            present(metadata, "webhook_url") ||
            present(metadata, "notify_webhook_url")
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    {:ok, run_input}
  end

  defp upload_storage_url(bucket, key) do
    base_url =
      upload_config(:source_base_url) ||
        s3_endpoint() ||
        "http://localhost:9000"

    build_storage_url(base_url, bucket, key)
  end

  defp public_upload_urls(embed, bucket, key) do
    if MaveCore.Playback.protected?(embed),
      do: {nil, nil},
      else: {upload_ffmpeg_input_url(bucket, key), Storage.upload_public_object_url(key)}
  end

  defp upload_ffmpeg_input_url(bucket, key) do
    case Storage.ffmpeg_input_url(bucket, key, upload_config(:source_region)) do
      {:ok, url} -> url
      {:error, _reason} -> upload_storage_url(bucket, key)
    end
  end

  defp start_run(template_selector, run_input, metadata) do
    opts = [enqueue: parse_enqueue(present(metadata, "enqueue"))]

    case Flow.start_run(template_selector, run_input, opts) do
      {:ok, flow_run} ->
        {:ok, flow_run}

      {:error, :template_not_found} ->
        maybe_install_and_start(template_selector, run_input, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp upload_space(%{space: %Space{} = space}, _space_hash), do: space

  defp upload_space(_embed, space_hash) when is_binary(space_hash),
    do: Spaces.get_space_by_hash(space_hash)

  defp maybe_install_and_start(template_selector, run_input, opts) do
    with {:ok, _} <- Flow.install_preset(template_selector),
         {:ok, flow_run} <- Flow.start_run(template_selector, run_input, opts) do
      {:ok, flow_run}
    else
      {:error, :preset_not_found} ->
        {:error, :template_not_found}

      {:error, reason} ->
        Logger.error(
          "Failed to auto-install flow preset #{template_selector}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp parse_enqueue(value) when value in [false, "false", "0", 0], do: false
  defp parse_enqueue(_), do: true

  defp custom_thumbnail?(metadata) do
    present(metadata, "custom_thumbnail") in ["true", "1", "yes"]
  end

  defp custom_audio_track?(metadata) do
    present(metadata, "custom_audio_track") in ["true", "1", "yes"]
  end

  defp custom_subtitle?(metadata) do
    present(metadata, "custom_subtitle") in ["true", "1", "yes"]
  end

  defp audio_track_filename(key) when is_binary(key) do
    key
    |> Path.basename()
  end

  defp audio_track_filename(_), do: "audio.mp3"

  defp audio_track_codec(metadata, key) do
    case present(metadata, "filetype") || present(metadata, "content_type") do
      "audio/mpeg" -> "mp3"
      "audio/mp4" -> "aac"
      "audio/wav" -> "wav"
      "audio/ogg" -> "ogg"
      _ -> key |> Path.extname() |> String.trim_leading(".") |> String.downcase()
    end
  end

  defp parse_integer(value, _fallback) when is_integer(value), do: value

  defp parse_integer(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> fallback
    end
  end

  defp parse_integer(_, fallback), do: fallback

  defp present(metadata, key) when is_map(metadata) do
    case Map.get(metadata, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp upload_config(key) do
    :mave_core
    |> Application.get_env(:upload, [])
    |> Keyword.get(key)
  end

  defp upload_object_extension(metadata) do
    content_type = present(metadata, "filetype") || present(metadata, "content_type")
    Map.get(@upload_extension_by_content_type, content_type, "bin")
  end

  defp random_upload_object_id do
    24
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp broadcast_error(upload_id, _reason) when not is_binary(upload_id), do: :ok

  defp broadcast_error(upload_id, reason) do
    Events.broadcast(
      :error,
      %{message: "Upload processing failed: #{inspect(reason)}"},
      upload_id
    )
  end

  defp enqueue_webhook(%{space: %Space{} = space} = embed, event_type) do
    case Spaces.enqueue_webhook_event_for_embed(space, embed, event_type, %{
           enqueue: true
         }) do
      {:ok, deliveries} -> {:ok, deliveries}
      {:error, :not_found} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end
end
