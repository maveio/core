defmodule MaveCore.EncodingBooster.ProgressStream do
  @moduledoc false

  defstruct [:stream, :on_chunk]
end

defimpl Collectable, for: MaveCore.EncodingBooster.ProgressStream do
  def into(%{stream: stream, on_chunk: on_chunk}) do
    {initial_acc, collector} = Collectable.into(stream)

    wrapped_collector = fn
      {acc, total_bytes}, {:cont, data} ->
        total_bytes = total_bytes + IO.iodata_length(data)
        notify(on_chunk, total_bytes)
        {collector.(acc, {:cont, data}), total_bytes}

      {acc, _total_bytes}, :done ->
        collector.(acc, :done)

      {acc, _total_bytes}, :halt ->
        collector.(acc, :halt)
    end

    {{initial_acc, 0}, wrapped_collector}
  end

  defp notify(on_chunk, total_bytes) when is_function(on_chunk, 1) do
    on_chunk.(total_bytes)
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp notify(_on_chunk, _total_bytes), do: :ok
end

defmodule MaveCore.EncodingBooster.ProgressEvents do
  @moduledoc false

  defstruct [:on_chunk]
end

defimpl Collectable, for: MaveCore.EncodingBooster.ProgressEvents do
  def into(%{on_chunk: on_chunk}) do
    {initial_acc, collector} = Collectable.into("")

    wrapped_collector = fn
      {acc, buffered}, {:cont, data} ->
        {lines, buffered} = complete_lines(buffered <> IO.iodata_to_binary(data))
        Enum.each(lines, &notify(&1, on_chunk))
        {collector.(acc, {:cont, data}), buffered}

      {acc, buffered}, :done ->
        if buffered != "", do: notify(buffered, on_chunk)
        collector.(acc, :done)

      {acc, _buffered}, :halt ->
        collector.(acc, :halt)
    end

    {{initial_acc, ""}, wrapped_collector}
  end

  defp complete_lines(data) do
    case String.split(data, "\n") do
      [buffered] -> {[], buffered}
      parts -> {Enum.drop(parts, -1), List.last(parts)}
    end
  end

  defp notify(line, on_chunk) when is_function(on_chunk, 1) do
    with {:ok, %{"uploaded_bytes" => bytes}} <- Jason.decode(line),
         true <- is_integer(bytes) and bytes >= 0 do
      on_chunk.(bytes)
    else
      _other -> :ok
    end
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp notify(_line, _on_chunk), do: :ok
end

defmodule MaveCore.EncodingBooster.Faststart do
  @moduledoc false

  alias MaveCore.Flow.Steps.Support, as: StepSupport
  alias MaveCore.SafeFile

  @spec remux(String.t(), keyword()) ::
          {:ok, %{size_bytes: non_neg_integer()}} | {:error, term()}
  def remux(input_path, opts \\ []) when is_binary(input_path) and is_list(opts) do
    output_path = remux_output_path(input_path)

    try do
      with {:ok, ffmpeg_bin} <- ffmpeg_executable(opts),
           :ok <- run_remux(ffmpeg_bin, input_path, output_path, opts),
           {:ok, size_bytes} <- remuxed_size(output_path),
           :ok <- replace_input(output_path, input_path) do
        {:ok, %{size_bytes: size_bytes}}
      end
    after
      _ = SafeFile.rm(output_path)
    end
  end

  defp ffmpeg_executable(opts) do
    case Keyword.get(opts, :ffmpeg_bin) do
      nil ->
        case StepSupport.find_ffmpeg() do
          {:ok, ffmpeg_bin} -> {:ok, ffmpeg_bin}
          {:error, :ffmpeg_not_found} -> {:error, :encoding_booster_ffmpeg_not_found}
        end

      ffmpeg_bin when is_binary(ffmpeg_bin) and ffmpeg_bin != "" ->
        {:ok, ffmpeg_bin}

      _other ->
        {:error, :encoding_booster_ffmpeg_not_found}
    end
  end

  defp run_remux(ffmpeg_bin, input_path, output_path, opts) do
    args = [
      "-hide_banner",
      "-nostdin",
      "-y",
      "-loglevel",
      "error",
      "-i",
      input_path,
      "-map",
      "0:v:0",
      "-map",
      "0:a?",
      "-c",
      "copy",
      "-movflags",
      "+faststart",
      output_path
    ]

    runner = Keyword.get(opts, :runner, &StepSupport.run_media_cmd/2)

    case runner.(ffmpeg_bin, args) do
      {_output, 0} ->
        :ok

      {_output, status} when is_integer(status) ->
        {:error, {:encoding_booster_remux_failed, status}}

      {:error, reason} ->
        {:error, {:encoding_booster_remux_failed, reason}}

      _other ->
        {:error, :encoding_booster_remux_failed}
    end
  end

  defp remuxed_size(output_path) do
    case SafeFile.stat_regular(output_path) do
      {:ok, %{size: size}} when size > 0 -> {:ok, size}
      {:ok, %{size: 0}} -> {:error, :encoding_booster_empty_remux}
      {:error, reason} -> {:error, {:encoding_booster_remux_failed, reason}}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp replace_input(output_path, input_path) do
    with {:ok, safe_output_path} <- SafeFile.readable_path(output_path),
         {:ok, safe_input_path} <- SafeFile.writable_path(input_path) do
      case File.rename(safe_output_path, safe_input_path) do
        :ok -> :ok
        {:error, reason} -> {:error, {:encoding_booster_remux_failed, reason}}
      end
    end
  end

  defp remux_output_path(input_path) do
    input_path <> ".faststart-#{System.unique_integer([:positive])}.mp4"
  end
end

defmodule MaveCore.EncodingBooster do
  @moduledoc """
  Streams an eligible FFmpeg encode through an external CPU or GPU booster.

  Availability is controlled at deployment level. Callers remain responsible
  for validating the returned media and may fall back to the regular FLAME
  executor when fallback is enabled.
  """

  alias MaveCore.EncodingBooster.{Bundle, Faststart, ProgressEvents, ProgressStream}
  alias MaveCore.GpuEncodingBoosterScaler
  alias MaveCore.Media.Storage
  alias MaveCore.{PublicHttpUrl, SafeFile}

  require Logger

  @default_connect_timeout_ms 10_000
  @default_receive_timeout_ms :timer.hours(1)
  @default_readiness_timeout_ms 1_000
  @default_cpu_warmup_requests 12
  @default_gpu_warmup_requests 1
  @max_warmup_requests 12
  # A held request gives the Serverless autoscaler enough sustained concurrent
  # demand to create separate instances before the upload finishes.
  @default_cpu_warmup_hold_ms 15_000
  @max_warmup_hold_ms 30_000
  @default_retry_backoff_ms [1_000, 2_000, 4_000, 8_000, 15_000]
  @default_busy_retry_backoff_ms [250, 500, 1_000, 2_000, 4_000]
  @default_retry_jitter_ms 500
  @retryable_statuses [429, 500, 502, 503, 504]
  @instance_id_pattern ~r/\A[a-zA-Z0-9_-]{1,64}\z/
  @payload_options [
    :input_referer,
    :encoding_profile,
    :operation,
    :codec,
    :audio_codec,
    :audio_stream_index,
    :frame_role,
    :frame_codec,
    :width,
    :video_bitrate,
    :video_crf,
    :svt_av1_params,
    :audio_bitrate,
    :preset,
    :tune,
    :include_audio,
    :keyframe_interval_seconds,
    :gop_frames,
    :start_seconds,
    :duration_seconds,
    :max_duration_seconds,
    :count,
    :package_hls
  ]

  @spec enabled?() :: boolean()
  def enabled? do
    enabled?(:cpu)
  end

  @spec enabled?(:cpu | :gpu) :: boolean()
  def enabled?(profile) when profile in [:cpu, :gpu] do
    config_value(profile, :enabled, false) in [true, "true", "1", 1]
  end

  @spec fallback_enabled?() :: boolean()
  def fallback_enabled? do
    fallback_enabled?(:cpu)
  end

  @spec fallback_enabled?(:cpu | :gpu) :: boolean()
  def fallback_enabled?(profile) when profile in [:cpu, :gpu] do
    config_value(profile, :fallback_enabled, true) in [true, "true", "1", 1]
  end

  @spec transient_error?(term()) :: boolean()
  def transient_error?(:encoding_booster_busy), do: true
  def transient_error?(:encoding_booster_not_ready), do: true
  def transient_error?({:encoding_booster_not_ready, _status}), do: true

  def transient_error?({:encoding_booster_http_status, status}),
    do: status in @retryable_statuses

  def transient_error?({:encoding_booster_http_status, status, detail}),
    do: status in @retryable_statuses and not terminal_source_error_detail?(detail)

  def transient_error?(:encoding_booster_request_failed), do: true
  def transient_error?({:encoding_booster_request_failed, %Req.TransportError{}}), do: true

  def transient_error?({:encoding_booster_chunk_failed, _index, reason}),
    do: transient_error?(reason)

  def transient_error?(:encoding_booster_empty_response), do: true
  def transient_error?(:encoding_booster_incomplete_storage_upload), do: true

  def transient_error?({:encoding_booster_remote_failed, detail}),
    do: not terminal_source_error_detail?(detail)

  def transient_error?(:invalid_encoding_booster_bundle), do: true
  def transient_error?(:incomplete_encoding_booster_bundle), do: true
  def transient_error?({:invalid_encoding_booster_bundle, _reason}), do: true
  def transient_error?(_reason), do: false

  @doc """
  Starts enabled boosters in the background while a user is still uploading.

  Warmup is deliberately best-effort: it never delays or rejects an upload.
  """
  @spec warmup_async(String.t() | nil) :: :ok
  def warmup_async(space_hash) when is_binary(space_hash) do
    profiles = Enum.filter([:cpu, :gpu], &enabled?/1)

    if profiles != [] do
      _ =
        Task.start(fn ->
          maybe_scale_gpu(profiles)

          warmup_targets = Enum.flat_map(profiles, &profile_warmup_targets/1)

          warmup_targets
          |> Task.async_stream(&warmup/1,
            max_concurrency: length(warmup_targets),
            ordered: false,
            timeout: 90_000,
            on_timeout: :kill_task
          )
          |> Stream.run()
        end)
    end

    :ok
  end

  def warmup_async(_space_hash), do: :ok

  defp profile_warmup_targets(profile) do
    List.duplicate(profile, warmup_requests(profile))
  end

  defp warmup_requests(:cpu) do
    :cpu
    |> config_value(:warmup_requests, @default_cpu_warmup_requests)
    |> positive_integer(@default_cpu_warmup_requests)
    |> min(@max_warmup_requests)
  end

  defp warmup_requests(:gpu) do
    :gpu
    |> config_value(:warmup_requests, @default_gpu_warmup_requests)
    |> positive_integer(@default_gpu_warmup_requests)
    |> min(@max_warmup_requests)
  end

  @spec warmup(:cpu | :gpu) :: :ok | {:error, term()}
  def warmup(profile) when profile in [:cpu, :gpu] do
    with :ok <- ensure_enabled(profile),
         {:ok, endpoint, headers} <- configured_credentials(profile),
         {:ok, request_options} <-
           request_transport_options(profile, warmup_url(profile, endpoint),
             method: :get,
             headers: headers,
             retry: false,
             receive_timeout: 75_000,
             connect_options: [timeout: @default_connect_timeout_ms]
           ) do
      case Req.request(request_options) do
        {:ok, %Req.Response{status: status}} when status in 200..299 ->
          :ok

        {:ok, %Req.Response{status: status}} ->
          {:error, {:encoding_booster_warmup_status, status}}

        {:error, reason} ->
          {:error, {:encoding_booster_warmup_failed, reason}}
      end
    end
  rescue
    _error -> {:error, :encoding_booster_warmup_failed}
  catch
    _kind, _reason -> {:error, :encoding_booster_warmup_failed}
  end

  @spec encode_to_file(String.t(), String.t(), keyword()) ::
          {:ok, %{elapsed_ms: non_neg_integer(), size_bytes: non_neg_integer()}}
          | {:error, term()}
  def encode_to_file(input_url, output_path, opts \\ [])

  def encode_to_file(input_url, output_path, opts)
      when is_binary(input_url) and is_binary(output_path) and is_list(opts) do
    profile = Keyword.get(opts, :booster, :cpu)
    request_output_path = request_output_path(output_path, opts)

    with :ok <- validate_profile(profile),
         :ok <- ensure_enabled(profile),
         {:ok, endpoint, headers} <- configured_credentials(profile),
         :ok <- validate_https_input(input_url),
         :ok <- ensure_ready(profile, endpoint, headers),
         {:ok, request_options} <-
           request_options(profile, endpoint, headers, input_url, request_output_path, opts) do
      started_at = System.monotonic_time(:millisecond)

      result = request_with_retries(profile, request_options, request_output_path)
      handle_response(result, request_output_path, output_path, started_at, opts)
    end
  rescue
    _error ->
      _ = SafeFile.rm(output_path)
      _ = SafeFile.rm(request_output_path(output_path, opts))
      {:error, :encoding_booster_request_failed}
  catch
    _kind, _reason ->
      _ = SafeFile.rm(output_path)
      _ = SafeFile.rm(request_output_path(output_path, opts))
      {:error, :encoding_booster_request_failed}
  end

  def encode_to_file(_input_url, _output_path, _opts),
    do: {:error, :invalid_encoding_booster_request}

  @doc """
  Encodes directly into an object-storage multipart upload.

  The upload payload contains only short-lived signed operation URLs. Media
  bytes never pass through, or land on disk in, the calling application node.
  """
  @spec encode_to_storage(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def encode_to_storage(input_url, output_upload, opts \\ [])

  def encode_to_storage(input_url, output_upload, opts)
      when is_binary(input_url) and is_map(output_upload) and is_list(opts) do
    profile = Keyword.get(opts, :booster, :cpu)

    with :ok <- validate_profile(profile),
         :ok <- ensure_enabled(profile),
         {:ok, endpoint, headers} <- configured_credentials(profile),
         :ok <- validate_https_input(input_url),
         :ok <- ensure_ready(profile, endpoint, headers),
         {:ok, request_options} <-
           storage_request_options(
             profile,
             encode_url(endpoint),
             headers,
             request_payload(input_url, opts) |> Map.put("output_upload", output_upload),
             opts
           ) do
      started_at = System.monotonic_time(:millisecond)
      handle_storage_response(Req.request(request_options), started_at)
    end
  rescue
    _error -> {:error, :encoding_booster_request_failed}
  catch
    _kind, _reason -> {:error, :encoding_booster_request_failed}
  end

  def encode_to_storage(_input_url, _output_upload, _opts),
    do: {:error, :invalid_encoding_booster_request}

  @doc """
  Encodes a bounded set of named assets directly into independent object-storage
  multipart uploads during one booster request.
  """
  @spec encode_many_to_storage(String.t(), [map()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def encode_many_to_storage(input_url, output_uploads, opts \\ [])

  def encode_many_to_storage(input_url, output_uploads, opts)
      when is_binary(input_url) and is_list(output_uploads) and output_uploads != [] and
             is_list(opts) do
    profile = Keyword.get(opts, :booster, :cpu)

    with :ok <- validate_profile(profile),
         :ok <- ensure_enabled(profile),
         {:ok, endpoint, headers} <- configured_credentials(profile),
         :ok <- validate_https_input(input_url),
         :ok <- ensure_ready(profile, endpoint, headers),
         {:ok, request_options} <-
           storage_request_options(
             profile,
             encode_url(endpoint),
             headers,
             request_payload(input_url, opts) |> Map.put("output_uploads", output_uploads),
             opts
           ) do
      started_at = System.monotonic_time(:millisecond)
      handle_storage_response(Req.request(request_options), started_at)
    end
  rescue
    _error -> {:error, :encoding_booster_request_failed}
  catch
    _kind, _reason -> {:error, :encoding_booster_request_failed}
  end

  def encode_many_to_storage(_input_url, _output_uploads, _opts),
    do: {:error, :invalid_encoding_booster_request}

  @doc "Streams a remote source byte-for-byte into an object-storage multipart upload."
  @spec transfer_to_storage(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def transfer_to_storage(input_url, output_upload, opts \\ [])

  def transfer_to_storage(input_url, output_upload, opts)
      when is_binary(input_url) and is_map(output_upload) and is_list(opts) do
    profile = :cpu

    with :ok <- ensure_enabled(profile),
         {:ok, endpoint, headers} <- configured_credentials(profile),
         {:ok, input_url, input_basic_auth} <- prepare_transfer_input(input_url),
         :ok <- validate_https_input(input_url),
         :ok <- ensure_ready(profile, endpoint, headers),
         payload <-
           %{"input_url" => input_url, "output_upload" => output_upload}
           |> maybe_put_payload_value("input_referer", Keyword.get(opts, :input_referer))
           |> maybe_put_payload_value("input_basic_auth", input_basic_auth),
         {:ok, request_options} <-
           storage_request_options(
             profile,
             transfer_url(endpoint),
             headers,
             payload,
             opts
           ) do
      started_at = System.monotonic_time(:millisecond)
      handle_storage_response(Req.request(request_options), started_at)
    end
  rescue
    _error -> {:error, :encoding_booster_request_failed}
  catch
    _kind, _reason -> {:error, :encoding_booster_request_failed}
  end

  def transfer_to_storage(_input_url, _output_upload, _opts),
    do: {:error, :invalid_encoding_booster_request}

  @doc "Concatenates remote fragmented MP4 chunks into a remote MP4 object."
  @spec concat_to_storage([String.t()], map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def concat_to_storage(input_urls, output_upload, opts \\ [])

  def concat_to_storage(input_urls, output_upload, opts)
      when is_list(input_urls) and is_map(output_upload) and is_list(opts) do
    profile = :cpu

    with true <- length(input_urls) >= 2,
         true <- Enum.all?(input_urls, &(is_binary(&1) and validate_https_input(&1) == :ok)),
         :ok <- ensure_enabled(profile),
         {:ok, endpoint, headers} <- configured_credentials(profile),
         :ok <- ensure_ready(profile, endpoint, headers),
         payload <-
           %{"input_urls" => input_urls, "output_upload" => output_upload}
           |> maybe_put_payload_value("input_referer", Keyword.get(opts, :input_referer)),
         {:ok, request_options} <-
           storage_request_options(
             profile,
             concat_url(endpoint),
             headers,
             payload,
             opts
           ) do
      started_at = System.monotonic_time(:millisecond)
      handle_storage_response(Req.request(request_options), started_at)
    else
      false -> {:error, :invalid_encoding_booster_request}
      {:error, _reason} = error -> error
    end
  rescue
    _error -> {:error, :encoding_booster_request_failed}
  catch
    _kind, _reason -> {:error, :encoding_booster_request_failed}
  end

  def concat_to_storage(_input_urls, _output_upload, _opts),
    do: {:error, :invalid_encoding_booster_request}

  @doc """
  Packages an already encoded MP4 and publishes every HLS object directly from
  the CPU booster to object storage.

  `upload_token` authorizes the booster to request short-lived, per-object PUT
  URLs as FFmpeg finalizes segment names and sizes. The booster publishes the
  init file and playlist last, and the application receives metadata only.
  """
  @spec package_hls_to_storage(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def package_hls_to_storage(input_url, upload_token, opts \\ [])

  def package_hls_to_storage(input_url, upload_token, opts)
      when is_binary(input_url) and is_binary(upload_token) and upload_token != "" and
             is_list(opts) do
    profile = :cpu

    with :ok <- ensure_enabled(profile),
         {:ok, endpoint, headers} <- configured_credentials(profile),
         :ok <- validate_https_input(input_url),
         :ok <- ensure_ready(profile, endpoint, headers),
         payload <-
           %{"input_url" => input_url, "upload_token" => upload_token}
           |> maybe_put_payload_value("input_referer", Keyword.get(opts, :input_referer))
           |> maybe_put_payload_value("media_kind", Keyword.get(opts, :media_kind))
           |> maybe_put_payload_value("channels", Keyword.get(opts, :channels)),
         {:ok, request_options} <-
           storage_request_options(
             profile,
             package_hls_url(endpoint),
             headers,
             payload,
             opts
           ) do
      started_at = System.monotonic_time(:millisecond)
      handle_hls_storage_response(Req.request(request_options), started_at)
    end
  rescue
    _error -> {:error, :encoding_booster_request_failed}
  catch
    _kind, _reason -> {:error, :encoding_booster_request_failed}
  end

  def package_hls_to_storage(_input_url, _upload_token, _opts),
    do: {:error, :invalid_encoding_booster_request}

  @doc """
  Packages an already encoded MP4 into HLS on the CPU booster.

  The input is read directly over HTTPS and the HLS-only ZIP response is
  streamed to disk before its validated files are extracted.
  """
  @spec package_hls_to_dir(String.t(), String.t(), keyword()) ::
          {:ok, %{hls_dir: String.t(), elapsed_ms: non_neg_integer()}} | {:error, term()}
  def package_hls_to_dir(input_url, extract_root, opts \\ [])

  def package_hls_to_dir(input_url, extract_root, opts)
      when is_binary(input_url) and is_binary(extract_root) and is_list(opts) do
    profile = :cpu
    bundle_path = extract_root <> ".zip"

    with :ok <- ensure_enabled(profile),
         {:ok, endpoint, headers} <- configured_credentials(profile),
         :ok <- validate_https_input(input_url),
         :ok <- ensure_ready(profile, endpoint, headers),
         {:ok, request_options} <-
           package_hls_request_options(
             profile,
             endpoint,
             headers,
             input_url,
             bundle_path,
             opts
           ) do
      started_at = System.monotonic_time(:millisecond)
      result = request_with_retries(profile, request_options, bundle_path)
      handle_package_hls_response(result, bundle_path, extract_root, started_at)
    end
  rescue
    _error ->
      cleanup_package_hls_files(extract_root <> ".zip", extract_root)
      {:error, :encoding_booster_request_failed}
  catch
    _kind, _reason ->
      cleanup_package_hls_files(extract_root <> ".zip", extract_root)
      {:error, :encoding_booster_request_failed}
  end

  def package_hls_to_dir(_input_url, _extract_root, _opts),
    do: {:error, :invalid_encoding_booster_request}

  defp validate_profile(profile) when profile in [:cpu, :gpu], do: :ok
  defp validate_profile(_profile), do: {:error, :invalid_encoding_booster_profile}

  defp ensure_enabled(profile) do
    if enabled?(profile), do: :ok, else: {:error, :encoding_booster_disabled}
  end

  defp configured_credentials(:cpu) do
    endpoint = config_value(:cpu, :endpoint)
    iam_secret_key = config_value(:cpu, :iam_secret_key)

    cond do
      not present?(endpoint) -> {:error, :encoding_booster_endpoint_missing}
      not present?(iam_secret_key) -> {:error, :encoding_booster_iam_secret_key_missing}
      true -> validate_endpoint(:cpu, String.trim(endpoint), iam_secret_key)
    end
  end

  defp configured_credentials(:gpu) do
    endpoint = config_value(:gpu, :endpoint)
    bearer_token = config_value(:gpu, :bearer_token)

    cond do
      not present?(endpoint) -> {:error, :encoding_booster_endpoint_missing}
      not present?(bearer_token) -> {:error, :encoding_booster_bearer_token_missing}
      true -> validate_endpoint(:gpu, String.trim(endpoint), bearer_token)
    end
  end

  defp validate_endpoint(:cpu, endpoint, iam_secret_key) do
    case URI.parse(endpoint) do
      %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil}
      when is_binary(host) and host != "" ->
        {:ok, endpoint, [{"x-auth-token", iam_secret_key}, {"accept", "video/mp4"}]}

      _ ->
        {:error, :encoding_booster_endpoint_must_be_https}
    end
  end

  defp validate_endpoint(:gpu, endpoint, bearer_token) do
    case URI.parse(endpoint) do
      %URI{scheme: "http", host: host, userinfo: nil, query: nil, fragment: nil}
      when is_binary(host) and host != "" ->
        if private_ipv4?(host) do
          {:ok, endpoint, [{"authorization", "Bearer #{bearer_token}"}, {"accept", "video/mp4"}]}
        else
          {:error, :gpu_encoding_booster_endpoint_must_be_private_http}
        end

      _ ->
        {:error, :gpu_encoding_booster_endpoint_must_be_private_http}
    end
  end

  defp request_options(profile, endpoint, headers, input_url, output_path, opts) do
    base_options = [
      method: :post,
      headers: request_headers(headers, opts),
      json: request_payload(input_url, opts),
      raw: true,
      retry: false,
      receive_timeout:
        positive_integer(
          config_value(profile, :receive_timeout_ms),
          @default_receive_timeout_ms
        ),
      connect_options: [
        timeout:
          positive_integer(
            config_value(profile, :connect_timeout_ms),
            @default_connect_timeout_ms
          )
      ]
    ]

    with {:ok, request_options} <-
           request_transport_options(profile, encode_url(endpoint), base_options) do
      progress_stream = %ProgressStream{
        stream: SafeFile.stream_write!(output_path),
        on_chunk: Keyword.get(opts, :on_chunk)
      }

      {:ok, Keyword.put(request_options, :into, progress_stream)}
    end
  end

  defp storage_request_options(profile, url, headers, payload, opts) do
    base_options = [
      method: :post,
      headers: replace_accept_header(headers, "application/x-ndjson"),
      json: payload,
      raw: true,
      retry: false,
      receive_timeout:
        positive_integer(
          config_value(profile, :receive_timeout_ms),
          @default_receive_timeout_ms
        ),
      connect_options: [
        timeout:
          positive_integer(
            config_value(profile, :connect_timeout_ms),
            @default_connect_timeout_ms
          )
      ],
      into: %ProgressEvents{on_chunk: Keyword.get(opts, :on_chunk)}
    ]

    request_transport_options(profile, url, base_options)
  end

  defp package_hls_request_options(
         profile,
         endpoint,
         headers,
         input_url,
         bundle_path,
         opts
       ) do
    payload =
      %{"input_url" => input_url}
      |> maybe_put_payload_value("input_referer", Keyword.get(opts, :input_referer))

    base_options = [
      method: :post,
      headers: replace_accept_header(headers, "application/vnd.mave.hls-bundle+zip"),
      json: payload,
      raw: true,
      retry: false,
      receive_timeout:
        positive_integer(
          config_value(profile, :receive_timeout_ms),
          @default_receive_timeout_ms
        ),
      connect_options: [
        timeout:
          positive_integer(
            config_value(profile, :connect_timeout_ms),
            @default_connect_timeout_ms
          )
      ],
      into: SafeFile.stream_write!(bundle_path)
    ]

    request_transport_options(profile, package_hls_url(endpoint), base_options)
  end

  defp maybe_put_payload_value(payload, _key, nil), do: payload
  defp maybe_put_payload_value(payload, key, value), do: Map.put(payload, key, value)

  defp prepare_transfer_input(input_url) do
    case URI.parse(input_url) do
      %URI{userinfo: nil} ->
        {:ok, input_url, nil}

      %URI{userinfo: userinfo} = uri when is_binary(userinfo) and userinfo != "" ->
        with {:ok, basic_auth} <- decode_input_basic_auth(userinfo) do
          sanitized_url =
            uri
            |> Map.put(:authority, nil)
            |> Map.put(:userinfo, nil)
            |> URI.to_string()

          {:ok, sanitized_url, basic_auth}
        end

      _other ->
        {:error, :encoding_booster_input_must_be_https}
    end
  end

  defp decode_input_basic_auth(userinfo) do
    basic_auth = URI.decode(userinfo)

    if byte_size(basic_auth) <= 4_096 and safe_basic_auth_bytes?(basic_auth) do
      {:ok, basic_auth}
    else
      {:error, :encoding_booster_input_basic_auth_invalid}
    end
  rescue
    ArgumentError -> {:error, :encoding_booster_input_basic_auth_invalid}
  end

  defp safe_basic_auth_bytes?(basic_auth) do
    basic_auth
    |> :binary.bin_to_list()
    |> Enum.all?(&(&1 >= 32 and &1 != 127))
  end

  defp replace_accept_header(headers, accept) do
    [{"accept", accept} | Enum.reject(headers, fn {name, _value} -> name == "accept" end)]
  end

  defp request_transport_options(:cpu, url, options), do: PublicHttpUrl.req_options(url, options)

  defp request_transport_options(:gpu, url, options) do
    {:ok, Keyword.put(options, :url, url)}
  end

  defp request_headers(headers, opts) do
    accept =
      cond do
        Keyword.get(opts, :operation) == "audio_peaks" -> "text/plain"
        Keyword.get(opts, :package_hls, false) -> "application/vnd.mave.encoding-bundle+zip"
        true -> "video/mp4"
      end

    [{"accept", accept} | Enum.reject(headers, fn {name, _value} -> name == "accept" end)]
  end

  # Boosters are warmed asynchronously at upload start. Do not hold a flow step
  # inside the long-running encode retry budget while capacity is still cold;
  # the caller can immediately delegate to the next executor in the chain.
  defp ensure_ready(profile, endpoint, headers) when profile in [:cpu, :gpu] do
    readiness_check_enabled? =
      config_value(profile, :readiness_check_enabled, profile == :gpu) in [true, "true", "1", 1]

    if readiness_check_enabled? do
      check_readiness(profile, endpoint, headers)
    else
      :ok
    end
  rescue
    _error -> {:error, :encoding_booster_not_ready}
  catch
    _kind, _reason -> {:error, :encoding_booster_not_ready}
  end

  defp check_readiness(profile, endpoint, headers) do
    readiness_timeout_ms =
      positive_integer(
        config_value(profile, :readiness_timeout_ms),
        @default_readiness_timeout_ms
      )

    with {:ok, request_options} <-
           request_transport_options(profile, health_url(endpoint),
             method: :get,
             headers: headers,
             retry: false,
             receive_timeout: readiness_timeout_ms,
             connect_options: [timeout: readiness_timeout_ms]
           ) do
      readiness_result(Req.request(request_options))
    end
  end

  defp readiness_result({:ok, %Req.Response{status: status}}) when status in 200..299, do: :ok

  defp readiness_result({:ok, %Req.Response{status: status}}),
    do: {:error, {:encoding_booster_not_ready, status}}

  defp readiness_result({:error, _reason}), do: {:error, :encoding_booster_not_ready}

  defp health_url(endpoint), do: String.trim_trailing(endpoint, "/") <> "/health"

  defp warmup_url(:cpu, endpoint) do
    hold_ms =
      :cpu
      |> config_value(:warmup_hold_ms, @default_cpu_warmup_hold_ms)
      |> non_negative_integer(@default_cpu_warmup_hold_ms)
      |> min(@max_warmup_hold_ms)

    if hold_ms > 0,
      do: cpu_warmup_url(endpoint) <> "?hold_ms=#{hold_ms}",
      else: cpu_warmup_url(endpoint)
  end

  defp warmup_url(:gpu, endpoint), do: health_url(endpoint)

  defp cpu_warmup_url(endpoint),
    do: String.trim_trailing(endpoint, "/") <> "/warmup"

  defp package_hls_url(endpoint), do: String.trim_trailing(endpoint, "/") <> "/package-hls"

  defp request_payload(input_url, opts) do
    opts =
      opts
      |> omit_default_codec()
      |> omit_presigned_input_referer(input_url)

    Enum.reduce(@payload_options, %{"input_url" => input_url}, fn key, payload ->
      case Keyword.fetch(opts, key) do
        {:ok, nil} -> payload
        {:ok, value} -> Map.put(payload, Atom.to_string(key), value)
        :error -> payload
      end
    end)
  end

  defp omit_presigned_input_referer(opts, input_url) do
    if Storage.presigned_storage_url?(input_url),
      do: Keyword.delete(opts, :input_referer),
      else: opts
  end

  # Older CPU booster images predate the explicit codec field and default to
  # H.264. Omitting that default keeps rolling app/booster deploys compatible.
  defp omit_default_codec(opts) do
    if Keyword.get(opts, :codec) in ["h264", :h264],
      do: Keyword.delete(opts, :codec),
      else: opts
  end

  defp request_with_retries(profile, request_options, output_path) do
    retry_delays = %{
      capacity: busy_retry_backoff_ms(profile),
      transient: retry_backoff_ms(profile)
    }

    request_with_retries(
      profile,
      request_options,
      output_path,
      retry_delays,
      %{capacity: 0, transient: 0}
    )
  end

  defp request_with_retries(
         profile,
         request_options,
         output_path,
         retry_delays,
         retry_attempts
       ) do
    result = Req.request(request_options)

    case next_retry(result, retry_delays) do
      {:retry, category, base_delay_ms, remaining_delays} ->
        _ = SafeFile.rm(output_path)
        attempt = Map.fetch!(retry_attempts, category) + 1
        delay_ms = retry_delay_ms(profile, base_delay_ms, output_path, attempt)

        Logger.warning(
          "#{booster_label(profile)} #{retry_reason(result)}; retrying in #{delay_ms}ms " <>
            "(#{retry_category_label(category)} retry #{attempt})"
        )

        Process.sleep(delay_ms)

        request_with_retries(
          profile,
          request_options,
          output_path,
          Map.put(retry_delays, category, remaining_delays),
          Map.put(retry_attempts, category, attempt)
        )

      :done ->
        result
    end
  end

  defp next_retry(result, retry_delays) do
    case retry_category(result) do
      category when category in [:capacity, :transient] ->
        case Map.fetch!(retry_delays, category) do
          [base_delay_ms | remaining_delays] ->
            {:retry, category, base_delay_ms, remaining_delays}

          [] ->
            :done
        end

      nil ->
        :done
    end
  end

  defp retry_category({:ok, %{status: 429}}), do: :capacity

  defp retry_category({:ok, %{status: status} = response}) when status in @retryable_statuses do
    if terminal_source_response?(response), do: nil, else: :transient
  end

  defp retry_category({:error, %Req.TransportError{}}), do: :transient
  defp retry_category(_result), do: nil

  defp terminal_source_response?(response) do
    response
    |> response_error_detail()
    |> terminal_source_error_detail?()
  end

  defp terminal_source_error_detail?(detail) when is_binary(detail) do
    Regex.match?(
      ~r/(?:source returned http|server returned|http error|error opening input[^\n]*)\s*:?[\s\S]{0,80}\b(?:400|401|403|404|410)\b/i,
      detail
    )
  end

  defp terminal_source_error_detail?(_detail), do: false

  defp retry_category_label(:capacity), do: "capacity"
  defp retry_category_label(:transient), do: "request"

  defp retry_reason({:ok, %{status: status}}), do: "returned HTTP #{status}"

  defp retry_reason({:error, %Req.TransportError{reason: reason}}) when is_atom(reason),
    do: "transport #{reason}"

  defp retry_reason({:error, %Req.TransportError{}}), do: "transport failure"

  defp retry_backoff_ms(profile) do
    retry_backoff_ms(profile, :retry_backoff_ms, @default_retry_backoff_ms)
  end

  defp busy_retry_backoff_ms(profile) do
    retry_backoff_ms(
      profile,
      :busy_retry_backoff_ms,
      config_value(profile, :retry_backoff_ms, @default_busy_retry_backoff_ms)
    )
  end

  defp retry_backoff_ms(profile, key, default) do
    case config_value(profile, key, default) do
      delays when is_list(delays) ->
        if Enum.all?(delays, &(is_integer(&1) and &1 >= 0)),
          do: delays,
          else: default

      _other ->
        default
    end
  end

  defp retry_delay_ms(profile, base_delay_ms, output_path, attempt) do
    jitter_ms =
      non_negative_integer(config_value(profile, :retry_jitter_ms), @default_retry_jitter_ms)

    jitter =
      if jitter_ms == 0,
        do: 0,
        else: :erlang.phash2({output_path, attempt}, jitter_ms + 1)

    base_delay_ms + jitter
  end

  defp booster_label(:gpu), do: "GPU encoding booster"
  defp booster_label(:cpu), do: "Encoding booster"

  defp handle_response(
         {:ok, %{status: status} = response},
         request_output_path,
         output_path,
         started_at,
         opts
       )
       when status in 200..299 do
    case SafeFile.stat_regular(request_output_path) do
      {:ok, %{size: size}} when size > 0 ->
        finalize_successful_response(
          request_output_path,
          output_path,
          started_at,
          response,
          opts
        )

      _ ->
        cleanup_response_files(request_output_path, output_path)
        {:error, :encoding_booster_empty_response}
    end
  end

  defp handle_response(
         {:ok, %{status: 429}},
         request_output_path,
         output_path,
         _elapsed_ms,
         _opts
       ) do
    cleanup_response_files(request_output_path, output_path)
    {:error, :encoding_booster_busy}
  end

  defp handle_response(
         {:ok, %{status: status} = response},
         request_output_path,
         output_path,
         _elapsed_ms,
         _opts
       ) do
    detail = response_error_detail(response)
    cleanup_response_files(request_output_path, output_path)

    if is_binary(detail),
      do: {:error, {:encoding_booster_http_status, status, detail}},
      else: {:error, {:encoding_booster_http_status, status}}
  end

  defp handle_response(
         {:error, reason},
         request_output_path,
         output_path,
         _elapsed_ms,
         _opts
       ) do
    cleanup_response_files(request_output_path, output_path)
    {:error, {:encoding_booster_request_failed, reason}}
  end

  defp handle_storage_response({:ok, %{status: status} = response}, started_at)
       when status in 200..299 do
    with {:ok, events} <- decode_storage_events(response.body),
         %{"status" => "completed", "size_bytes" => size_bytes} = completed <-
           List.last(events),
         true <- is_integer(size_bytes) and size_bytes > 0 do
      metadata =
        %{
          elapsed_ms: System.monotonic_time(:millisecond) - started_at,
          size_bytes: size_bytes,
          output_bytes: size_bytes
        }
        |> maybe_put_event_integer(completed, :ffmpeg_elapsed_ms, "ffmpeg_elapsed_ms")
        |> maybe_put_event_string(completed, :sha256, "sha256")
        |> put_storage_event_metrics(Map.get(completed, "metrics", %{}))
        |> maybe_put_instance_id(response)

      {:ok, metadata}
    else
      %{"status" => "failed", "error" => detail} when is_binary(detail) ->
        {:error, {:encoding_booster_remote_failed, String.slice(detail, 0, 500)}}

      _other ->
        {:error, :encoding_booster_incomplete_storage_upload}
    end
  end

  defp handle_storage_response({:ok, %{status: 429}}, _started_at),
    do: {:error, :encoding_booster_busy}

  defp handle_storage_response({:ok, %{status: status} = response}, _started_at) do
    case response_error_detail(response) do
      detail when is_binary(detail) ->
        {:error, {:encoding_booster_http_status, status, detail}}

      _other ->
        {:error, {:encoding_booster_http_status, status}}
    end
  end

  defp handle_storage_response({:error, reason}, _started_at),
    do: {:error, {:encoding_booster_request_failed, reason}}

  defp handle_hls_storage_response({:ok, %{status: status} = response}, started_at)
       when status in 200..299 do
    with {:ok, events} <- decode_storage_events(response.body),
         %{"status" => "completed", "files" => files} = completed <- List.last(events),
         true <- is_list(files) and files != [],
         {:ok, normalized_files} <- normalize_hls_files(files) do
      total_size = Enum.reduce(normalized_files, 0, &(&1["file_size"] + &2))

      metadata =
        %{
          elapsed_ms: System.monotonic_time(:millisecond) - started_at,
          files: normalized_files,
          size_bytes: total_size,
          output_bytes: total_size
        }
        |> maybe_put_event_integer(completed, :ffmpeg_elapsed_ms, "ffmpeg_elapsed_ms")
        |> maybe_put_instance_id(response)

      {:ok, metadata}
    else
      %{"status" => "failed", "error" => detail} when is_binary(detail) ->
        {:error, {:encoding_booster_remote_failed, String.slice(detail, 0, 500)}}

      _other ->
        {:error, :encoding_booster_incomplete_storage_upload}
    end
  end

  defp handle_hls_storage_response({:ok, %{status: 429}}, _started_at),
    do: {:error, :encoding_booster_busy}

  defp handle_hls_storage_response({:ok, %{status: status} = response}, _started_at) do
    case response_error_detail(response) do
      detail when is_binary(detail) ->
        {:error, {:encoding_booster_http_status, status, detail}}

      _other ->
        {:error, {:encoding_booster_http_status, status}}
    end
  end

  defp handle_hls_storage_response({:error, reason}, _started_at),
    do: {:error, {:encoding_booster_request_failed, reason}}

  defp normalize_hls_files(files) do
    files
    |> Enum.reduce_while({:ok, []}, &normalize_hls_file/2)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_hls_file(
         %{
           "name" => name,
           "key" => key,
           "size_bytes" => size,
           "content_type" => content_type
         },
         {:ok, normalized}
       )
       when is_binary(name) and name != "" and is_binary(key) and key != "" and
              is_integer(size) and size > 0 and is_binary(content_type) do
    file = %{
      "name" => name,
      "key" => key,
      "file_size" => size,
      "content_type" => content_type
    }

    {:cont, {:ok, [file | normalized]}}
  end

  defp normalize_hls_file(_file, _acc),
    do: {:halt, {:error, :invalid_encoding_booster_response}}

  defp decode_storage_events(body) when is_binary(body) do
    events =
      body
      |> String.split("\n", trim: true)
      |> Enum.reduce_while([], fn line, events ->
        case Jason.decode(line) do
          {:ok, event} when is_map(event) -> {:cont, [event | events]}
          _other -> {:halt, :error}
        end
      end)

    case events do
      :error -> {:error, :invalid_encoding_booster_response}
      [] -> {:error, :encoding_booster_empty_response}
      parsed -> {:ok, Enum.reverse(parsed)}
    end
  end

  defp decode_storage_events(_body), do: {:error, :invalid_encoding_booster_response}

  defp put_storage_event_metrics(metadata, metrics) when is_map(metrics) do
    metadata
    |> maybe_put_parsed_integer(metrics, :frames, "frame")
    |> maybe_put_parsed_float(metrics, :fps, "fps")
    |> maybe_put_parsed_float(metrics, :speed_x, "speed")
    |> maybe_put_parsed_integer(metrics, :out_time_ms, "out_time_ms")
    |> maybe_put_parsed_integer(metrics, :dup_frames, "dup_frames")
    |> maybe_put_parsed_integer(metrics, :drop_frames, "drop_frames")
  end

  defp put_storage_event_metrics(metadata, _metrics), do: metadata

  defp maybe_put_event_integer(metadata, event, key, source_key) do
    case Map.get(event, source_key) do
      value when is_integer(value) and value >= 0 -> Map.put(metadata, key, value)
      _other -> metadata
    end
  end

  defp maybe_put_event_string(metadata, event, key, source_key) do
    case Map.get(event, source_key) do
      value when is_binary(value) and value != "" -> Map.put(metadata, key, value)
      _other -> metadata
    end
  end

  defp maybe_put_parsed_integer(metadata, metrics, key, source_key) do
    case Map.get(metrics, source_key) do
      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {parsed, ""} -> Map.put(metadata, key, parsed)
          _other -> metadata
        end

      _other ->
        metadata
    end
  end

  defp maybe_put_parsed_float(metadata, metrics, key, source_key) do
    case Map.get(metrics, source_key) do
      value when is_binary(value) ->
        value = value |> String.trim() |> String.trim_trailing("x")

        case Float.parse(value) do
          {parsed, ""} -> Map.put(metadata, key, parsed)
          _other -> metadata
        end

      _other ->
        metadata
    end
  end

  defp handle_package_hls_response(
         {:ok, %{status: status} = response},
         bundle_path,
         extract_root,
         started_at
       )
       when status in 200..299 do
    with {:ok, %{size: size}} when size > 0 <- SafeFile.stat_regular(bundle_path),
         {:ok, bundle_metadata} <- Bundle.extract_hls(bundle_path, extract_root) do
      _ = SafeFile.rm(bundle_path)

      metadata =
        bundle_metadata
        |> Map.put(:elapsed_ms, System.monotonic_time(:millisecond) - started_at)
        |> maybe_put_instance_id(response)

      {:ok, metadata}
    else
      {:error, reason} ->
        cleanup_package_hls_files(bundle_path, extract_root)
        {:error, reason}

      _other ->
        cleanup_package_hls_files(bundle_path, extract_root)
        {:error, :encoding_booster_empty_response}
    end
  end

  defp handle_package_hls_response(
         {:ok, %{status: 429}},
         bundle_path,
         extract_root,
         _started_at
       ) do
    cleanup_package_hls_files(bundle_path, extract_root)
    {:error, :encoding_booster_busy}
  end

  defp handle_package_hls_response(
         {:ok, %{status: status} = response},
         bundle_path,
         extract_root,
         _started_at
       ) do
    detail = response_error_detail(response)
    cleanup_package_hls_files(bundle_path, extract_root)

    if is_binary(detail),
      do: {:error, {:encoding_booster_http_status, status, detail}},
      else: {:error, {:encoding_booster_http_status, status}}
  end

  defp handle_package_hls_response(
         {:error, reason},
         bundle_path,
         extract_root,
         _started_at
       ) do
    cleanup_package_hls_files(bundle_path, extract_root)
    {:error, {:encoding_booster_request_failed, reason}}
  end

  defp cleanup_package_hls_files(bundle_path, extract_root) do
    _ = SafeFile.rm(bundle_path)
    _ = SafeFile.rm_rf(extract_root)
    :ok
  end

  defp finalize_successful_response(
         request_output_path,
         output_path,
         started_at,
         response,
         opts
       ) do
    with {:ok, bundle_metadata} <-
           maybe_extract_bundle(request_output_path, output_path, opts),
         {:ok, %{size_bytes: size_bytes}} when is_integer(size_bytes) and size_bytes > 0 <-
           finalize_output(output_path, opts) do
      elapsed_ms = System.monotonic_time(:millisecond) - started_at

      metadata =
        %{elapsed_ms: elapsed_ms, size_bytes: size_bytes}
        |> Map.merge(bundle_metadata)
        |> maybe_put_instance_id(response)
        |> maybe_put_ffmpeg_metrics(response)

      {:ok, metadata}
    else
      {:error, reason} ->
        cleanup_response_files(request_output_path, output_path)
        {:error, reason}

      _other ->
        cleanup_response_files(request_output_path, output_path)
        {:error, :encoding_booster_remux_failed}
    end
  end

  defp finalize_output(path, opts) do
    if Keyword.get(opts, :operation) == "audio_peaks" do
      case SafeFile.stat_regular(path) do
        {:ok, %{size: size}} when size > 0 and size <= 65_536 -> {:ok, %{size_bytes: size}}
        _ -> {:error, :invalid_audio_peaks_response}
      end
    else
      faststart_adapter().remux(path)
    end
  end

  defp maybe_extract_bundle(request_output_path, output_path, opts) do
    if Keyword.get(opts, :package_hls, false) do
      result = Bundle.extract(request_output_path, output_path)
      _ = SafeFile.rm(request_output_path)
      result
    else
      {:ok, %{}}
    end
  end

  defp request_output_path(output_path, opts) do
    if Keyword.get(opts, :package_hls, false), do: output_path <> ".bundle.zip", else: output_path
  end

  defp cleanup_response_files(request_output_path, output_path) do
    _ = SafeFile.rm(request_output_path)

    if request_output_path != output_path do
      _ = SafeFile.rm(output_path)
    end

    :ok
  end

  defp response_error_detail(%{body: body}) when is_binary(body) and byte_size(body) <= 8_192 do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> response_error_detail(decoded)
      _other -> nil
    end
  end

  defp response_error_detail(%{body: body}) when is_map(body) do
    response_error_detail(body)
  end

  defp response_error_detail(%{"error" => error} = body) when is_binary(error) do
    error = String.trim(error)
    details = body |> Map.get("details") |> normalize_response_error_detail()

    [error, details]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.join(": ")
    |> String.slice(0, 500)
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp response_error_detail(_response), do: nil

  defp normalize_response_error_detail(detail) when is_binary(detail) do
    detail
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_response_error_detail(_detail), do: nil

  defp faststart_adapter do
    Application.get_env(:mave_core, :encoding_booster_faststart_adapter, Faststart)
  end

  defp gpu_scaler do
    Application.get_env(
      :mave_core,
      :gpu_encoding_booster_scaler_adapter,
      GpuEncodingBoosterScaler
    )
  end

  defp maybe_scale_gpu(profiles) do
    if :gpu in profiles do
      _ = gpu_scaler().prewarm()
    end

    :ok
  end

  defp maybe_put_instance_id(metadata, %Req.Response{} = response) do
    case Req.Response.get_header(response, "x-mave-booster-instance") do
      [instance_id | _rest] when is_binary(instance_id) ->
        if Regex.match?(@instance_id_pattern, instance_id),
          do: Map.put(metadata, :instance_id, instance_id),
          else: metadata

      _other ->
        metadata
    end
  end

  defp maybe_put_instance_id(metadata, _response), do: metadata

  defp maybe_put_ffmpeg_metrics(metadata, %Req.Response{} = response) do
    metadata
    |> maybe_put_integer_header(response, :ffmpeg_elapsed_ms, "x-mave-ffmpeg-elapsed-ms")
    |> maybe_put_integer_header(response, :frames, "x-mave-ffmpeg-frames")
    |> maybe_put_float_header(response, :fps, "x-mave-ffmpeg-fps")
    |> maybe_put_float_header(response, :speed_x, "x-mave-ffmpeg-speed")
    |> maybe_put_integer_header(response, :out_time_ms, "x-mave-ffmpeg-out-time-ms")
    |> maybe_put_integer_header(response, :output_bytes, "x-mave-ffmpeg-output-bytes")
    |> maybe_put_integer_header(response, :dup_frames, "x-mave-ffmpeg-dup-frames")
    |> maybe_put_integer_header(response, :drop_frames, "x-mave-ffmpeg-drop-frames")
  end

  defp maybe_put_ffmpeg_metrics(metadata, _response), do: metadata

  defp maybe_put_integer_header(metadata, response, key, header) do
    case response_header(response, header) do
      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {parsed, ""} -> Map.put(metadata, key, parsed)
          _other -> metadata
        end

      _other ->
        metadata
    end
  end

  defp maybe_put_float_header(metadata, response, key, header) do
    case response_header(response, header) do
      value when is_binary(value) ->
        value = value |> String.trim() |> String.trim_trailing("x")

        case Float.parse(value) do
          {parsed, ""} -> Map.put(metadata, key, parsed)
          _other -> metadata
        end

      _other ->
        metadata
    end
  end

  defp response_header(response, header) do
    case Req.Response.get_header(response, header) do
      [value | _rest] when is_binary(value) -> value
      _other -> nil
    end
  end

  defp encode_url(endpoint) do
    String.trim_trailing(endpoint, "/") <> "/encode"
  end

  defp concat_url(endpoint) do
    String.trim_trailing(endpoint, "/") <> "/concat"
  end

  defp transfer_url(endpoint) do
    String.trim_trailing(endpoint, "/") <> "/transfer"
  end

  defp validate_https_input(input_url) do
    case URI.parse(input_url) do
      %URI{scheme: "https", host: host, userinfo: userinfo}
      when is_binary(host) and host != "" ->
        with :ok <- validate_input_basic_auth(userinfo),
             do: validate_public_https_input(input_url)

      _ ->
        {:error, :encoding_booster_input_must_be_https}
    end
  end

  defp validate_public_https_input(input_url) do
    case PublicHttpUrl.validate(input_url) do
      :ok -> :ok
      {:error, reason} -> {:error, {:unsafe_encoding_booster_input, reason}}
    end
  end

  defp validate_input_basic_auth(nil), do: :ok

  defp validate_input_basic_auth(userinfo) when is_binary(userinfo) and userinfo != "" do
    case decode_input_basic_auth(userinfo) do
      {:ok, _basic_auth} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp validate_input_basic_auth(_userinfo),
    do: {:error, :encoding_booster_input_basic_auth_invalid}

  defp config_value(profile, key, default \\ nil) do
    config_key = if profile == :gpu, do: :gpu_encoding_booster, else: :encoding_booster

    :mave_core
    |> Application.get_env(config_key, [])
    |> Keyword.get(key, default)
  end

  defp private_ipv4?(host) do
    case :inet.parse_ipv4_address(String.to_charlist(host)) do
      {:ok, {10, _, _, _}} -> true
      {:ok, {172, second, _, _}} when second in 16..31 -> true
      {:ok, {192, 168, _, _}} -> true
      _ -> false
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp non_negative_integer(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value, default), do: default
end
