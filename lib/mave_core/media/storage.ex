defmodule MaveCore.Media.Storage do
  @moduledoc """
  Handles interaction with S3-compatible storage.
  Supports multiple storage profiles.
  """
  require Logger

  alias MaveCore.Media.CdnCache
  alias MaveCore.SafeFile
  alias MaveCore.SharedStorageSpace
  alias MaveCore.Spaces.Space
  alias MaveCore.StorageProfiles

  @aws_policy_version "2012-10-17"
  @scaleway_policy_version "2023-04-17"
  @ffmpeg_referer_context "mave-ffmpeg-storage-referer-v1"
  @ffmpeg_referer_origin "https://ffmpeg.storage.mave.invalid"
  @ffmpeg_policy_sid "AllowMaveFfmpegRead"
  @public_read_policy_sid "AllowPublicReadGetObject"
  @cross_profile_single_put_max_bytes 8 * 1024 * 1024
  @multipart_copy_part_size 8 * 1024 * 1024
  @server_side_copy_max_bytes 5 * 1024 * 1024 * 1024
  @server_side_multipart_copy_part_size 128 * 1024 * 1024
  @multipart_part_max_attempts 3
  @object_put_max_retries 3
  @object_put_retry_base_delay_ms 100
  @object_put_retry_max_delay_ms 1_000
  @object_put_transient_statuses [408, 409, 429, 500, 502, 503, 504]
  @object_head_max_retries 3
  @object_head_retry_base_delay_ms 100
  @object_head_retry_max_delay_ms 1_000
  @object_head_transient_statuses [403, 408, 409, 429, 500, 502, 503, 504]
  @object_request_transient_transport_reasons [:timeout, :econnrefused, :closed]
  @object_request_transient_http2_reasons [:unprocessed, :pool_not_available]
  @copy_prefix_key_max_attempts 3
  @copy_prefix_key_retry_delay_ms 250
  @s3_min_multipart_part_size 5 * 1024 * 1024
  # Scaleway Object Storage accepts at most 1,000 parts. Keeping the generic
  # storage path within that limit also remains compatible with S3 providers
  # that allow more parts.
  @multipart_max_parts 1_000
  @multipart_control_request_timeout_ms 60_000
  @multipart_part_request_timeout_ms 5 * 60 * 1000
  @direct_upload_part_size 16 * 1024 * 1024
  @direct_upload_url_expiry_seconds 2 * 60 * 60
  @download_to_file_request_timeout_ms 30 * 60 * 1000
  @object_prefix_max_bytes 1_048_576
  @copy_tmp_root "mave-storage-copy"
  @default_object_acl_profiles ["eu", "eu_3"]
  @space_hash_pattern ~r/^[a-z0-9]{5}$/

  @doc """
  Returns the bucket name for a given space hash.
  Optionally uses a storage-profile-specific bucket prefix.
  """
  def bucket_for_space(space_hash, storage_profile \\ nil) do
    config = config_for_profile(storage_profile)
    prefix = config_value(config, :bucket_prefix) || "space-"
    "#{prefix}#{space_hash}"
  end

  @doc """
  Returns the public CDN bucket alias for a space.

  A storage profile may use a physical bucket prefix that differs from the
  stable public hostname/path prefix used by embeds during a storage move.
  """
  def public_bucket_for_space(space_hash, storage_profile \\ nil) do
    config = config_for_profile(storage_profile)

    prefix =
      config_value(config, :public_bucket_prefix) ||
        config_value(config, :bucket_prefix) ||
        "space-"

    "#{prefix}#{space_hash}"
  end

  @doc """
  Converts a physical bucket name to its configured public CDN alias.

  Bucket names that do not match a configured aliased prefix are returned
  unchanged.
  """
  def public_bucket_name(bucket) when is_binary(bucket) do
    :mave_core
    |> Application.get_env(:storage_providers, %{})
    |> Map.values()
    |> Enum.flat_map(&public_bucket_alias/1)
    |> Enum.sort_by(fn {bucket_prefix, _public_prefix} -> -byte_size(bucket_prefix) end)
    |> Enum.find_value(bucket, fn {bucket_prefix, public_prefix} ->
      if space_bucket_with_prefix?(bucket, bucket_prefix) do
        String.replace_prefix(bucket, bucket_prefix, public_prefix)
      end
    end)
  end

  def public_bucket_name(bucket), do: bucket

  @doc """
  Checks if an object exists in the bucket.
  """
  def exists?(bucket, path, storage_profile \\ nil) do
    case head(bucket, path, storage_profile) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  end

  @doc """
  Ensures a bucket exists. Creates it when missing.
  """
  def ensure_bucket(bucket, storage_profile \\ nil) do
    case head_bucket(bucket, storage_profile) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: 404}} ->
        create_bucket(bucket, storage_profile)

      {:ok, %{status: 409}} ->
        # Bucket exists / already owned in many S3-compatible providers.
        :ok

      {:ok, %{status: status}} ->
        {:error, {:bucket_check_failed, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetches an object's body.
  """
  def get(bucket, path, storage_profile \\ nil) do
    build_req(bucket, storage_profile)
    |> Req.get(url: "/#{path}")
    |> handle_response()
  end

  @doc "Fetches at most `max_bytes` from the beginning of an object."
  def get_prefix(bucket, path, storage_profile, max_bytes)
      when is_binary(bucket) and is_binary(path) do
    if is_integer(max_bytes) and max_bytes > 0 and max_bytes <= @object_prefix_max_bytes do
      do_get_prefix(bucket, path, storage_profile, max_bytes)
    else
      {:error, :invalid_object_prefix_request}
    end
  end

  def get_prefix(_bucket, _path, _storage_profile, _max_bytes),
    do: {:error, :invalid_object_prefix_request}

  defp do_get_prefix(bucket, path, storage_profile, max_bytes) do
    case object_info(bucket, path, storage_profile) do
      {:ok, %{size_bytes: size_bytes}} when is_integer(size_bytes) and size_bytes > 0 ->
        get_object_range(
          bucket,
          path,
          storage_profile,
          0,
          min(size_bytes, max_bytes) - 1
        )

      {:ok, %{size_bytes: 0}} ->
        {:error, :empty_object}

      {:ok, _info} ->
        {:error, :object_size_unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Downloads an object directly into a file to avoid loading the whole body into memory.
  """
  def download_to_file(bucket, path, destination_path, storage_profile \\ nil, opts \\ []) do
    timeout_ms =
      opts
      |> Keyword.get(:timeout, @download_to_file_request_timeout_ms)
      |> positive_integer(@download_to_file_request_timeout_ms)

    result =
      build_req(bucket, storage_profile)
      |> request_with_deadline(
        fn req ->
          Req.get(req, url: "/#{path}", into: SafeFile.stream_write!(destination_path), raw: true)
        end,
        timeout_ms
      )

    case result do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: 404}} ->
        _ = SafeFile.rm(destination_path)
        {:error, :not_found}

      {:ok, resp} ->
        _ = SafeFile.rm(destination_path)
        {:error, "S3 error: #{resp.status}"}

      {:error, reason} ->
        _ = SafeFile.rm(destination_path)
        {:error, reason}
    end
  end

  @doc """
  Returns an unsigned object-storage URL that FFmpeg can read directly.

  Upload-bucket reads use the configured source origin instead of the
  browser-facing Edge Services origin. Protected non-upload storage uses the
  server-owned Referer header returned by `ffmpeg_input_referer/0`.
  """
  def ffmpeg_input_url(bucket, path, storage_profile \\ nil)

  def ffmpeg_input_url(bucket, path, storage_profile)
      when is_binary(bucket) and is_binary(path) do
    trimmed_bucket = String.trim(bucket)
    trimmed_path = String.trim_leading(path, "/")

    if trimmed_bucket == "" or trimmed_path == "" do
      {:error, :invalid_storage_url}
    else
      build_ffmpeg_input_url(trimmed_bucket, trimmed_path, storage_profile)
    end
  end

  def ffmpeg_input_url(_bucket, _path, _storage_profile), do: {:error, :invalid_storage_url}

  @doc """
  Returns the unguessable Referer value used to authorize direct FFmpeg reads.

  The value is derived from the internal secret so deployments do not need to
  provision another secret, while the internal secret itself is never sent to
  object storage.
  """
  def ffmpeg_input_referer do
    case Application.get_env(:mave_core, :internal_secret) do
      secret when is_binary(secret) and secret != "" ->
        token =
          :crypto.mac(:hmac, :sha256, secret, @ffmpeg_referer_context)
          |> Base.url_encode64(padding: false)

        "#{@ffmpeg_referer_origin}/#{token}"

      _other ->
        nil
    end
  end

  @doc """
  Returns whether a URL belongs to one of the configured object-storage origins.

  Callers use this check before attaching the private FFmpeg Referer so it is
  never disclosed to arbitrary remote input URLs.
  """
  def ffmpeg_storage_url?(url) when is_binary(url) do
    with %URI{scheme: scheme, host: host} = uri when scheme in ["http", "https"] <-
           URI.parse(url),
         true <- is_binary(host) and host != "" do
      not upload_storage_uri?(uri) and
        Enum.any?(ffmpeg_storage_base_urls(), &url_belongs_to_base?(uri, &1))
    else
      _other -> false
    end
  end

  def ffmpeg_storage_url?(_url), do: false

  @doc "Returns whether a configured storage URL carries an S3 request signature."
  def presigned_storage_url?(url) when is_binary(url) do
    with true <- ffmpeg_storage_url?(url),
         %URI{query: query} when is_binary(query) <- URI.parse(url) do
      query
      |> URI.query_decoder()
      |> Enum.any?(fn {key, _value} -> String.downcase(key) == "x-amz-signature" end)
    else
      _other -> false
    end
  rescue
    _error -> false
  end

  def presigned_storage_url?(_url), do: false

  @doc "Returns whether FFmpeg must attach the private storage Referer to this URL."
  def ffmpeg_referer_required?(url) do
    ffmpeg_storage_url?(url) and not presigned_storage_url?(url)
  end

  @doc """
  Returns whether a URL is an object in the configured upload bucket.
  """
  def upload_storage_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        upload_storage_uri?(uri)

      _other ->
        false
    end
  end

  def upload_storage_url?(_url), do: false

  @doc """
  Builds the browser-facing URL for an object in the configured upload bucket.

  The public base intentionally omits the physical bucket name because it may
  be an Edge Services hostname dedicated to that bucket. When no public base is
  configured, this falls back to the direct object-storage URL.
  """
  def upload_public_object_url(key) when is_binary(key) do
    upload_config = Application.get_env(:mave_core, :upload, [])

    case String.trim_leading(key, "/") do
      "" -> nil
      trimmed_key -> configured_upload_public_object_url(upload_config, trimmed_key)
    end
  end

  def upload_public_object_url(_key), do: nil

  @doc """
  Returns whether a URL belongs to the configured browser-facing upload origin.
  """
  def upload_public_url?(url) when is_binary(url) do
    upload_config = Application.get_env(:mave_core, :upload, [])

    case config_value(upload_config, :public_base_url) do
      base_url when is_binary(base_url) and base_url != "" ->
        case URI.parse(url) do
          %URI{scheme: scheme, host: host} = uri
          when scheme in ["http", "https"] and is_binary(host) and host != "" ->
            url_belongs_to_base?(uri, base_url)

          _other ->
            false
        end

      _other ->
        upload_storage_url?(url)
    end
  end

  def upload_public_url?(_url), do: false

  defp configured_upload_public_object_url(upload_config, key) do
    case config_value(upload_config, :public_base_url) do
      base_url when is_binary(base_url) and base_url != "" ->
        String.trim_trailing(base_url, "/") <> "/" <> key

      _other ->
        configured_upload_storage_object_url(upload_config, key)
    end
  end

  defp configured_upload_storage_object_url(upload_config, key) do
    source_base_url = config_value(upload_config, :source_base_url)
    bucket = config_value(upload_config, :bucket)

    if is_binary(source_base_url) and source_base_url != "" and is_binary(bucket) and
         bucket != "" do
      String.trim_trailing(source_base_url, "/") <>
        "/" <> URI.encode(bucket) <> "/" <> key
    end
  end

  @doc """
  Streams a local file into object storage.
  """
  def put_file(
        bucket,
        path,
        source_path,
        content_type \\ "application/octet-stream",
        storage_profile \\ nil,
        opts \\ []
      ) do
    {:ok, %{size: size}} = SafeFile.stat_regular(source_path)

    headers =
      [
        {"content-type", content_type},
        {"content-length", Integer.to_string(size)}
      ]
      |> maybe_add_public_read_header(storage_profile, opts)

    put_object_with_retry(
      bucket,
      path,
      storage_profile,
      headers,
      fn -> SafeFile.stream_read!(source_path) end
    )
    |> handle_response()
  end

  @doc """
  Puts an object.
  """
  def put(
        bucket,
        path,
        body,
        content_type \\ "application/octet-stream",
        storage_profile \\ nil,
        opts \\ []
      ) do
    headers =
      [{"content-type", content_type}]
      |> maybe_add_content_length_header(opts)
      |> maybe_add_public_read_header(storage_profile, opts)

    put_object_with_retry(bucket, path, storage_profile, headers, fn -> body end)
    |> handle_response()
  end

  @doc """
  Puts an object and applies old-mave public-read semantics for public media outputs.
  """
  def put_public(
        bucket,
        path,
        body,
        content_type \\ "application/octet-stream",
        storage_profile \\ nil,
        opts \\ []
      ) do
    put(bucket, path, body, content_type, storage_profile, Keyword.put(opts, :public, true))
  end

  @doc """
  Streams a local file into object storage using public-read semantics for media outputs.
  """
  def put_file_public(
        bucket,
        path,
        source_path,
        content_type \\ "application/octet-stream",
        storage_profile \\ nil
      ) do
    put_file(bucket, path, source_path, content_type, storage_profile, public: true)
  end

  @doc """
  Starts a multipart upload and returns short-lived, operation-scoped URLs that
  let an encoding worker write the object without receiving storage credentials.

  Media bytes travel directly from the encoding worker to object storage. The
  returned session must be aborted when the remote operation does not complete.
  """
  def start_presigned_multipart_upload(
        bucket,
        path,
        storage_profile,
        content_type,
        opts \\ []
      )

  def start_presigned_multipart_upload(
        bucket,
        path,
        storage_profile,
        content_type,
        opts
      )
      when is_binary(bucket) and is_binary(path) and is_binary(content_type) and is_list(opts) do
    max_bytes = Keyword.get(opts, :max_bytes)

    part_size =
      case max_bytes do
        value when is_integer(value) and value > 0 ->
          min_multipart_part_size(direct_upload_part_size(opts), value, @multipart_max_parts)

        _other ->
          direct_upload_part_size(opts)
      end

    part_count = direct_upload_part_count(part_size, opts)
    expires = positive_integer(Keyword.get(opts, :expires), @direct_upload_url_expiry_seconds)
    public? = Keyword.get(opts, :public, true) != false

    case validate_direct_upload_capacity(part_size, max_bytes) do
      :ok ->
        start_presigned_multipart_upload_session(
          bucket,
          path,
          storage_profile,
          content_type,
          part_size,
          part_count,
          expires,
          public?
        )

      {:error, _reason} = error ->
        error
    end
  end

  def start_presigned_multipart_upload(
        _bucket,
        _path,
        _storage_profile,
        _content_type,
        _opts
      ),
      do: {:error, :invalid_multipart_upload_destination}

  defp start_presigned_multipart_upload_session(
         bucket,
         path,
         storage_profile,
         content_type,
         part_size,
         part_count,
         expires,
         public?
       ) do
    case initiate_multipart_upload(bucket, path, storage_profile, content_type, public: public?) do
      {:ok, upload_id} ->
        case presigned_multipart_payload(
               bucket,
               path,
               storage_profile,
               upload_id,
               part_size,
               part_count,
               expires
             ) do
          {:ok, payload} ->
            {:ok,
             %{
               bucket: bucket,
               path: path,
               storage_profile: storage_profile,
               upload_id: upload_id,
               payload: payload
             }}

          {:error, reason} ->
            _ = abort_multipart_upload(bucket, path, storage_profile, upload_id)
            {:error, reason}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Aborts a multipart destination returned by `start_presigned_multipart_upload/5`."
  def abort_presigned_multipart_upload(%{
        bucket: bucket,
        path: path,
        storage_profile: storage_profile,
        upload_id: upload_id
      }) do
    abort_multipart_upload(bucket, path, storage_profile, upload_id)
  end

  def abort_presigned_multipart_upload(_session), do: {:error, :invalid_multipart_upload_session}

  @doc "Returns a short-lived read URL for a single object-storage object."
  def presigned_get_url(bucket, path, storage_profile, opts \\ [])

  def presigned_get_url(bucket, path, storage_profile, opts)
      when is_binary(bucket) and is_binary(path) and is_list(opts) do
    config = config_for_bucket(storage_profile, bucket)
    expires = positive_integer(Keyword.get(opts, :expires), @direct_upload_url_expiry_seconds)

    with {:ok, endpoint} <- required_storage_config(config, :endpoint),
         {:ok, access_key_id} <- required_storage_config(config, :access_key_id),
         {:ok, secret_access_key} <- required_storage_config(config, :secret_access_key) do
      {:ok,
       ReqS3.presign_url(
         access_key_id: access_key_id,
         secret_access_key: secret_access_key,
         region: config_value(config, :region) || "us-east-1",
         endpoint_url: endpoint,
         bucket: bucket,
         key: path,
         method: :get,
         expires: min(expires, @direct_upload_url_expiry_seconds)
       )}
    end
  rescue
    _error -> {:error, :object_presign_failed}
  end

  def presigned_get_url(_bucket, _path, _storage_profile, _opts),
    do: {:error, :invalid_storage_url}

  @doc """
  Returns a short-lived, single-object PUT destination.

  The returned headers are part of the signature and must be sent unchanged.
  This lets an external media worker publish a bounded object without receiving
  storage credentials or proxying the object through the application.
  """
  def presigned_put_url(
        bucket,
        path,
        storage_profile,
        content_type,
        content_length,
        opts \\ []
      )

  def presigned_put_url(
        bucket,
        path,
        storage_profile,
        content_type,
        content_length,
        opts
      )
      when is_binary(bucket) and is_binary(path) and is_binary(content_type) and
             is_integer(content_length) and content_length > 0 and is_list(opts) do
    config = config_for_bucket(storage_profile, bucket)
    expires = positive_integer(Keyword.get(opts, :expires), @direct_upload_url_expiry_seconds)

    headers =
      [
        {"content-type", content_type},
        {"content-length", Integer.to_string(content_length)}
      ]
      |> maybe_add_public_read_header(storage_profile, public: true)

    with {:ok, endpoint} <- required_storage_config(config, :endpoint),
         {:ok, access_key_id} <- required_storage_config(config, :access_key_id),
         {:ok, secret_access_key} <- required_storage_config(config, :secret_access_key) do
      {:ok,
       %{
         "url" =>
           ReqS3.presign_url(
             access_key_id: access_key_id,
             secret_access_key: secret_access_key,
             region: config_value(config, :region) || "us-east-1",
             endpoint_url: endpoint,
             bucket: bucket,
             key: path,
             method: :put,
             headers: headers,
             expires: min(expires, @direct_upload_url_expiry_seconds)
           ),
         "headers" => Map.new(headers)
       }}
    end
  rescue
    _error -> {:error, :object_presign_failed}
  end

  def presigned_put_url(
        _bucket,
        _path,
        _storage_profile,
        _content_type,
        _content_length,
        _opts
      ),
      do: {:error, :invalid_storage_url}

  @doc """
  Copies an object within the same storage profile without loading it into BEAM memory.
  """
  def copy_public(
        destination_bucket,
        destination_path,
        source_bucket,
        source_path,
        storage_profile \\ nil
      ) do
    if same_storage_backend?(storage_profile, destination_bucket, storage_profile, source_bucket) do
      do_copy_public(
        destination_bucket,
        destination_path,
        source_bucket,
        source_path,
        storage_profile
      )
    else
      do_copy_public_between_profiles(
        destination_bucket,
        destination_path,
        storage_profile,
        source_bucket,
        source_path,
        storage_profile,
        []
      )
    end
  end

  defp do_copy_public(
         destination_bucket,
         destination_path,
         source_bucket,
         source_path,
         storage_profile
       ) do
    headers =
      [{"x-amz-copy-source", copy_source_header(source_bucket, source_path)}]
      |> maybe_add_public_read_header(storage_profile, public: true)

    case Req.put(build_req(destination_bucket, storage_profile),
           url: "/#{destination_path}",
           body: "",
           headers: headers
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status}} ->
        {:error, {:copy_failed, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Removes user-defined metadata from a public object without downloading its body.

  Objects above the provider's single-copy limit are rewritten with a server-side
  multipart copy, so this is safe for completed upload originals of any supported
  size.
  """
  def sanitize_public_object_metadata(bucket, path, storage_profile \\ nil) do
    with {:ok, info} <- object_info(bucket, path, storage_profile),
         {:ok, size_bytes} <- require_object_size(info) do
      context = %{
        destination_bucket: bucket,
        destination_path: path,
        destination_storage_profile: storage_profile,
        source_bucket: bucket,
        source_path: path,
        source_storage_profile: storage_profile,
        size_bytes: size_bytes,
        content_type: info.content_type || "application/octet-stream"
      }

      if size_bytes <= server_side_copy_max_bytes([]) do
        copy_object_public_between_profiles(context, "REPLACE")
      else
        multipart_server_side_copy_public_between_profiles(context, [])
      end
    end
  end

  @doc """
  Copies a public object between storage profiles.

  Same-backend copies use the provider-side copy operation. Cross-profile copies
  use bounded concurrent ranged reads and multipart upload parts so a large
  original does not have to live in a worker temp file or a single long-running
  PUT request.
  """
  def copy_public_between_profiles(
        destination_bucket,
        destination_path,
        destination_storage_profile,
        source_bucket,
        source_path,
        source_storage_profile,
        opts \\ []
      ) do
    if same_storage_backend?(
         destination_storage_profile,
         destination_bucket,
         source_storage_profile,
         source_bucket
       ) do
      copy_public(
        destination_bucket,
        destination_path,
        source_bucket,
        source_path,
        destination_storage_profile
      )
    else
      do_copy_public_between_profiles(
        destination_bucket,
        destination_path,
        destination_storage_profile,
        source_bucket,
        source_path,
        source_storage_profile,
        opts
      )
    end
  end

  @doc """
  Copies all objects below a prefix using public-read semantics for media outputs.

  When source and destination storage profiles differ, objects are streamed through
  a temporary file so large media outputs are not loaded into BEAM memory.
  """
  def copy_prefix_public(
        destination_bucket,
        destination_prefix,
        destination_storage_profile,
        source_bucket,
        source_prefix,
        source_storage_profile,
        opts \\ []
      ) do
    with {:ok, keys} <- list_prefix_keys(source_bucket, source_prefix, source_storage_profile) do
      failures =
        Enum.flat_map(keys, fn source_key ->
          copy_prefix_key_failure(
            source_key,
            source_prefix,
            source_bucket,
            source_storage_profile,
            destination_bucket,
            destination_prefix,
            destination_storage_profile,
            opts
          )
        end)

      case failures do
        [] -> :ok
        failures -> {:error, {:copy_prefix_failed, failures}}
      end
    end
  end

  defp copy_prefix_key_failure(
         source_key,
         source_prefix,
         source_bucket,
         source_storage_profile,
         destination_bucket,
         destination_prefix,
         destination_storage_profile,
         opts
       ) do
    case copy_prefix_key_public(
           source_key,
           source_prefix,
           source_bucket,
           source_storage_profile,
           destination_bucket,
           destination_prefix,
           destination_storage_profile,
           opts
         ) do
      :ok -> []
      {:error, failure} -> [failure]
    end
  end

  defp copy_prefix_key_public(
         source_key,
         source_prefix,
         source_bucket,
         source_storage_profile,
         destination_bucket,
         destination_prefix,
         destination_storage_profile,
         opts
       ) do
    destination_key = destination_prefix <> String.replace_prefix(source_key, source_prefix, "")

    result =
      case maybe_skip_existing_prefix_key(
             destination_bucket,
             destination_key,
             destination_storage_profile,
             source_bucket,
             source_key,
             source_storage_profile,
             opts
           ) do
        :skip ->
          :ok

        :copy ->
          copy_key_public_with_retries(
            destination_bucket,
            destination_key,
            destination_storage_profile,
            source_bucket,
            source_key,
            source_storage_profile,
            opts,
            @copy_prefix_key_max_attempts
          )

        {:error, reason} ->
          {:error, reason}
      end

    case result do
      :ok -> :ok
      {:error, reason} -> {:error, {source_key, reason}}
    end
  end

  defp maybe_skip_existing_prefix_key(
         destination_bucket,
         destination_key,
         destination_storage_profile,
         source_bucket,
         source_key,
         source_storage_profile,
         opts
       ) do
    if Keyword.get(opts, :skip_existing?, true) do
      existing_prefix_key_status(
        destination_bucket,
        destination_key,
        destination_storage_profile,
        source_bucket,
        source_key,
        source_storage_profile
      )
    else
      :copy
    end
  end

  defp existing_prefix_key_status(
         destination_bucket,
         destination_key,
         destination_storage_profile,
         source_bucket,
         source_key,
         source_storage_profile
       ) do
    case object_info(source_bucket, source_key, source_storage_profile) do
      {:ok, %{size_bytes: source_size}} when is_integer(source_size) ->
        case object_info(destination_bucket, destination_key, destination_storage_profile) do
          {:ok, %{size_bytes: ^source_size}} -> :skip
          {:ok, _info} -> :copy
          {:error, :not_found} -> :copy
          {:error, _reason} -> :copy
        end

      {:ok, _info} ->
        :copy

      {:error, reason} ->
        {:error, {:source_object_info_failed, reason}}
    end
  end

  defp copy_key_public_with_retries(
         destination_bucket,
         destination_key,
         destination_storage_profile,
         source_bucket,
         source_key,
         source_storage_profile,
         opts,
         attempts_left
       ) do
    case copy_key_public(
           destination_bucket,
           destination_key,
           destination_storage_profile,
           source_bucket,
           source_key,
           source_storage_profile,
           opts
         ) do
      :ok ->
        :ok

      {:error, reason} = error ->
        if attempts_left > 1 and transient_storage_copy_error?(reason) do
          Process.sleep(@copy_prefix_key_retry_delay_ms)

          copy_key_public_with_retries(
            destination_bucket,
            destination_key,
            destination_storage_profile,
            source_bucket,
            source_key,
            source_storage_profile,
            opts,
            attempts_left - 1
          )
        else
          error
        end
    end
  end

  defp transient_storage_copy_error?(%Req.TransportError{reason: reason})
       when reason in [:closed, :timeout, :econnreset, :enetunreach],
       do: true

  defp transient_storage_copy_error?({:storage_request_timeout, _timeout_ms}), do: true

  defp transient_storage_copy_error?({:storage_request_exit, reason}),
    do: transient_storage_copy_error?(reason)

  defp transient_storage_copy_error?({:multipart_copy_failed, reason}),
    do: transient_storage_copy_error?(reason)

  defp transient_storage_copy_error?({_tag, reason}),
    do: transient_storage_copy_error?(reason)

  defp transient_storage_copy_error?(_reason), do: false

  @doc """
  Deletes all objects below a prefix.
  """
  def delete_prefix(bucket, prefix, storage_profile \\ nil) do
    with {:ok, keys} <- list_prefix_keys(bucket, prefix, storage_profile) do
      delete_keys(bucket, keys, storage_profile)
    end
  end

  @doc """
  Checks whether an object prefix is empty without fetching object bodies.

  A missing bucket is treated as empty.
  """
  def prefix_empty?(bucket, prefix, storage_profile \\ nil) do
    case list_prefix_keys(bucket, prefix, storage_profile) do
      {:ok, []} -> {:ok, true}
      {:ok, _keys} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Deletes one object.
  """
  def delete_object(bucket, key, storage_profile \\ nil) do
    case Req.delete(build_req(bucket, storage_profile), url: "/#{key}") do
      {:ok, %{status: status}} when status in 200..299 or status == 404 ->
        :ok

      {:ok, %{status: status}} ->
        {:error, {:delete_failed, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns lightweight object metadata without fetching the body.
  """
  def object_info(bucket, path, storage_profile \\ nil) do
    case head(bucket, path, storage_profile) do
      {:ok, %{status: status, headers: headers}} when status in 200..299 ->
        {:ok,
         %{
           size_bytes: parse_content_length(headers),
           content_type: extract_content_type(headers),
           sha256: header_value(headers, "x-amz-meta-mave-sha256")
         }}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:object_info_failed, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Syncs bucket CORS for a space based on its linked domains and hotlink protection setting.

  If the bucket doesn't exist yet, this is treated as a no-op so the dashboard can
  persist the space settings before storage provisioning catches up.
  """
  def sync_space_domain_cors(%Space{} = space) do
    storage_profile = StorageProfiles.resolve(space.region)
    bucket = bucket_for_space(space.hash, storage_profile)
    allowed_domains = allowed_domains_for_space(space)
    hotlink_protection_enabled = hotlink_protection_enabled_for_bucket(space)

    case head_bucket(bucket, storage_profile) do
      {:ok, %{status: status}} when status in 200..299 ->
        with :ok <- maybe_put_bucket_cors(bucket, allowed_domains, storage_profile) do
          put_bucket_access_policy(
            bucket,
            allowed_domains,
            hotlink_protection_enabled,
            storage_profile
          )
        end

      {:ok, %{status: 404}} ->
        Logger.debug("Skipping bucket CORS sync for missing bucket #{bucket}")
        :ok

      {:ok, %{status: status}} ->
        {:error, {:bucket_check_failed, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Updates all objects below an embed prefix to either private or public-read.
  Mirrors the legacy mave-encoder behavior used for hiding/restoring embeds.
  """
  def update_embed_visibility(space_or_hash, embed_hash, visibility, storage_profile \\ nil)

  def update_embed_visibility(%Space{} = space, embed_hash, visibility, storage_profile)
      when visibility in ["private", "public"] do
    storage_profile = storage_profile || space.region
    do_update_embed_visibility(space, space.hash, embed_hash, visibility, storage_profile)
  end

  def update_embed_visibility(space_hash, embed_hash, visibility, storage_profile)
      when visibility in ["private", "public"] do
    do_update_embed_visibility(space_hash, space_hash, embed_hash, visibility, storage_profile)
  end

  @doc """
  Updates one object's visibility using its S3-compatible object ACL.
  """
  def set_object_visibility(bucket, key, visibility, storage_profile \\ nil)

  def set_object_visibility(bucket, key, visibility, storage_profile)
      when is_binary(bucket) and bucket != "" and is_binary(key) and key != "" and
             visibility in ["private", "public"] do
    acl = if visibility == "private", do: "private", else: "public-read"
    put_object_acl(bucket, key, acl, storage_profile)
  end

  def set_object_visibility(_bucket, _key, _visibility, _storage_profile),
    do: {:error, :invalid_object_visibility}

  defp do_update_embed_visibility(
         cache_space,
         space_hash,
         embed_hash,
         visibility,
         storage_profile
       ) do
    storage_profile = StorageProfiles.resolve(storage_profile)
    bucket = bucket_for_space(space_hash, storage_profile)
    prefix = "#{embed_hash}/"
    acl = if visibility == "private", do: "private", else: "public-read"

    if object_acl_enabled_for_profile?(storage_profile) do
      with {:ok, keys} <- list_prefix_keys(bucket, prefix, storage_profile),
           :ok <- update_keys_acl(bucket, keys, acl, storage_profile) do
        CdnCache.purge_best_effort(cache_space, storage_profile, [prefix])
      end
    else
      CdnCache.purge_best_effort(cache_space, storage_profile, [prefix])
    end
  end

  def put_bucket_cors(bucket, allowed_domains, storage_profile \\ nil) do
    body = build_bucket_cors_xml(allowed_domains)
    content_md5 = :crypto.hash(:md5, body) |> Base.encode64()

    case Req.put(build_service_req(storage_profile, bucket),
           url: "/#{bucket}?cors",
           body: body,
           headers: [
             {"content-type", "application/xml"},
             {"content-md5", content_md5}
           ]
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status}} ->
        {:error, {:bucket_cors_failed, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def put_bucket_access_policy(
        bucket,
        allowed_domains,
        hotlink_protection_enabled,
        storage_profile \\ nil
      ) do
    if hotlink_protection_enabled do
      body = build_bucket_policy_json(bucket, allowed_domains)

      case Req.put(build_service_req(storage_profile, bucket),
             url: "/#{bucket}?policy",
             body: body,
             headers: [{"content-type", "application/json"}]
           ) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: status}} ->
          {:error, {:bucket_policy_failed, status}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      body = build_public_bucket_policy_json(bucket)

      case Req.put(build_service_req(storage_profile, bucket),
             url: "/#{bucket}?policy",
             body: body,
             headers: [{"content-type", "application/json"}]
           ) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: status}} ->
          {:error, {:bucket_policy_failed, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Ensures a private source bucket allows object reads carrying Mave's FFmpeg
  Referer. Existing bucket-policy statements are preserved.

  The successful result is cached per node, bucket, endpoint, and derived
  Referer so normal uploads do not add storage control-plane requests.
  """
  def ensure_ffmpeg_bucket_access_policy(bucket, storage_profile \\ nil)

  def ensure_ffmpeg_bucket_access_policy(bucket, storage_profile)
      when is_binary(bucket) and bucket != "" do
    with referer when is_binary(referer) <- ffmpeg_input_referer(),
         cache_key <- ffmpeg_policy_cache_key(bucket, storage_profile, referer) do
      ensure_cached_ffmpeg_bucket_policy(
        cache_key,
        bucket,
        storage_profile,
        referer
      )
    else
      _other -> {:error, :ffmpeg_input_referer_missing}
    end
  end

  def ensure_ffmpeg_bucket_access_policy(_bucket, _storage_profile),
    do: {:error, :invalid_bucket}

  defp ensure_cached_ffmpeg_bucket_policy(cache_key, bucket, storage_profile, referer) do
    if :persistent_term.get(cache_key, false) do
      :ok
    else
      sync_ffmpeg_bucket_policy(cache_key, bucket, storage_profile, referer)
    end
  end

  defp sync_ffmpeg_bucket_policy(cache_key, bucket, storage_profile, referer) do
    with {:ok, policy} <- get_bucket_access_policy(bucket, storage_profile),
         :ok <- validate_bucket_policy_write_access(policy, storage_profile),
         :ok <-
           put_bucket_policy_document(
             bucket,
             merge_ffmpeg_read_statement(policy, bucket, referer, storage_profile),
             storage_profile
           ) do
      :persistent_term.put(cache_key, true)
      :ok
    end
  end

  defp validate_bucket_policy_write_access(policy, storage_profile) do
    if bucket_policy_dialect(storage_profile) == :scaleway and
         not policy_allows_authenticated_object_writes?(policy) do
      {:error, :scaleway_bucket_policy_writer_required}
    else
      :ok
    end
  end

  defp policy_allows_authenticated_object_writes?(policy) do
    policy
    |> Map.get("Statement", [])
    |> List.wrap()
    |> Enum.any?(fn statement ->
      scw_principal?(Map.get(statement, "Principal")) and
        write_action?(Map.get(statement, "Action"))
    end)
  end

  defp scw_principal?(%{"SCW" => principal}) when is_binary(principal), do: principal != ""
  defp scw_principal?(%{"SCW" => principals}) when is_list(principals), do: principals != []
  defp scw_principal?(_principal), do: false

  defp write_action?(actions) do
    actions
    |> List.wrap()
    |> Enum.any?(&(&1 in ["*", "s3:*", "s3:PutObject"]))
  end

  @doc false
  def build_bucket_cors_xml(allowed_domains) do
    cors_rules_xml =
      allowed_domains
      |> build_allowed_origins()
      |> Enum.map_join("", fn origin ->
        """
        <CORSRule>
          <AllowedHeader>*</AllowedHeader>
          <AllowedMethod>GET</AllowedMethod>
          <AllowedMethod>HEAD</AllowedMethod>
          <AllowedOrigin>#{xml_escape(origin)}</AllowedOrigin>
          <ExposeHeader>Accept-Ranges</ExposeHeader>
          <ExposeHeader>Content-Length</ExposeHeader>
          <ExposeHeader>Content-Range</ExposeHeader>
          <ExposeHeader>ETag</ExposeHeader>
        </CORSRule>
        """
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <CORSConfiguration>
      #{cors_rules_xml}
    </CORSConfiguration>
    """
    |> String.trim()
  end

  @doc false
  def build_bucket_policy_json(bucket, allowed_domains) do
    statements =
      [
        %{
          "Sid" => "AllowGetRequestsReferer",
          "Effect" => "Allow",
          "Principal" => "*",
          "Action" => "s3:GetObject",
          "Resource" => bucket_resource_arn(bucket),
          "Condition" => %{
            "StringLike" => %{
              "aws:Referer" => build_allowed_referers(allowed_domains)
            }
          }
        }
      ]
      |> maybe_append_ffmpeg_read_statement(bucket)

    %{
      "Version" => @aws_policy_version,
      "Statement" => statements
    }
    |> Jason.encode_to_iodata!()
  end

  @doc false
  def build_public_bucket_policy_json(bucket) do
    %{
      "Version" => @aws_policy_version,
      "Statement" => [
        %{
          "Sid" => @public_read_policy_sid,
          "Effect" => "Allow",
          "Principal" => "*",
          "Action" => "s3:GetObject",
          "Resource" => bucket_resource_arn(bucket)
        }
      ]
    }
    |> Jason.encode_to_iodata!()
  end

  defp maybe_put_bucket_cors(bucket, allowed_domains, storage_profile) do
    case put_bucket_cors(bucket, allowed_domains, storage_profile) do
      :ok ->
        :ok

      {:error, {:bucket_cors_failed, 501}} ->
        Logger.debug("Bucket CORS unsupported for #{bucket}, continuing with access policy sync")
        :ok

      other ->
        other
    end
  end

  @doc false
  def build_allowed_origins(allowed_domains) do
    requested_origins =
      allowed_domains
      |> normalize_requested_origins()
      |> expand_requested_origins()

    if "*" in requested_origins do
      ["*"]
    else
      default_allowed_origins()
      |> Enum.concat(Enum.reject(requested_origins, &(&1 == "*")))
      |> Enum.uniq()
    end
  end

  @doc false
  def build_allowed_referers(allowed_domains) do
    requested_origins =
      allowed_domains
      |> normalize_requested_origins()
      |> expand_requested_origins()

    if "*" in requested_origins do
      ["*"]
    else
      default_allowed_origins()
      |> Enum.concat(Enum.reject(requested_origins, &(&1 == "*")))
      |> Enum.flat_map(&origin_to_referer_patterns/1)
      |> Enum.uniq()
    end
  end

  defp allowed_domains_for_space(%Space{} = space) do
    if SharedStorageSpace.shared?(space) do
      ["*"]
    else
      allowed_domains_for_hotlink_protection(space)
    end
  end

  defp allowed_domains_for_hotlink_protection(%Space{
         hotlink_protection_enabled: true,
         domains: domains
       }) do
    Enum.map(domains || [], & &1.domain)
  end

  defp allowed_domains_for_hotlink_protection(%Space{}), do: ["*"]

  defp hotlink_protection_enabled_for_bucket(%Space{} = space) do
    not SharedStorageSpace.shared?(space) and space.hotlink_protection_enabled == true
  end

  defp normalize_requested_origins(nil), do: []

  defp normalize_requested_origins(allowed_domains) when is_binary(allowed_domains) do
    normalize_requested_origins([allowed_domains])
  end

  defp normalize_requested_origins(allowed_domains) when is_list(allowed_domains) do
    allowed_domains
    |> Enum.reduce([], fn
      value, acc when is_binary(value) ->
        candidate = value |> String.trim() |> String.trim_trailing("/")

        cond do
          candidate == "" ->
            acc

          candidate == "*" ->
            acc ++ ["*"]

          String.starts_with?(candidate, "https://") or String.starts_with?(candidate, "http://") ->
            acc ++ [candidate]

          true ->
            acc ++ ["https://#{candidate}", "http://#{candidate}"]
        end

      _, acc ->
        acc
    end)
    |> Enum.uniq()
  end

  defp expand_requested_origins(origins) do
    origins
    |> Enum.flat_map(fn origin ->
      case subdomain_wildcard_origin(origin) do
        nil -> [origin]
        wildcard_origin -> [origin, wildcard_origin]
      end
    end)
    |> Enum.uniq()
  end

  defp subdomain_wildcard_origin("*"), do: nil

  defp subdomain_wildcard_origin(origin) do
    case URI.parse(origin) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        if String.starts_with?(host, "*.") do
          nil
        else
          uri
          |> Map.put(:host, "*.#{host}")
          |> URI.to_string()
        end

      _other ->
        nil
    end
  end

  defp default_allowed_origins do
    configured_domain_origins() ++
      endpoint_origins() ++ localhost_origins() ++ public_cdn_origins()
  end

  defp configured_domain_origins do
    case Application.get_env(:mave_core, :domain) do
      domain when is_binary(domain) and domain != "" ->
        host =
          domain
          |> String.trim()
          |> String.trim_trailing("/")
          |> URI.parse()
          |> Map.get(:host)

        host
        |> host_defaults()

      _ ->
        []
    end
  end

  defp endpoint_origins do
    :mave_core
    |> Application.get_env(MaveCoreWeb.Endpoint, [])
    |> Keyword.get(:url, [])
    |> endpoint_url_origins()
  end

  defp endpoint_url_origins(url_config) when is_list(url_config) do
    host = Keyword.get(url_config, :host)
    scheme = Keyword.get(url_config, :scheme)
    port = Keyword.get(url_config, :port)

    host
    |> host_defaults()
    |> Enum.concat(endpoint_origin(host, scheme, port))
  end

  defp endpoint_url_origins(_url_config), do: []

  defp endpoint_origin(host, scheme, port)
       when is_binary(host) and host != "" and is_binary(scheme) and scheme != "" and
              is_integer(port) do
    default_port? = (scheme == "http" and port == 80) or (scheme == "https" and port == 443)
    port_suffix = if default_port?, do: "", else: ":#{port}"

    ["#{scheme}://#{host}#{port_suffix}"]
  end

  defp endpoint_origin(_host, _scheme, _port), do: []

  defp localhost_origins do
    for scheme <- ["http", "https"],
        host <- ["localhost", "127.0.0.1", "[::1]"],
        port_suffix <- ["", ":*"] do
      "#{scheme}://#{host}#{port_suffix}"
    end
  end

  defp public_cdn_origins do
    host = Application.get_env(:mave_core, :public_cdn_host, "video-dns.com")

    configured_base_origins =
      case Application.get_env(:mave_core, :public_cdn_base_url) do
        base_url when is_binary(base_url) and base_url != "" ->
          case URI.parse(base_url) do
            %URI{scheme: scheme, host: base_host} = uri
            when scheme in ["http", "https"] and is_binary(base_host) and base_host != "" ->
              [URI.to_string(%URI{scheme: scheme, host: base_host, port: uri.port})]

            _other ->
              []
          end

        _other ->
          []
      end

    (configured_base_origins ++
       ["https://#{host}", "http://#{host}", "https://*.#{host}", "http://*.#{host}"])
    |> Enum.uniq()
  end

  defp host_defaults(nil), do: []
  defp host_defaults(""), do: []

  defp host_defaults(host) do
    hosts =
      host
      |> related_hosts()
      |> Enum.uniq()

    hosts
    |> Enum.flat_map(fn value -> ["https://#{value}", "http://#{value}"] end)
    |> Enum.uniq()
  end

  defp related_hosts(host) do
    parts = String.split(host, ".", trim: true)

    case parts do
      [prefix | rest] when prefix in ["app", "dash", "api"] and length(rest) >= 2 ->
        base = Enum.join(rest, ".")
        [host, base, "app.#{base}", "dash.#{base}"]

      [_ | _] when length(parts) >= 2 ->
        [host, "app.#{host}", "dash.#{host}"]

      _ ->
        [host]
    end
  end

  defp origin_to_referer_patterns("*"), do: ["*"]

  defp origin_to_referer_patterns(origin) do
    trimmed = String.trim_trailing(origin, "/")
    [trimmed, "#{trimmed}/*"]
  end

  defp maybe_append_ffmpeg_read_statement(statements, bucket) do
    case ffmpeg_input_referer() do
      referer when is_binary(referer) ->
        statements ++ [ffmpeg_read_statement(bucket, referer, :aws)]

      _other ->
        statements
    end
  end

  defp ffmpeg_read_statement(bucket, referer, dialect) do
    %{
      "Sid" => @ffmpeg_policy_sid,
      "Effect" => "Allow",
      "Principal" => "*",
      "Action" => "s3:GetObject",
      "Resource" => bucket_policy_object_resource(bucket, dialect),
      "Condition" => %{
        "StringLike" => %{
          "aws:Referer" => referer
        }
      }
    }
  end

  defp merge_ffmpeg_read_statement(policy, bucket, referer, storage_profile) do
    dialect = bucket_policy_dialect(storage_profile)

    statements =
      policy
      |> Map.get("Statement", [])
      |> List.wrap()
      |> Enum.reject(&(Map.get(&1, "Sid") == @ffmpeg_policy_sid))
      |> Kernel.++([ffmpeg_read_statement(bucket, referer, dialect)])

    policy
    |> Map.put("Version", bucket_policy_version(dialect))
    |> Map.put("Statement", statements)
  end

  defp get_bucket_access_policy(bucket, storage_profile) do
    case Req.get(build_service_req(storage_profile, bucket), url: "/#{bucket}?policy", raw: true) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        decode_bucket_policy(body)

      {:ok, %{status: 404}} ->
        {:ok, %{"Statement" => []}}

      {:ok, %{status: status}} ->
        {:error, {:bucket_policy_read_failed, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_bucket_policy(%{"Policy" => policy}) when is_binary(policy),
    do: decode_bucket_policy(policy)

  defp decode_bucket_policy(policy) when is_map(policy), do: {:ok, policy}

  defp decode_bucket_policy(policy) when is_binary(policy) do
    case Jason.decode(policy) do
      {:ok, decoded} when is_map(decoded) -> decode_bucket_policy(decoded)
      _other -> {:error, :invalid_bucket_policy}
    end
  end

  defp decode_bucket_policy(_policy), do: {:error, :invalid_bucket_policy}

  defp put_bucket_policy_document(bucket, policy, storage_profile) do
    case Req.put(build_service_req(storage_profile, bucket),
           url: "/#{bucket}?policy",
           body: Jason.encode_to_iodata!(policy),
           headers: [{"content-type", "application/json"}]
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} -> {:error, {:bucket_policy_failed, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ffmpeg_policy_cache_key(bucket, storage_profile, referer) do
    endpoint = storage_profile |> config_for_profile() |> config_value(:endpoint)
    referer_hash = :crypto.hash(:sha256, referer)
    {__MODULE__, :ffmpeg_bucket_policy, endpoint, bucket, referer_hash}
  end

  defp bucket_resource_arn(bucket) when is_binary(bucket) do
    "arn:aws:s3:::#{bucket}/*"
  end

  defp bucket_policy_object_resource(bucket, :scaleway), do: ["#{bucket}/*"]
  defp bucket_policy_object_resource(bucket, :aws), do: bucket_resource_arn(bucket)

  defp bucket_policy_version(:scaleway), do: @scaleway_policy_version
  defp bucket_policy_version(:aws), do: @aws_policy_version

  defp xml_escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp head(bucket, path, storage_profile, retry_count \\ 0) do
    result =
      bucket
      |> build_req(storage_profile)
      |> Req.merge(retry: false)
      |> Req.head(url: "/#{path}")

    if retry_object_head?(result) and retry_count < @object_head_max_retries do
      Logger.warning(
        "S3 HEAD transient failure; retrying with a fresh signed request " <>
          "(retry #{retry_count + 1}/#{@object_head_max_retries})"
      )

      Process.sleep(object_head_retry_delay(retry_count))
      head(bucket, path, storage_profile, retry_count + 1)
    else
      result
    end
  end

  defp head_bucket(bucket, storage_profile) do
    build_service_req(storage_profile, bucket)
    |> Req.head(url: "/#{bucket}")
  end

  defp create_bucket(bucket, storage_profile) do
    case Req.put(build_service_req(storage_profile, bucket), url: "/#{bucket}") do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: 409}} ->
        :ok

      {:ok, %{status: status}} ->
        {:error, {:bucket_create_failed, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp copy_key_public(
         destination_bucket,
         destination_key,
         destination_storage_profile,
         source_bucket,
         source_key,
         source_storage_profile,
         opts
       ) do
    copy_public_between_profiles(
      destination_bucket,
      destination_key,
      destination_storage_profile,
      source_bucket,
      source_key,
      source_storage_profile,
      opts
    )
  end

  defp do_copy_public_between_profiles(
         destination_bucket,
         destination_path,
         destination_storage_profile,
         source_bucket,
         source_path,
         source_storage_profile,
         opts
       ) do
    with {:ok, info} <- object_info(source_bucket, source_path, source_storage_profile),
         {:ok, size_bytes} <- require_object_size(info) do
      content_type = info.content_type || "application/octet-stream"

      context = %{
        destination_bucket: destination_bucket,
        destination_path: destination_path,
        destination_storage_profile: destination_storage_profile,
        source_bucket: source_bucket,
        source_path: source_path,
        source_storage_profile: source_storage_profile,
        size_bytes: size_bytes,
        content_type: content_type
      }

      copy_public_between_profiles_with_strategy(context, opts)
    end
  end

  defp copy_public_between_profiles_with_strategy(context, opts) do
    if server_side_copy_enabled?(opts) do
      context
      |> server_side_copy_public_between_profiles(opts)
      |> maybe_fallback_to_proxy_copy(context, opts)
    else
      proxy_copy_public_between_profiles(context, opts)
    end
  end

  defp maybe_fallback_to_proxy_copy(:ok, _context, _opts), do: :ok

  defp maybe_fallback_to_proxy_copy({:error, reason} = error, context, opts) do
    if server_side_copy_fallback_enabled?(opts) do
      Logger.warning("S3 server-side copy failed, falling back to proxy copy: #{inspect(reason)}")

      proxy_copy_public_between_profiles(context, opts)
    else
      error
    end
  end

  defp proxy_copy_public_between_profiles(context, opts) do
    %{
      destination_bucket: destination_bucket,
      destination_path: destination_path,
      destination_storage_profile: destination_storage_profile,
      source_bucket: source_bucket,
      source_path: source_path,
      source_storage_profile: source_storage_profile,
      size_bytes: size_bytes,
      content_type: content_type
    } = context

    if size_bytes <= cross_profile_single_put_max_bytes(opts) do
      copy_small_public_between_profiles(
        destination_bucket,
        destination_path,
        destination_storage_profile,
        source_bucket,
        source_path,
        source_storage_profile,
        content_type,
        size_bytes
      )
    else
      multipart_copy_public_between_profiles(
        context,
        opts
      )
    end
  end

  defp require_object_size(%{size_bytes: size_bytes})
       when is_integer(size_bytes) and size_bytes >= 0,
       do: {:ok, size_bytes}

  defp require_object_size(_info), do: {:error, :missing_object_size}

  defp copy_small_public_between_profiles(
         destination_bucket,
         destination_path,
         destination_storage_profile,
         source_bucket,
         source_path,
         source_storage_profile,
         content_type,
         _size_bytes
       ) do
    with_temp_copy_file(fn tmp_path ->
      with :ok <- download_to_file(source_bucket, source_path, tmp_path, source_storage_profile),
           {:ok, _response} <-
             put_file_public(
               destination_bucket,
               destination_path,
               tmp_path,
               content_type,
               destination_storage_profile
             ) do
        :ok
      end
    end)
  end

  defp with_temp_copy_file(fun) when is_function(fun, 1) do
    tmp_dir = Path.join(System.tmp_dir!(), @copy_tmp_root)
    tmp_path = Path.join(tmp_dir, copy_tmp_filename())

    with :ok <- SafeFile.mkdir_p(tmp_dir) do
      try do
        fun.(tmp_path)
      after
        _ = SafeFile.rm(tmp_path)
      end
    end
  end

  defp copy_tmp_filename do
    unique = System.unique_integer([:positive, :monotonic])
    random = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    "object-#{unique}-#{random}.tmp"
  end

  defp server_side_copy_public_between_profiles(context, opts) do
    if context.size_bytes <= server_side_copy_max_bytes(opts) do
      copy_object_public_between_profiles(context)
    else
      multipart_server_side_copy_public_between_profiles(context, opts)
    end
  end

  defp copy_object_public_between_profiles(context, metadata_directive \\ "COPY") do
    headers =
      [
        {"x-amz-copy-source", copy_source_header(context.source_bucket, context.source_path)},
        {"x-amz-metadata-directive", metadata_directive}
      ]
      |> maybe_add_replacement_content_type(metadata_directive, context.content_type)
      |> maybe_add_public_read_header(context.destination_storage_profile, public: true)

    result =
      build_req(context.destination_bucket, context.destination_storage_profile)
      |> Req.merge(retry: false)
      |> Req.Request.put_headers(headers)
      |> request_with_deadline(
        fn req -> Req.put(req, url: "/#{context.destination_path}", body: "") end,
        @multipart_control_request_timeout_ms
      )

    case result do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status}} ->
        {:error, {:server_side_copy_failed, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_add_replacement_content_type(headers, "REPLACE", content_type),
    do: headers ++ [{"content-type", content_type}]

  defp maybe_add_replacement_content_type(headers, _metadata_directive, _content_type),
    do: headers

  defp multipart_server_side_copy_public_between_profiles(context, opts) do
    case initiate_multipart_upload(
           context.destination_bucket,
           context.destination_path,
           context.destination_storage_profile,
           context.content_type
         ) do
      {:ok, upload_id} ->
        context =
          context
          |> Map.put(:upload_id, upload_id)
          |> Map.put(:opts, opts)

        result =
          case upload_multipart_server_side_copy_parts(
                 context,
                 server_side_multipart_copy_part_size(context.size_bytes, opts)
               ) do
            {:ok, parts} ->
              complete_multipart_upload(
                context.destination_bucket,
                context.destination_path,
                context.destination_storage_profile,
                upload_id,
                parts
              )

            {:error, reason} ->
              {:error, reason}
          end

        case result do
          :ok ->
            :ok

          {:error, reason} ->
            _ =
              abort_multipart_upload(
                context.destination_bucket,
                context.destination_path,
                context.destination_storage_profile,
                upload_id
              )

            {:error, {:server_side_multipart_copy_failed, reason}}

          other ->
            _ =
              abort_multipart_upload(
                context.destination_bucket,
                context.destination_path,
                context.destination_storage_profile,
                upload_id
              )

            {:error, {:server_side_multipart_copy_failed, other}}
        end

      {:error, reason} ->
        {:error, {:server_side_multipart_copy_failed, reason}}
    end
  end

  defp upload_multipart_server_side_copy_parts(context, part_size) do
    context.size_bytes
    |> multipart_ranges(part_size)
    |> upload_multipart_parts(
      fn part_number, range_start, range_end ->
        upload_multipart_server_side_copy_part_with_retries(
          context,
          part_number,
          range_start,
          range_end,
          multipart_part_max_attempts(context.opts)
        )
      end,
      :server_side_multipart_part_failed,
      multipart_copy_max_concurrency(context.opts)
    )
  end

  defp upload_multipart_server_side_copy_part_with_retries(
         context,
         part_number,
         range_start,
         range_end,
         attempts_left
       ) do
    case upload_multipart_server_side_copy_part(context, part_number, range_start, range_end) do
      {:ok, etag} ->
        {:ok, etag}

      {:error, reason} = error ->
        if attempts_left > 1 and transient_storage_copy_error?(reason) do
          Process.sleep(@copy_prefix_key_retry_delay_ms)

          upload_multipart_server_side_copy_part_with_retries(
            context,
            part_number,
            range_start,
            range_end,
            attempts_left - 1
          )
        else
          error
        end
    end
  end

  defp upload_multipart_server_side_copy_part(context, part_number, range_start, range_end) do
    headers = [
      {"x-amz-copy-source", copy_source_header(context.source_bucket, context.source_path)},
      {"x-amz-copy-source-range", "bytes=#{range_start}-#{range_end}"}
    ]

    params = [{"partNumber", Integer.to_string(part_number)}, {"uploadId", context.upload_id}]

    result =
      build_req(context.destination_bucket, context.destination_storage_profile)
      |> Req.merge(retry: false)
      |> Req.Request.put_headers(headers)
      |> request_with_deadline(
        fn req -> Req.put(req, url: "/#{context.destination_path}", params: params, body: "") end,
        @multipart_part_request_timeout_ms
      )

    case result do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        case extract_xml_value(to_string(body), "ETag") do
          etag when is_binary(etag) and etag != "" -> {:ok, etag}
          _ -> {:error, :missing_part_etag}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:server_side_part_copy_failed, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp multipart_copy_public_between_profiles(context, opts) do
    case initiate_multipart_upload(
           context.destination_bucket,
           context.destination_path,
           context.destination_storage_profile,
           context.content_type
         ) do
      {:ok, upload_id} ->
        context =
          context
          |> Map.put(:upload_id, upload_id)
          |> Map.put(:opts, opts)

        result =
          case upload_multipart_copy_parts(
                 context,
                 multipart_copy_part_size(context.size_bytes, opts)
               ) do
            {:ok, parts} ->
              complete_multipart_upload(
                context.destination_bucket,
                context.destination_path,
                context.destination_storage_profile,
                upload_id,
                parts
              )

            {:error, reason} ->
              {:error, reason}
          end

        case result do
          :ok ->
            :ok

          {:error, reason} ->
            _ =
              abort_multipart_upload(
                context.destination_bucket,
                context.destination_path,
                context.destination_storage_profile,
                upload_id
              )

            {:error, {:multipart_copy_failed, reason}}

          other ->
            _ =
              abort_multipart_upload(
                context.destination_bucket,
                context.destination_path,
                context.destination_storage_profile,
                upload_id
              )

            {:error, {:multipart_copy_failed, other}}
        end

      {:error, reason} ->
        {:error, {:multipart_copy_failed, reason}}
    end
  end

  defp initiate_multipart_upload(bucket, path, storage_profile, content_type, opts \\ []) do
    headers =
      [{"content-type", content_type}]
      |> maybe_add_public_read_header(storage_profile, public: Keyword.get(opts, :public, true))

    result =
      build_req(bucket, storage_profile)
      |> Req.merge(retry: false)
      |> Req.Request.put_headers(headers)
      |> request_with_deadline(
        fn req -> Req.post(req, url: "/#{path}?uploads") end,
        @multipart_control_request_timeout_ms
      )

    case result do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        case extract_xml_value(to_string(body), "UploadId") do
          upload_id when is_binary(upload_id) and upload_id != "" -> {:ok, upload_id}
          _ -> {:error, :missing_upload_id}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:multipart_init_failed, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp presigned_multipart_payload(
         bucket,
         path,
         storage_profile,
         upload_id,
         part_size,
         part_count,
         expires
       ) do
    config = config_for_bucket(storage_profile, bucket)

    with {:ok, endpoint} <- required_storage_config(config, :endpoint),
         {:ok, access_key_id} <- required_storage_config(config, :access_key_id),
         {:ok, secret_access_key} <- required_storage_config(config, :secret_access_key) do
      base_options = [
        access_key_id: access_key_id,
        secret_access_key: secret_access_key,
        region: config_value(config, :region) || "us-east-1",
        endpoint_url: endpoint,
        expires: min(expires, @direct_upload_url_expiry_seconds)
      ]

      part_urls =
        Enum.map(1..part_count, fn part_number ->
          presign_multipart_url(
            base_options,
            bucket,
            path,
            upload_id,
            :put,
            [{"partNumber", Integer.to_string(part_number)}]
          )
        end)

      {:ok,
       %{
         "part_size_bytes" => part_size,
         "part_urls" => part_urls,
         "complete_url" =>
           presign_multipart_url(base_options, bucket, path, upload_id, :post, []),
         "abort_url" => presign_multipart_url(base_options, bucket, path, upload_id, :delete, [])
       }}
    end
  rescue
    _error -> {:error, :multipart_presign_failed}
  end

  defp presign_multipart_url(options, bucket, path, upload_id, method, extra_params) do
    endpoint = options |> Keyword.fetch!(:endpoint_url) |> String.trim_trailing("/")
    encoded_bucket = URI.encode(bucket, &URI.char_unreserved?/1)
    encoded_path = URI.encode(path, &(URI.char_unreserved?(&1) or &1 == ?/))

    query =
      extra_params
      |> Kernel.++([{"uploadId", upload_id}])

    ReqS3.presign_url(
      options
      |> Keyword.put(:method, method)
      |> Keyword.put(:url, "#{endpoint}/#{encoded_bucket}/#{encoded_path}")
      |> Keyword.put(:query, query)
    )
  end

  defp direct_upload_part_size(opts) do
    opts
    |> Keyword.get(:part_size, @direct_upload_part_size)
    |> positive_integer(@direct_upload_part_size)
    |> max(@s3_min_multipart_part_size)
    |> min(512 * 1024 * 1024)
  end

  defp direct_upload_part_count(part_size, opts) do
    case Keyword.get(opts, :max_bytes) do
      max_bytes when is_integer(max_bytes) and max_bytes > 0 ->
        max_bytes
        |> Kernel.+(part_size - 1)
        |> div(part_size)
        |> Kernel.+(1)
        |> max(1)
        |> min(@multipart_max_parts)

      _other ->
        @multipart_max_parts
    end
  end

  defp validate_direct_upload_capacity(part_size, _max_bytes)
       when part_size <= 512 * 1024 * 1024,
       do: :ok

  defp validate_direct_upload_capacity(_part_size, _max_bytes),
    do: {:error, :multipart_output_too_large}

  defp upload_multipart_copy_parts(context, part_size) do
    context.size_bytes
    |> multipart_ranges(part_size)
    |> upload_multipart_parts(
      fn part_number, range_start, range_end ->
        upload_multipart_copy_part_with_retries(
          context,
          part_number,
          range_start,
          range_end,
          multipart_part_max_attempts(context.opts)
        )
      end,
      :multipart_part_failed,
      multipart_copy_max_concurrency(context.opts)
    )
  end

  defp upload_multipart_parts(ranges, upload_part, failure_tag, max_concurrency) do
    {parts, failures} =
      ranges
      |> Task.async_stream(
        fn {part_number, range_start, range_end} ->
          {part_number, upload_part.(part_number, range_start, range_end)}
        end,
        max_concurrency: max_concurrency,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.reduce({[], []}, fn
        {:ok, {part_number, {:ok, etag}}}, {parts, failures} ->
          {[%{part_number: part_number, etag: etag} | parts], failures}

        {:ok, {part_number, {:error, reason}}}, {parts, failures} ->
          {parts, [{part_number, reason} | failures]}

        {:exit, reason}, {parts, failures} ->
          {parts, [{nil, {:multipart_part_task_failed, reason}} | failures]}
      end)

    case Enum.sort_by(failures, fn {part_number, _reason} -> part_number || 0 end) do
      [] ->
        {:ok, Enum.sort_by(parts, & &1.part_number)}

      [{nil, reason} | _failures] ->
        {:error, reason}

      [{part_number, reason} | _failures] ->
        {:error, {failure_tag, part_number, reason}}
    end
  end

  defp upload_multipart_copy_part_with_retries(
         context,
         part_number,
         range_start,
         range_end,
         attempts_left
       ) do
    case upload_multipart_copy_part(context, part_number, range_start, range_end) do
      {:ok, etag} ->
        {:ok, etag}

      {:error, reason} = error ->
        if attempts_left > 1 and transient_storage_copy_error?(reason) do
          Process.sleep(@copy_prefix_key_retry_delay_ms)

          upload_multipart_copy_part_with_retries(
            context,
            part_number,
            range_start,
            range_end,
            attempts_left - 1
          )
        else
          error
        end
    end
  end

  defp upload_multipart_copy_part(context, part_number, range_start, range_end) do
    with {:ok, body} <-
           get_object_range(
             context.source_bucket,
             context.source_path,
             context.source_storage_profile,
             range_start,
             range_end
           ) do
      upload_multipart_part(
        context.destination_bucket,
        context.destination_path,
        context.destination_storage_profile,
        context.upload_id,
        part_number,
        body
      )
    end
  end

  defp multipart_ranges(size_bytes, part_size) do
    Stream.unfold({1, 0}, fn
      {_part_number, offset} when offset >= size_bytes ->
        nil

      {part_number, offset} ->
        range_end = min(offset + part_size - 1, size_bytes - 1)
        {{part_number, offset, range_end}, {part_number + 1, range_end + 1}}
    end)
  end

  defp get_object_range(bucket, path, storage_profile, range_start, range_end) do
    expected_bytes = range_end - range_start + 1
    headers = [{"range", "bytes=#{range_start}-#{range_end}"}]

    result =
      build_req(bucket, storage_profile)
      |> Req.merge(retry: false)
      |> Req.Request.put_headers(headers)
      |> request_with_deadline(
        fn req ->
          Req.get(req, url: "/#{path}", raw: true, into: bounded_body(expected_bytes))
        end,
        @multipart_part_request_timeout_ms
      )

    case result do
      {:ok, %Req.Response{status: status, body: body}} when status in [200, 206] ->
        actual_bytes = body_size(body)

        if actual_bytes == expected_bytes do
          {:ok, IO.iodata_to_binary(body)}
        else
          {:error, {:range_size_mismatch, expected_bytes, actual_bytes}}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:range_get_failed, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp bounded_body(max_bytes) do
    fn {:data, data}, {req, resp} ->
      size = Map.get(resp.private, :mave_body_size, 0) + byte_size(data)
      body = [resp.body, data]
      resp = %{resp | body: body, private: Map.put(resp.private, :mave_body_size, size)}

      if size > max_bytes do
        {:halt, {req, resp}}
      else
        {:cont, {req, resp}}
      end
    end
  end

  defp body_size(body) when is_binary(body), do: byte_size(body)
  defp body_size(body), do: IO.iodata_length(body)

  defp maybe_add_content_length_header(headers, opts) do
    case Keyword.get(opts, :content_length) do
      content_length when is_integer(content_length) and content_length >= 0 ->
        [{"content-length", Integer.to_string(content_length)} | headers]

      _content_length ->
        headers
    end
  end

  defp upload_multipart_part(
         bucket,
         path,
         storage_profile,
         upload_id,
         part_number,
         body
       ) do
    headers = [{"content-length", Integer.to_string(byte_size(body))}]
    params = [{"partNumber", Integer.to_string(part_number)}, {"uploadId", upload_id}]

    result =
      build_req(bucket, storage_profile)
      |> Req.merge(retry: false)
      |> Req.Request.put_headers(headers)
      |> request_with_deadline(
        fn req -> Req.put(req, url: "/#{path}", params: params, body: body) end,
        @multipart_part_request_timeout_ms
      )

    case result do
      {:ok, %Req.Response{status: status, headers: headers}} when status in 200..299 ->
        case header_value(headers, "etag") do
          etag when is_binary(etag) and etag != "" -> {:ok, etag}
          _ -> {:error, :missing_part_etag}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:part_upload_failed, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp complete_multipart_upload(bucket, path, storage_profile, upload_id, parts) do
    body = complete_multipart_upload_xml(parts)
    params = [{"uploadId", upload_id}]

    result =
      build_req(bucket, storage_profile)
      |> Req.merge(retry: false)
      |> Req.Request.put_header("content-type", "application/xml")
      |> request_with_deadline(
        fn req ->
          Req.post(req, url: "/#{path}", params: params, body: body)
        end,
        @multipart_control_request_timeout_ms
      )

    case result do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:multipart_complete_failed, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp abort_multipart_upload(bucket, path, storage_profile, upload_id) do
    result =
      build_req(bucket, storage_profile)
      |> Req.merge(retry: false)
      |> request_with_deadline(
        fn req -> Req.delete(req, url: "/#{path}", params: [{"uploadId", upload_id}]) end,
        @multipart_control_request_timeout_ms
      )

    case result do
      {:ok, %Req.Response{status: status}} when status in 200..299 or status == 404 -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:multipart_abort_failed, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request_with_deadline(req, fun, timeout_ms) when is_function(fun, 1) do
    parent = self()
    ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        result =
          try do
            {:ok, fun.(req)}
          rescue
            error -> {:error, {:exception, Exception.message(error)}}
          catch
            kind, reason -> {:error, {kind, reason}}
          end

        send(parent, {ref, result})
      end)

    receive do
      {^ref, {:ok, result}} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {^ref, {:error, reason}} ->
        Process.demonitor(monitor_ref, [:flush])
        {:error, {:storage_request_exit, reason}}

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        {:error, {:storage_request_exit, reason}}
    after
      timeout_ms ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
        after
          0 -> :ok
        end

        {:error, {:storage_request_timeout, timeout_ms}}
    end
  end

  defp complete_multipart_upload_xml(parts) do
    part_xml =
      Enum.map_join(parts, "", fn %{part_number: part_number, etag: etag} ->
        "<Part><PartNumber>#{part_number}</PartNumber><ETag>#{xml_escape(etag)}</ETag></Part>"
      end)

    "<CompleteMultipartUpload>#{part_xml}</CompleteMultipartUpload>"
  end

  defp cross_profile_single_put_max_bytes(opts) do
    opts
    |> Keyword.get(:single_put_max_bytes, @cross_profile_single_put_max_bytes)
    |> positive_integer(@cross_profile_single_put_max_bytes)
  end

  defp server_side_copy_enabled?(opts) do
    Keyword.get(opts, :server_side_copy?, false) == true
  end

  defp server_side_copy_fallback_enabled?(opts) do
    Keyword.get(opts, :server_side_copy_fallback?, true) != false
  end

  defp server_side_copy_max_bytes(opts) do
    opts
    |> Keyword.get(:server_side_copy_max_bytes, @server_side_copy_max_bytes)
    |> positive_integer(@server_side_copy_max_bytes)
  end

  defp server_side_multipart_copy_part_size(size_bytes, opts) do
    opts
    |> Keyword.get(:server_side_part_size, @server_side_multipart_copy_part_size)
    |> positive_integer(@server_side_multipart_copy_part_size)
    |> max(@s3_min_multipart_part_size)
    |> min_multipart_part_size(size_bytes, multipart_max_parts(opts))
  end

  defp min_multipart_part_size(part_size, size_bytes, max_parts) do
    min_part_size = div(size_bytes + max_parts - 1, max_parts)

    part_size
    |> max(min_part_size)
    |> max(@s3_min_multipart_part_size)
  end

  defp multipart_copy_part_size(size_bytes, opts) do
    opts
    |> Keyword.get(:part_size, @multipart_copy_part_size)
    |> positive_integer(@multipart_copy_part_size)
    |> max(@s3_min_multipart_part_size)
    |> min_multipart_part_size(size_bytes, multipart_max_parts(opts))
  end

  defp multipart_max_parts(opts) do
    opts
    |> Keyword.get(:multipart_max_parts, @multipart_max_parts)
    |> positive_integer(@multipart_max_parts)
    |> min(@multipart_max_parts)
  end

  defp multipart_part_max_attempts(opts) do
    opts
    |> Keyword.get(:part_attempts, @multipart_part_max_attempts)
    |> positive_integer(@multipart_part_max_attempts)
  end

  defp multipart_copy_max_concurrency(opts) do
    opts
    |> Keyword.get(:part_concurrency, storage_object_max_concurrency())
    |> positive_integer(storage_object_max_concurrency())
  end

  defp list_prefix_keys(bucket, prefix, storage_profile, continuation_token \\ nil, acc \\ []) do
    params =
      [{"list-type", "2"}, {"prefix", prefix}]
      |> maybe_add_continuation_token(continuation_token)

    case Req.get(build_req(bucket, storage_profile), url: "/", params: params) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        keys = extract_xml_values(body, "Key")
        next_token = extract_xml_value(body, "NextContinuationToken")
        truncated? = extract_xml_value(body, "IsTruncated") == "true"
        all_keys = acc ++ keys

        if truncated? and is_binary(next_token) and next_token != "" do
          list_prefix_keys(bucket, prefix, storage_profile, next_token, all_keys)
        else
          {:ok, all_keys}
        end

      {:ok, %Req.Response{status: 404}} ->
        {:ok, acc}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:list_objects_failed, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delete_keys(_bucket, [], _storage_profile), do: :ok

  defp delete_keys(bucket, keys, storage_profile) do
    keys
    |> Task.async_stream(
      fn key -> {key, delete_object(bucket, key, storage_profile)} end,
      max_concurrency: storage_object_max_concurrency(),
      ordered: false,
      timeout: :infinity
    )
    |> Enum.reduce_while(:ok, fn
      {:ok, {_key, :ok}}, :ok ->
        {:cont, :ok}

      {:ok, {key, {:error, reason}}}, :ok ->
        {:halt, {:error, {:delete_object_failed, key, reason}}}

      {:exit, reason}, :ok ->
        {:halt, {:error, {:delete_object_failed, reason}}}
    end)
  end

  defp update_keys_acl(_bucket, [], _acl, _storage_profile), do: :ok

  defp update_keys_acl(bucket, keys, acl, storage_profile) do
    keys
    |> Task.async_stream(
      fn key -> {key, put_object_acl(bucket, key, acl, storage_profile)} end,
      max_concurrency: storage_object_max_concurrency(),
      ordered: false,
      timeout: :infinity
    )
    |> Enum.reduce_while(:ok, fn
      {:ok, {_key, :ok}}, :ok ->
        {:cont, :ok}

      {:ok, {key, {:error, reason}}}, :ok ->
        {:halt, {:error, {:object_acl_failed, key, reason}}}

      {:exit, reason}, :ok ->
        {:halt, {:error, {:object_acl_failed, reason}}}
    end)
  end

  defp storage_object_max_concurrency do
    case Application.get_env(:mave_core, :storage_object_max_concurrency, 8) do
      value when is_integer(value) and value > 0 -> value
      _ -> 8
    end
  end

  defp put_object_acl(bucket, key, acl, storage_profile) do
    case Req.put(build_req(bucket, storage_profile),
           url: "/#{key}?acl",
           body: "",
           headers: [{"x-amz-acl", acl}]
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status}} ->
        {:error, {:acl_failed, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_req(bucket, storage_profile) do
    config = config_for_bucket(storage_profile, bucket)
    base_url = "#{config[:endpoint]}/#{bucket}"

    Req.new(base_url: base_url)
    |> ReqS3.attach()
    |> fresh_signature_on_retry()
    |> Req.merge(
      aws_sigv4: [
        access_key_id: config[:access_key_id],
        secret_access_key: config[:secret_access_key],
        region: config[:region] || "us-east-1",
        service: "s3"
      ]
    )
  end

  # A retry must start from a new request so SigV4 headers and streamed bodies are
  # rebuilt. Retrying the same Req request after a transport timeout can replay
  # stale signing state; Scaleway then reports the retry as HTTP 403 even though
  # the credentials and bucket permissions are valid.
  defp put_object_with_retry(
         bucket,
         path,
         storage_profile,
         headers,
         body_factory,
         retry_count \\ 0
       ) do
    result =
      bucket
      |> build_req(storage_profile)
      |> Req.merge(retry: false)
      |> Req.put(url: "/#{path}", body: body_factory.(), headers: headers)

    if retry_object_put?(result) and retry_count < @object_put_max_retries do
      Logger.warning(
        "S3 PUT transient failure; retrying with a fresh signed request " <>
          "(retry #{retry_count + 1}/#{@object_put_max_retries})"
      )

      Process.sleep(object_put_retry_delay(retry_count))

      put_object_with_retry(
        bucket,
        path,
        storage_profile,
        headers,
        body_factory,
        retry_count + 1
      )
    else
      result
    end
  end

  defp retry_object_put?({:ok, %Req.Response{status: status}}),
    do: status in @object_put_transient_statuses

  defp retry_object_put?({:error, %Req.TransportError{reason: reason}}),
    do: reason in @object_request_transient_transport_reasons

  defp retry_object_put?({:error, %Req.HTTPError{protocol: :http2, reason: reason}}),
    do: reason in @object_request_transient_http2_reasons

  defp retry_object_put?(_result), do: false

  defp object_put_retry_delay(retry_count) do
    @object_put_retry_base_delay_ms
    |> Kernel.*(Integer.pow(2, retry_count))
    |> min(@object_put_retry_max_delay_ms)
  end

  defp retry_object_head?({:ok, %Req.Response{status: status}}),
    do: status in @object_head_transient_statuses

  defp retry_object_head?({:error, %Req.TransportError{reason: reason}}),
    do: reason in @object_request_transient_transport_reasons

  defp retry_object_head?({:error, %Req.HTTPError{protocol: :http2, reason: reason}}),
    do: reason in @object_request_transient_http2_reasons

  defp retry_object_head?(_result), do: false

  defp object_head_retry_delay(retry_count) do
    @object_head_retry_base_delay_ms
    |> Kernel.*(Integer.pow(2, retry_count))
    |> min(@object_head_retry_max_delay_ms)
  end

  defp build_ffmpeg_input_url(bucket, path, storage_profile) do
    encoded_path = URI.encode(path, &(URI.char_unreserved?(&1) or &1 == ?/))
    upload_config = Application.get_env(:mave_core, :upload, [])

    if bucket == config_value(upload_config, :bucket) do
      case configured_upload_storage_object_url(upload_config, encoded_path) do
        url when is_binary(url) and url != "" -> {:ok, url}
        _other -> {:error, {:missing_storage_config, :endpoint}}
      end
    else
      with {:ok, endpoint} <-
             storage_profile |> config_for_profile() |> required_storage_config(:endpoint) do
        encoded_bucket = URI.encode(bucket, &URI.char_unreserved?/1)

        {:ok, "#{String.trim_trailing(endpoint, "/")}/#{encoded_bucket}/#{encoded_path}"}
      end
    end
  end

  defp required_storage_config(config, key) do
    case config_value(config, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_storage_config, key}}
    end
  end

  defp build_service_req(storage_profile, bucket) do
    config = config_for_bucket(storage_profile, bucket)
    base_url = config[:endpoint]

    Req.new(base_url: base_url)
    |> ReqS3.attach()
    |> fresh_signature_on_retry()
    |> Req.merge(
      aws_sigv4: [
        access_key_id: config[:access_key_id],
        secret_access_key: config[:secret_access_key],
        region: config[:region] || "us-east-1",
        service: "s3"
      ]
    )
  end

  defp fresh_signature_on_retry(request) do
    # Req re-runs request steps on retry with the previous request's headers.
    # Remove only signer-owned headers before SigV4 adds the new values, or the
    # canonical request includes duplicate dates/digests and S3 rejects it.
    Req.Request.prepend_request_steps(request,
      reset_storage_signature: fn request ->
        Enum.reduce(
          ["authorization", "x-amz-date", "x-amz-content-sha256", "x-amz-security-token"],
          request,
          &Req.Request.delete_header(&2, &1)
        )
      end
    )
  end

  # Bucket-scoped credentials allow a logical storage profile to span separate
  # provider accounts. Keep naming/public URLs on the parent profile.
  defp config_for_bucket(storage_profile, bucket) do
    config = config_for_profile(storage_profile)
    overrides = config_value(config, :bucket_overrides) || %{}

    case Map.get(overrides, bucket) do
      nil -> config
      override -> Map.merge(Map.new(config), Map.new(override))
    end
  end

  defp config_for_profile(storage_profile) do
    cond do
      is_map(storage_profile) ->
        storage_profile

      Keyword.keyword?(storage_profile) ->
        storage_profile

      true ->
        providers = Application.get_env(:mave_core, :storage_providers, %{})
        profile = StorageProfiles.resolve(storage_profile)

        Map.get(providers, profile) ||
          Map.get(providers, to_string(profile)) ||
          Map.get(providers, "default") ||
          legacy_config()
    end
  end

  defp bucket_policy_dialect(storage_profile) do
    endpoint = storage_profile |> config_for_profile() |> config_value(:endpoint)

    case URI.parse(endpoint || "") do
      %URI{host: host} when is_binary(host) ->
        if String.ends_with?(String.downcase(host), ".scw.cloud"),
          do: :scaleway,
          else: :aws

      _other ->
        :aws
    end
  end

  defp ffmpeg_storage_base_urls do
    provider_urls =
      :mave_core
      |> Application.get_env(:storage_providers, %{})
      |> Map.values()
      |> Enum.map(&config_value(&1, :endpoint))

    upload_url =
      :mave_core
      |> Application.get_env(:upload, [])
      |> config_value(:source_base_url)

    legacy_url = legacy_config() |> config_value(:endpoint)

    [upload_url, legacy_url | provider_urls]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp upload_storage_uri?(%URI{} = url) do
    upload_config = Application.get_env(:mave_core, :upload, [])
    source_base_url = config_value(upload_config, :source_base_url)
    bucket = config_value(upload_config, :bucket)

    if is_binary(source_base_url) and source_base_url != "" and is_binary(bucket) and
         bucket != "" do
      object_base_url =
        String.trim_trailing(source_base_url, "/") <>
          "/" <> URI.encode(bucket)

      url_belongs_to_base?(url, object_base_url)
    else
      false
    end
  end

  defp url_belongs_to_base?(url, base_url) do
    case URI.parse(base_url) do
      %URI{scheme: scheme, host: host} = base
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        String.downcase(url.scheme) == String.downcase(scheme) and
          String.downcase(url.host) == String.downcase(host) and
          effective_port(url) == effective_port(base) and
          path_has_prefix?(url.path, base.path)

      _other ->
        false
    end
  end

  defp effective_port(%URI{port: port}) when is_integer(port), do: port
  defp effective_port(%URI{scheme: "https"}), do: 443
  defp effective_port(%URI{scheme: "http"}), do: 80
  defp effective_port(_uri), do: nil

  defp path_has_prefix?(url_path, base_path) do
    normalized_url_path = url_path || "/"
    normalized_base_path = (base_path || "/") |> String.trim_trailing("/")

    normalized_base_path == "" or normalized_base_path == "/" or
      normalized_url_path == normalized_base_path or
      String.starts_with?(normalized_url_path, normalized_base_path <> "/")
  end

  defp same_storage_backend?(left_profile, left_bucket, right_profile, right_bucket) do
    storage_backend_identity(config_for_bucket(left_profile, left_bucket)) ==
      storage_backend_identity(config_for_bucket(right_profile, right_bucket))
  end

  defp storage_profile_name(storage_profile)
       when is_nil(storage_profile) or is_atom(storage_profile) or is_binary(storage_profile),
       do: StorageProfiles.resolve(storage_profile)

  defp storage_profile_name(_storage_profile), do: nil

  defp storage_backend_identity(storage_profile) do
    config = config_for_profile(storage_profile)

    %{
      endpoint: config_value(config, :endpoint) |> normalize_endpoint(),
      access_key_id: config_value(config, :access_key_id),
      secret_access_key: config_value(config, :secret_access_key),
      region: config_value(config, :region) || "us-east-1",
      bucket_prefix: config_value(config, :bucket_prefix) || "space-"
    }
  end

  defp config_value(config, key) when is_map(config) do
    Map.get(config, key) || Map.get(config, to_string(key))
  end

  defp config_value(config, key) when is_list(config) do
    case Keyword.fetch(config, key) do
      {:ok, value} ->
        value

      :error ->
        case List.keyfind(config, to_string(key), 0) do
          {_key, value} -> value
          nil -> nil
        end
    end
  end

  defp config_value(_config, _key), do: nil

  defp public_bucket_alias(config) do
    bucket_prefix = config_value(config, :bucket_prefix)
    public_prefix = config_value(config, :public_bucket_prefix)

    if is_binary(bucket_prefix) and bucket_prefix != "" and is_binary(public_prefix) and
         public_prefix != "" and bucket_prefix != public_prefix do
      [{bucket_prefix, public_prefix}]
    else
      []
    end
  end

  defp space_bucket_with_prefix?(bucket, prefix) do
    suffix = String.replace_prefix(bucket, prefix, "")
    suffix != bucket and String.match?(suffix, @space_hash_pattern)
  end

  defp normalize_endpoint(nil), do: nil

  defp normalize_endpoint(endpoint) do
    endpoint
    |> to_string()
    |> String.trim()
    |> String.trim_trailing("/")
  end

  # Fallback to legacy :s3 config or MinIO defaults for dev
  defp legacy_config do
    Application.get_env(:mave_core, :s3) ||
      [
        access_key_id: "minioadmin",
        secret_access_key: "minioadmin",
        endpoint: "http://localhost:9000",
        region: "us-east-1",
        bucket_prefix: "space-"
      ]
  end

  defp handle_response({:ok, %{status: status} = resp}) when status in 200..299 do
    {:ok, resp.body}
  end

  defp handle_response({:ok, %{status: 404}}) do
    {:error, :not_found}
  end

  defp handle_response({:ok, resp}) do
    {:error, "S3 error: #{resp.status}"}
  end

  defp handle_response({:error, reason}) do
    {:error, reason}
  end

  defp extract_content_type(headers) when is_map(headers),
    do: headers |> header_value("content-type") |> normalize_content_type()

  defp extract_content_type(headers) when is_list(headers),
    do: headers |> header_value("content-type") |> normalize_content_type()

  defp extract_content_type(_), do: nil

  defp parse_content_length(headers) when is_map(headers),
    do: headers |> header_value("content-length") |> parse_integer_header()

  defp parse_content_length(headers) when is_list(headers),
    do: headers |> header_value("content-length") |> parse_integer_header()

  defp parse_content_length(_), do: nil

  defp header_value(headers, name) when is_map(headers) do
    headers
    |> Enum.to_list()
    |> header_value(name)
  end

  defp header_value(headers, name) when is_list(headers) and is_binary(name) do
    normalized_name = String.downcase(name)

    Enum.find_value(headers, fn
      {key, value} when is_binary(key) ->
        if String.downcase(key) == normalized_name, do: normalize_header_value(value)

      _ ->
        nil
    end)
  end

  defp header_value(_headers, _name), do: nil

  defp normalize_header_value([value | _]), do: normalize_header_value(value)
  defp normalize_header_value(value) when is_binary(value), do: value
  defp normalize_header_value(value) when is_list(value), do: List.to_string(value)
  defp normalize_header_value(value), do: to_string(value)

  defp parse_integer_header(value) when is_list(value),
    do: value |> to_string() |> parse_integer_header()

  defp parse_integer_header(value) when is_binary(value) do
    value
    |> String.trim()
    |> Integer.parse()
    |> case do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_integer_header(_), do: nil

  defp positive_integer(value, _fallback) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, fallback) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> fallback
    end
  end

  defp positive_integer(_value, fallback), do: fallback

  defp normalize_content_type(value) when is_binary(value) do
    value
    |> String.split(";")
    |> List.first()
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_content_type(_), do: nil

  defp maybe_add_continuation_token(params, nil), do: params
  defp maybe_add_continuation_token(params, ""), do: params
  defp maybe_add_continuation_token(params, token), do: params ++ [{"continuation-token", token}]

  defp extract_xml_values(body, tag) when is_binary(body) do
    regex = ~r/<#{tag}>(.*?)<\/#{tag}>/s

    Regex.scan(regex, body, capture: :all_but_first)
    |> Enum.map(fn [value] -> xml_unescape(value) end)
  end

  defp extract_xml_value(body, tag) when is_binary(body) do
    case extract_xml_values(body, tag) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp xml_unescape(value) do
    value
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
    |> String.replace("&amp;", "&")
  end

  defp maybe_add_public_read_header(headers, storage_profile, opts) do
    if Keyword.get(opts, :public, false) and public_read_acl_enabled_for_profile?(storage_profile) do
      headers ++ [{"x-amz-acl", "public-read"}]
    else
      headers
    end
  end

  defp copy_source_header(bucket, path) do
    encoded_path =
      path
      |> String.split("/", trim: false)
      |> Enum.map_join("/", &URI.encode/1)

    "/#{bucket}/#{encoded_path}"
  end

  defp public_read_acl_enabled_for_profile?(storage_profile) do
    object_acl_enabled_for_profile?(storage_profile)
  end

  defp object_acl_enabled_for_profile?(storage_profile) do
    config = config_for_profile(storage_profile)

    case config_value(config, :object_acl) do
      true ->
        true

      false ->
        false

      _other ->
        case storage_profile_name(storage_profile) do
          profile when is_binary(profile) -> profile in object_acl_profiles()
          _profile -> false
        end
    end
  end

  defp object_acl_profiles do
    :mave_core
    |> Application.get_env(:object_acl_storage_profiles, @default_object_acl_profiles)
    |> List.wrap()
    |> Enum.map(&StorageProfiles.resolve/1)
  end
end
