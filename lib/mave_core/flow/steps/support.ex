defmodule MaveCore.Flow.Steps.Support do
  @moduledoc false

  alias MaveCore.Flow.ProgressReporter
  alias MaveCore.Media.Command
  alias MaveCore.Media.Storage
  alias MaveCore.PublicHttpUrl
  alias MaveCore.SafeFile

  @default_media_command_timeout_ms 25 * 60 * 1000
  @flame_timeout_buffer_ms 60_000
  @media_command_timeout_status 124
  @media_command_terminate_grace_ms 5_000
  @media_command_kill_grace_ms 1_000
  @media_tools ~w(ffmpeg ffprobe)
  @max_command_output_bytes 1024 * 1024
  @tmp_component ~r/^[A-Za-z0-9_-]+$/
  @tmp_root_name "mave-flow"

  @spec strict_enabled?(map(), map(), String.t()) :: boolean()
  def strict_enabled?(params, run_input, run_input_key) do
    case Map.fetch(run_input, run_input_key) do
      {:ok, value} -> truthy?(value)
      :error -> truthy?(Map.get(params, "strict"))
    end
  end

  @spec require_binary(term(), atom()) :: {:ok, String.t()} | {:error, {:missing_field, atom()}}
  def require_binary(value, _field) when is_binary(value) and value != "", do: {:ok, value}
  def require_binary(_, field), do: {:error, {:missing_field, field}}

  @spec normalize_version(term()) :: integer()
  def normalize_version(nil), do: 0
  def normalize_version(value) when is_integer(value), do: value

  def normalize_version(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> 0
    end
  end

  def normalize_version(_), do: 0

  @spec normalize_mode(map(), String.t(), [String.t()], String.t()) :: String.t()
  def normalize_mode(run_input, run_input_key, supported_modes, default \\ "auto") do
    mode =
      run_input
      |> Map.get(run_input_key, default)
      |> to_string()
      |> String.downcase()

    if mode in supported_modes, do: mode, else: default
  end

  @spec normalize_param_downcase(term(), String.t()) :: String.t()
  def normalize_param_downcase(value, _default) when is_binary(value) and value != "",
    do: String.downcase(value)

  def normalize_param_downcase(nil, default), do: default
  def normalize_param_downcase(value, _default), do: to_string(value) |> String.downcase()

  @doc "Returns the first video stream, excluding embedded cover artwork."
  @spec video_stream([map()]) :: map() | nil
  def video_stream(streams) when is_list(streams) do
    Enum.find(streams, fn stream ->
      disposition = map_value(stream, "disposition", %{})

      map_value(stream, "codec_type") == "video" and
        map_value(disposition, "attached_pic") not in [1, "1", true]
    end)
  end

  @spec frame_skip_reason(map(), map()) :: String.t() | nil
  def frame_skip_reason(params, dependency_outputs) do
    no_video? = inspect_reports_no_video?(dependency_outputs)

    cond do
      map_value(params, "audio_only", false) and not no_video? ->
        "source has video"

      no_video? and not generated_frame_source?(params, dependency_outputs) ->
        "no video stream"

      true ->
        nil
    end
  end

  defp generated_frame_source?(params, dependency_outputs) do
    output = Map.get(dependency_outputs, map_value(params, "source_step_id"), %{})
    bucket = map_value(output, "bucket")
    key = map_value(output, "key")

    map_value(output, "status") == "ok" and
      map_value(output, "step_type") in ["media.transcode_waveform", "media.extract_frame"] and
      is_binary(bucket) and bucket != "" and is_binary(key) and key != ""
  end

  @spec inspect_reports_no_video?(term()) :: boolean()
  def inspect_reports_no_video?(dependency_outputs) when is_map(dependency_outputs) do
    inspect_output_reports_no_video?(Map.get(dependency_outputs, "inspect_media", %{})) or
      Enum.any?(Map.values(dependency_outputs), &step_output_reports_no_video?/1)
  end

  def inspect_reports_no_video?(_), do: false

  defp inspect_output_reports_no_video?(%{} = inspect_output) do
    Map.get(inspect_output, "has_video", Map.get(inspect_output, :has_video)) == false
  end

  defp inspect_output_reports_no_video?(_), do: false

  defp step_output_reports_no_video?(%{} = output) do
    status = Map.get(output, "status", Map.get(output, :status))
    reason = Map.get(output, "reason", Map.get(output, :reason))

    status == "skipped" and reason == "no video stream"
  end

  defp step_output_reports_no_video?(_), do: false

  @spec truncate_binary(term(), integer()) :: term()
  def truncate_binary(nil, _max), do: nil
  def truncate_binary(value, max) when is_binary(value) and byte_size(value) <= max, do: value

  def truncate_binary(value, max) when is_binary(value) and is_integer(max),
    do: binary_part(value, 0, max)

  def truncate_binary(value, _max), do: value

  @spec extension_from_content_type(term()) :: String.t() | nil
  def extension_from_content_type(content_type) when is_binary(content_type) do
    content_type
    |> String.split(";")
    |> List.first()
    |> String.trim()
    |> content_type_extension()
  end

  def extension_from_content_type(_), do: nil

  @spec extension_from_url(term()) :: String.t() | nil
  def extension_from_url(source_url) when is_binary(source_url) do
    source_url
    |> String.split("?")
    |> List.first()
    |> Path.extname()
    |> case do
      "" -> nil
      ext -> ext |> String.trim_leading(".") |> String.downcase()
    end
  end

  def extension_from_url(_), do: nil

  @spec resolve_source_body(map(), term(), map()) :: {:ok, binary()} | {:error, term()}
  def resolve_source_body(run_input, source_url, dependency_outputs \\ %{}) do
    case Map.fetch(run_input, "source_body") do
      {:ok, body} when is_binary(body) ->
        {:ok, body}

      {:ok, _other} ->
        {:error, {:invalid_field, :source_body}}

      :error ->
        case preferred_storage_reference(run_input, dependency_outputs) do
          {:ok, bucket, key, region} ->
            fetch_source_body_from_storage(bucket, key, region)

          :error ->
            fetch_source_body(source_url)
        end
    end
  end

  @spec fetch_source_body(term()) :: {:ok, binary()} | {:error, term()}
  def fetch_source_body(source_url) when is_binary(source_url) and source_url != "" do
    with {:ok, req_options} <- remote_source_req_options(source_url) do
      case Req.get(req_options) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          {:ok, body}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:http_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def fetch_source_body(_), do: {:error, {:missing_field, :source_url}}

  defp remote_source_req_options(source_url) do
    case PublicHttpUrl.req_options(source_url) do
      {:ok, req_options} -> {:ok, req_options}
      {:error, reason} -> {:error, {:unsafe_source_url, reason}}
    end
  end

  @spec find_ffmpeg() :: {:ok, String.t()} | {:error, :ffmpeg_not_found}
  def find_ffmpeg do
    case System.find_executable("ffmpeg") do
      nil -> {:error, :ffmpeg_not_found}
      ffmpeg_bin -> {:ok, ffmpeg_bin}
    end
  end

  @spec find_ffprobe() :: {:ok, String.t()} | {:error, :ffprobe_not_found}
  def find_ffprobe do
    case System.find_executable("ffprobe") do
      nil -> {:error, :ffprobe_not_found}
      ffprobe_bin -> {:ok, ffprobe_bin}
    end
  end

  def with_temp_dir(prefix, fun) when is_binary(prefix) and is_function(fun, 1) do
    tmp_dir =
      Path.join(
        tmp_root(),
        "#{normalize_tmp_component!(prefix, :prefix)}_#{Ecto.UUID.generate()}"
      )

    create_tmp_dir!(tmp_dir)
    File.chmod!(tmp_dir, 0o700)

    try do
      fun.(tmp_dir)
    after
      _ = remove_tmp_dir(tmp_dir)
    end
  end

  def tmp_file_path(tmp_dir, basename, extension \\ nil) do
    with :ok <- validate_tmp_path(tmp_dir),
         basename <- normalize_tmp_component!(basename, :basename),
         filename <- tmp_filename(basename, extension) do
      {:ok, Path.join(tmp_dir, filename)}
    end
  end

  def mkdir_tmp_dir(path) do
    create_tmp_dir(path)
  end

  def write_tmp_file(path, body) do
    with :ok <- validate_tmp_path(path) do
      SafeFile.write(path, body)
    end
  end

  def read_tmp_file(path) do
    with :ok <- validate_tmp_path(path) do
      SafeFile.read(path)
    end
  end

  def remove_tmp_file(path) do
    with :ok <- validate_tmp_path(path) do
      SafeFile.rm(path)
    end
  end

  def stream_tmp_file(path, modes) when is_list(modes) do
    case validate_tmp_path(path) do
      :ok -> {:ok, SafeFile.stream_write!(path, modes)}
      {:error, reason} -> {:error, reason}
    end
  end

  # sobelow_skip ["CI.System"]
  def run_media_cmd(executable, args, opts \\ [])

  def run_media_cmd(executable, args, opts)
      when is_binary(executable) and is_list(args) and is_list(opts) do
    with :ok <- validate_media_executable(executable) do
      progress = media_command_progress(opts)

      args =
        executable
        |> maybe_enable_ffmpeg_progress(args, progress)
        |> maybe_add_storage_referer(executable)

      with {:ok, command, args} <- Command.prepare(executable, args, tmp_root()) do
        command
        |> do_run_media_cmd(args, media_command_timeout_ms(opts), progress)
        |> sanitize_media_cmd_result()
      end
    end
  end

  def ffmpeg_progress(nil, _attributes), do: nil

  def ffmpeg_progress(progress_reporter, attributes)
      when is_map(attributes) or is_list(attributes) do
    attributes
    |> Map.new()
    |> Map.put(:reporter, progress_reporter)
  end

  def inspect_duration_ms(dependency_outputs) when is_map(dependency_outputs) do
    dependency_outputs
    |> Map.get("inspect_media", Map.get(dependency_outputs, :inspect_media, %{}))
    |> case do
      inspect_output when is_map(inspect_output) ->
        Map.get(inspect_output, "duration", Map.get(inspect_output, :duration))

      _other ->
        nil
    end
    |> duration_ms()
  end

  def inspect_duration_ms(_dependency_outputs), do: nil

  def report_progress(progress_reporter, event) when is_map(event) do
    ProgressReporter.report(progress_reporter, event)
  end

  def report_progress(_progress_reporter, _event), do: :ok

  @spec validate_media_file(String.t(), :audio | :video) :: :ok | {:error, term()}
  def validate_media_file(path, kind) when kind in [:audio, :video] do
    case do_validate_media_file(path, kind) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_media_output, kind, reason}}
    end
  end

  def validate_media_file(_path, kind),
    do: {:error, {:invalid_media_output, kind, :unsupported_media_kind}}

  @doc false
  def decode_probe_output(output) when is_binary(output) do
    case Jason.decode(String.trim(output)) do
      {:ok, payload} when is_map(payload) ->
        {:ok, payload}

      {:ok, _other} ->
        {:error, :invalid_probe_output}

      {:error, reason} ->
        case decode_embedded_probe_json(output) do
          {:ok, payload} -> {:ok, payload}
          :error -> {:error, reason}
        end
    end
  end

  def decode_probe_output(_output), do: {:error, :invalid_probe_output}

  def sanitize_media_output(value) when is_binary(value) do
    Regex.replace(
      ~r/(https?:\/\/[^\s'"<>?]+)\?[^\s'"<>]*/,
      value,
      fn candidate, url_without_query ->
        if String.contains?(candidate, "X-Amz-") do
          url_without_query <> "?[redacted]"
        else
          candidate
        end
      end
    )
  end

  def sanitize_media_output(value), do: value

  defp do_validate_media_file(path, kind) do
    with :ok <- validate_tmp_path(path),
         {:ok, %File.Stat{size: size}} <- SafeFile.stat_regular(path),
         :ok <- validate_media_file_size(size),
         {:ok, ffprobe_bin} <- find_ffprobe(),
         {:ok, payload} <- probe_media_file(ffprobe_bin, path, kind) do
      validate_media_stream(payload, kind)
    end
  end

  defp validate_media_file_size(size) when is_integer(size) and size > 0, do: :ok
  defp validate_media_file_size(_size), do: {:error, :empty_file}

  defp probe_media_file(ffprobe_bin, path, kind) do
    args = [
      "-v",
      "error",
      "-select_streams",
      "#{media_stream_selector(kind)}:0",
      "-show_entries",
      "stream=codec_type,codec_name",
      "-of",
      "json",
      path
    ]

    case run_media_cmd(ffprobe_bin, args) do
      {output, 0} ->
        case decode_probe_output(output) do
          {:ok, payload} -> {:ok, payload}
          {:error, error} -> {:error, {:ffprobe_json_decode_failed, probe_decode_error(error)}}
        end

      {output, status} ->
        {:error, {:ffprobe_exit, status, truncate_binary(output, 1000)}}
    end
  end

  defp decode_embedded_probe_json(output) do
    with {start, 1} <- :binary.match(output, "{"),
         [_ | _] = endings <- :binary.matches(output, "}"),
         {finish, 1} <- List.last(endings),
         true <- finish > start,
         candidate <- binary_part(output, start, finish - start + 1),
         {:ok, payload} when is_map(payload) <- Jason.decode(candidate) do
      {:ok, payload}
    else
      _ -> :error
    end
  end

  defp probe_decode_error(%_{} = error), do: Exception.message(error)
  defp probe_decode_error(error), do: inspect(error)

  defp validate_media_stream(%{"streams" => streams}, kind) when is_list(streams) do
    expected_type = Atom.to_string(kind)

    if Enum.any?(streams, &(Map.get(&1, "codec_type") == expected_type)) do
      :ok
    else
      {:error, {:missing_stream, expected_type}}
    end
  end

  defp validate_media_stream(_payload, kind),
    do: {:error, {:missing_stream, Atom.to_string(kind)}}

  defp media_stream_selector(:audio), do: "a"
  defp media_stream_selector(:video), do: "v"

  @spec prepare_ffmpeg_input(String.t(), map(), term(), map(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def prepare_ffmpeg_input(tmp_dir, run_input, source_url, dependency_outputs \\ %{}, opts \\ []) do
    case Map.fetch(run_input, "source_body") do
      {:ok, body} when is_binary(body) ->
        write_ffmpeg_input(tmp_dir, body, run_input, source_url)

      {:ok, _other} ->
        {:error, {:invalid_field, :source_body}}

      :error ->
        case upload_ffmpeg_input_url(run_input, opts) do
          {:ok, url} ->
            {:ok, url}

          :error ->
            prepare_fallback_ffmpeg_input(
              tmp_dir,
              run_input,
              source_url,
              dependency_outputs,
              opts
            )
        end
    end
  end

  defp prepare_fallback_ffmpeg_input(
         tmp_dir,
         run_input,
         source_url,
         dependency_outputs,
         opts
       ) do
    case preferred_storage_source(run_input, dependency_outputs, opts) do
      {:ok, bucket, key, region, content_type, source_ref} ->
        prepare_storage_ffmpeg_input(
          tmp_dir,
          bucket,
          key,
          region,
          content_type,
          source_ref,
          nil,
          opts
        )

      :error ->
        remote_ffmpeg_input(run_input, source_url)
    end
  end

  defp upload_ffmpeg_input_url(run_input, opts) do
    if Keyword.get(opts, :force_download, false) or preferred_derived_input?(opts) do
      :error
    else
      case Map.get(run_input, "upload_ffmpeg_input_url") do
        url when is_binary(url) and url != "" ->
          accept_upload_ffmpeg_input_url(run_input, url)

        _ ->
          :error
      end
    end
  end

  defp preferred_derived_input?(opts) do
    Keyword.get(opts, :prefer_video_rendition, false) or
      match?(
        step_id when is_binary(step_id) and step_id != "",
        Keyword.get(opts, :preferred_storage_step_id)
      )
  end

  defp accept_upload_ffmpeg_input_url(run_input, url) do
    if trusted_upload_ffmpeg_input_url?(run_input, url), do: {:ok, url}, else: :error
  end

  @spec encoding_booster_input_url(map(), term(), map(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def encoding_booster_input_url(run_input, source_url, dependency_outputs \\ %{}, opts \\ [])

  def encoding_booster_input_url(run_input, source_url, dependency_outputs, opts)
      when is_map(run_input) and is_map(dependency_outputs) and is_list(opts) do
    if Map.has_key?(run_input, "source_body") do
      {:error, :encoding_booster_inline_source_unsupported}
    else
      opts =
        Keyword.put_new(
          opts,
          :allow_remote_source_fallback,
          Map.get(run_input, "durable_source_required") != true
        )

      case encoding_booster_storage_source(run_input, dependency_outputs, opts) do
        {:ok, bucket, key, region, _content_type, source_ref} ->
          encoding_booster_storage_url(bucket, key, region, source_ref, source_url, opts)

        :error ->
          remote_booster_input(run_input, source_url)
      end
    end
  end

  def encoding_booster_input_url(_run_input, _source_url, _dependency_outputs, _opts),
    do: {:error, :invalid_encoding_booster_source}

  defp encoding_booster_storage_source(run_input, dependency_outputs, opts) do
    if Keyword.get(opts, :prefer_source_storage, false) do
      case source_storage_reference(run_input) do
        {:ok, bucket, key, region} ->
          {:ok, bucket, key, region, Map.get(run_input, "source_content_type"), nil}

        :error ->
          preferred_storage_source(run_input, dependency_outputs, opts)
      end
    else
      preferred_storage_source(run_input, dependency_outputs, opts)
    end
  end

  defp remote_ffmpeg_input(%{"durable_source_required" => true}, source_url)
       when is_binary(source_url),
       do: {:error, :durable_media_source_required}

  defp remote_ffmpeg_input(_run_input, source_url) do
    with :ok <- validate_remote_ffmpeg_input(source_url) do
      {:ok, source_url}
    end
  end

  defp validate_remote_ffmpeg_input(source_url) do
    case PublicHttpUrl.validate_if_remote(source_url) do
      :ok -> :ok
      {:error, reason} -> {:error, {:unsafe_source_url, reason}}
    end
  end

  defp remote_booster_input(%{"durable_source_required" => true}, source_url)
       when is_binary(source_url),
       do: {:error, :durable_media_source_required}

  defp remote_booster_input(_run_input, source_url), do: encoding_booster_https_url(source_url)

  def prepare_storage_ffmpeg_input(
        tmp_dir,
        bucket,
        key,
        region,
        content_type,
        source_ref \\ nil,
        fallback_extension \\ nil,
        opts \\ []
      ) do
    storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter, Storage)

    case storage_ffmpeg_input_url(storage_adapter, bucket, key, region, source_ref, opts) do
      {:ok, url} ->
        {:ok, url}

      {:error, :unsupported} ->
        download_source_to_ffmpeg_input(
          tmp_dir,
          bucket,
          key,
          region,
          content_type,
          source_ref,
          fallback_extension
        )

      {:error, reason} ->
        {:error, {:source_storage_url_failed, reason}}
    end
  end

  @spec source_storage_reference(map()) :: {:ok, String.t(), String.t(), term()} | :error
  def source_storage_reference(run_input) when is_map(run_input) do
    bucket = Map.get(run_input, "source_bucket")
    key = Map.get(run_input, "source_key")
    region = Map.get(run_input, "source_region")

    if is_binary(bucket) and bucket != "" and is_binary(key) and key != "" do
      {:ok, bucket, key, region}
    else
      :error
    end
  end

  def source_storage_reference(_), do: :error

  defp preferred_storage_reference(run_input, dependency_outputs) do
    case preferred_storage_source(run_input, dependency_outputs, []) do
      {:ok, bucket, key, region, _content_type, _source_ref} ->
        {:ok, bucket, key, region}

      :error ->
        :error
    end
  end

  defp preferred_storage_source(run_input, dependency_outputs, opts) do
    case preferred_step_storage_source(run_input, dependency_outputs, opts) do
      {:ok, _bucket, _key, _region, _content_type, _source_ref} = step_source ->
        step_source

      :error ->
        case preferred_video_storage_source(run_input, dependency_outputs, opts) do
          {:ok, _bucket, _key, _region, _content_type, _source_ref} = video_source ->
            video_source

          :error ->
            preferred_original_storage_source(run_input, dependency_outputs)
        end
    end
  end

  defp preferred_step_storage_source(run_input, dependency_outputs, opts)
       when is_map(run_input) and is_map(dependency_outputs) and is_list(opts) do
    with step_id when is_binary(step_id) and step_id != "" <-
           Keyword.get(opts, :preferred_storage_step_id),
         %{} = output <- Map.get(dependency_outputs, step_id),
         true <- map_value(output, "status", "ok") == "ok",
         {:ok, bucket} <- require_binary(map_value(output, "bucket"), :bucket),
         {:ok, key} <- require_binary(map_value(output, "key"), :key) do
      region = map_value(output, "region") || Map.get(run_input, "region")

      content_type =
        Keyword.get(opts, :preferred_storage_content_type) ||
          map_value(output, "content_type")

      source_ref = map_value(output, "uri") || map_value(output, "src")
      {:ok, bucket, key, region, content_type, source_ref}
    else
      _ -> :error
    end
  end

  defp preferred_step_storage_source(_run_input, _dependency_outputs, _opts), do: :error

  defp preferred_original_storage_source(run_input, dependency_outputs) do
    case source_storage_reference(run_input) do
      {:ok, bucket, key, region} ->
        {:ok, bucket, key, region, Map.get(run_input, "source_content_type"), nil}

      :error ->
        uploaded_original_storage_source(run_input, dependency_outputs)
    end
  end

  defp preferred_video_storage_source(_run_input, _dependency_outputs, opts)
       when not is_list(opts),
       do: :error

  defp preferred_video_storage_source(run_input, dependency_outputs, opts)
       when is_map(dependency_outputs) do
    if Keyword.get(opts, :prefer_video_rendition, false) do
      dependency_outputs
      |> preferred_video_outputs(Keyword.get(opts, :preferred_video_step_id))
      |> Enum.flat_map(&video_source_candidates/1)
      |> select_video_source_candidate(opts)
      |> case do
        %{} = candidate ->
          {:ok, candidate.bucket, candidate.key, candidate.region || Map.get(run_input, "region"),
           "video/mp4", candidate.uri}

        nil ->
          :error
      end
    else
      :error
    end
  end

  defp preferred_video_storage_source(_run_input, _dependency_outputs, _opts), do: :error

  defp preferred_video_outputs(dependency_outputs, preferred_step_id) do
    preferred =
      case preferred_step_id do
        step_id when is_binary(step_id) and step_id != "" ->
          dependency_outputs
          |> Map.get(step_id)
          |> case do
            %{} = output -> [output]
            _ -> []
          end

        _ ->
          []
      end

    preferred ++ Map.values(dependency_outputs)
  end

  defp select_video_source_candidate(candidates, opts) do
    codec = normalize_preferred_video_value(Keyword.get(opts, :preferred_video_codec, "h264"))

    container =
      normalize_preferred_video_value(Keyword.get(opts, :preferred_video_container, "mp4"))

    sizes = preferred_video_sizes(opts)

    candidates
    |> Enum.filter(fn candidate ->
      candidate.codec == codec and candidate.container == container and candidate.size in sizes
    end)
    |> Enum.min_by(
      fn candidate -> Enum.find_index(sizes, &(&1 == candidate.size)) || length(sizes) end,
      fn -> nil end
    )
  end

  defp preferred_video_sizes(opts) do
    opts
    |> Keyword.get(:preferred_video_sizes, Keyword.get(opts, :preferred_video_size, "sd"))
    |> List.wrap()
    |> Enum.map(&normalize_preferred_video_value/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> ["sd"]
      sizes -> sizes
    end
  end

  defp video_source_candidates(%{} = output) do
    case map_value(output, "step_type") do
      "media.transcode_h264_ladder" ->
        output
        |> ladder_variant_candidates()
        |> Enum.map(&inherit_video_source_context(&1, output))
        |> Enum.flat_map(&video_source_candidate/1)

      "media.transcode_video" ->
        video_source_candidate(output)

      _ ->
        []
    end
  end

  defp video_source_candidates(_output), do: []

  defp ladder_variant_candidates(output) do
    variant_outputs =
      output
      |> map_value("variant_outputs", %{})
      |> case do
        %{} = variants -> Map.values(variants)
        _ -> []
      end

    variants =
      output
      |> map_value("variants", [])
      |> case do
        values when is_list(values) -> values
        _ -> []
      end

    variant_outputs ++ variants
  end

  defp inherit_video_source_context(variant, output) when is_map(variant) do
    variant
    |> Map.put_new("bucket", map_value(output, "bucket"))
    |> Map.put_new("region", map_value(output, "region"))
  end

  defp video_source_candidate(%{} = output) do
    with true <- map_value(output, "status", "ok") == "ok",
         {:ok, bucket} <- require_binary(map_value(output, "bucket"), :bucket),
         {:ok, key} <- require_binary(map_value(output, "key"), :key),
         codec when not is_nil(codec) <-
           normalize_preferred_video_value(map_value(output, "codec")),
         size when not is_nil(size) <- normalize_preferred_video_value(map_value(output, "size")),
         container when not is_nil(container) <-
           normalize_preferred_video_value(map_value(output, "container", "mp4")) do
      [
        %{
          bucket: bucket,
          key: key,
          region: map_value(output, "region"),
          uri: map_value(output, "uri"),
          codec: codec,
          size: size,
          container: container
        }
      ]
    else
      _ -> []
    end
  end

  defp normalize_preferred_video_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_preferred_video_value(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_preferred_video_value()

  defp normalize_preferred_video_value(_value), do: nil

  defp map_value(map, key, default \\ nil)

  defp map_value(map, key, default) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        map
        |> Map.keys()
        |> Enum.find_value(default, &map_atom_string_value(map, &1, key))
    end
  end

  defp map_value(_map, _key, default), do: default

  defp map_atom_string_value(map, map_key, key) when is_atom(map_key) do
    if Atom.to_string(map_key) == key, do: Map.get(map, map_key), else: nil
  end

  defp map_atom_string_value(_map, _map_key, _key), do: nil

  defp uploaded_original_storage_source(run_input, dependency_outputs)
       when is_map(dependency_outputs) do
    upload_output = Map.get(dependency_outputs, "upload_original", %{})
    bucket = Map.get(upload_output, "bucket")
    key = Map.get(upload_output, "original_key")
    region = Map.get(upload_output, "region") || Map.get(run_input, "region")

    content_type =
      Map.get(upload_output, "content_type") || Map.get(run_input, "source_content_type")

    source_ref = Map.get(upload_output, "original_uri")

    if is_binary(bucket) and bucket != "" and is_binary(key) and key != "" do
      {:ok, bucket, key, region, content_type, source_ref}
    else
      :error
    end
  end

  defp uploaded_original_storage_source(_run_input, _dependency_outputs), do: :error

  defp content_type_extension("video/mp4"), do: "mp4"
  defp content_type_extension("audio/mpeg"), do: "mp3"
  defp content_type_extension("audio/wav"), do: "wav"
  defp content_type_extension("audio/x-wav"), do: "wav"
  defp content_type_extension("audio/mp4"), do: "m4a"
  defp content_type_extension("video/quicktime"), do: "mov"
  defp content_type_extension("video/webm"), do: "webm"
  defp content_type_extension("video/x-matroska"), do: "mkv"
  defp content_type_extension("image/jpeg"), do: "jpg"
  defp content_type_extension("image/png"), do: "png"
  defp content_type_extension("image/webp"), do: "webp"

  defp content_type_extension(other) do
    other
    |> String.split("/")
    |> List.last()
  end

  defp fetch_source_body_from_storage(bucket, key, region) do
    storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter, Storage)

    case storage_adapter.get(bucket, key, region) do
      {:ok, body} when is_binary(body) ->
        {:ok, body}

      {:ok, _other} ->
        {:error, {:invalid_source_body, :source_storage}}

      {:error, reason} ->
        {:error, {:source_storage_get_failed, reason}}
    end
  end

  defp download_source_to_ffmpeg_input(
         tmp_dir,
         bucket,
         key,
         region,
         content_type,
         source_ref,
         fallback_extension
       ) do
    source_extension =
      fallback_extension || extension_from_content_type(content_type) ||
        extension_from_url(source_ref) ||
        "bin"

    storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter, Storage)

    with {:ok, input_path} <- tmp_file_path(tmp_dir, "input", source_extension) do
      case storage_adapter.download_to_file(bucket, key, input_path, region) do
        :ok ->
          {:ok, input_path}

        {:error, reason} ->
          {:error, {:source_storage_get_failed, reason}}
      end
    end
  end

  def run_ffmpeg_with_storage_fallback(
        tmp_dir,
        run_input,
        source_url,
        dependency_outputs,
        build_args,
        opts \\ []
      )
      when is_function(build_args, 1) and is_list(opts) do
    with {:ok, ffmpeg_bin} <- find_ffmpeg() do
      %{
        ffmpeg_bin: ffmpeg_bin,
        tmp_dir: tmp_dir,
        run_input: run_input,
        source_url: source_url,
        dependency_outputs: dependency_outputs,
        build_args: build_args,
        opts: opts,
        storage_backed_input?: storage_backed_ffmpeg_input?(run_input, dependency_outputs, opts)
      }
      |> run_ffmpeg_with_optional_storage_fallback()
    end
  end

  defp run_ffmpeg_with_optional_storage_fallback(context) do
    case run_ffmpeg_once(context, false) do
      {:ok, output} ->
        {:ok, output, false}

      {:error, {:ffmpeg_output_validation_failed, _reason} = validation_error} ->
        maybe_retry_ffmpeg_from_download(context.storage_backed_input?, validation_error, context)

      {:error, {ffmpeg_output, _status} = initial_error} when is_binary(ffmpeg_output) ->
        maybe_retry_ffmpeg_from_download(
          context.storage_backed_input? and ffmpeg_storage_read_error?(ffmpeg_output),
          initial_error,
          context
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_retry_ffmpeg_from_download(true, _initial_error, context) do
    case run_ffmpeg_once(context, true) do
      {:ok, output} -> {:ok, output, true}
      {:error, {:ffmpeg_output_validation_failed, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_retry_ffmpeg_from_download(
         false,
         {:ffmpeg_output_validation_failed, reason},
         _context
       ) do
    {:error, reason}
  end

  defp maybe_retry_ffmpeg_from_download(false, initial_error, _context) do
    {:error, initial_error}
  end

  def ffmpeg_storage_read_error?(output) when is_binary(output) do
    normalized = String.downcase(output)

    String.contains?(normalized, "partial file") or
      String.contains?(normalized, "after eof") or
      String.contains?(normalized, "cannot determine format of input") or
      String.contains?(normalized, "invalid data found when processing input") or
      String.contains?(normalized, "failed to find two consecutive mpeg audio frames") or
      Regex.match?(~r/server returned [45](?:\d\d|xx)\b/, normalized) or
      Regex.match?(~r/http error [45](?:\d\d|xx)\b/, normalized) or
      ffmpeg_network_error?(normalized)
  end

  def ffmpeg_storage_read_error?(_output), do: false

  defp ffmpeg_network_error?(output) do
    Enum.any?(
      ["connection refused", "connection timed out", "failed to resolve hostname"],
      &String.contains?(output, &1)
    )
  end

  def ffmpeg_fallback_metadata(false), do: %{}
  def ffmpeg_fallback_metadata(true), do: %{"ffmpeg_input_fallback" => "download"}

  defp storage_backed_ffmpeg_input?(run_input, dependency_outputs, opts) do
    match?(
      {:ok, _bucket, _key, _region, _content_type, _source_ref},
      preferred_storage_source(run_input, dependency_outputs, opts)
    )
  end

  defp run_ffmpeg_once(context, force_download?) do
    opts = Keyword.put(context.opts, :force_download, force_download?)

    with {:ok, input_ref} <-
           prepare_ffmpeg_input(
             context.tmp_dir,
             context.run_input,
             context.source_url,
             context.dependency_outputs,
             opts
           ),
         {:ok, args} <- context.build_args.(input_ref) do
      case run_media_cmd(context.ffmpeg_bin, args, media_cmd_opts(context.opts)) do
        {output, 0} -> validate_ffmpeg_output(output, context)
        {output, status} -> {:error, {output, status}}
      end
    end
  end

  defp validate_ffmpeg_output(output, context) do
    validate_output = Keyword.get(context.opts, :validate_output, fn -> :ok end)

    case validate_output.() do
      :ok -> {:ok, output}
      {:error, reason} -> {:error, {:ffmpeg_output_validation_failed, reason}}
    end
  end

  defp storage_ffmpeg_input_url(storage_adapter, bucket, key, region, source_ref, opts) do
    if Keyword.get(opts, :force_download, false) do
      {:error, :unsupported}
    else
      storage_ffmpeg_input_url(storage_adapter, bucket, key, region, source_ref)
    end
  end

  defp storage_ffmpeg_input_url(storage_adapter, bucket, key, region, source_ref) do
    if direct_storage_ffmpeg_input?() do
      presigned_url =
        if not upload_bucket?(bucket) and
             function_exported?(storage_adapter, :presigned_get_url, 4) do
          storage_adapter.presigned_get_url(bucket, key, region, expires: 2 * 60 * 60)
          |> normalize_ffmpeg_input_url()
        else
          {:error, :unsupported}
        end

      case presigned_url do
        {:ok, _url} = result ->
          result

        {:error, _reason} ->
          unsigned_storage_ffmpeg_input_url(storage_adapter, bucket, key, region, source_ref)
      end
    else
      {:error, :unsupported}
    end
  end

  defp unsigned_storage_ffmpeg_input_url(storage_adapter, bucket, key, region, source_ref) do
    cond do
      function_exported?(storage_adapter, :ffmpeg_input_url, 3) ->
        storage_adapter.ffmpeg_input_url(bucket, key, region)
        |> normalize_ffmpeg_input_url()

      remote_url?(source_ref) ->
        {:ok, source_ref}

      true ->
        {:error, :unsupported}
    end
  end

  defp encoding_booster_storage_url(bucket, key, region, source_ref, source_url, opts) do
    storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter, Storage)

    presigned_url =
      if presigned_booster_input?(bucket, opts) and
           function_exported?(storage_adapter, :presigned_get_url, 4) do
        storage_adapter.presigned_get_url(bucket, key, region, expires: 2 * 60 * 60)
        |> normalize_ffmpeg_input_url()
      else
        {:error, :unsupported}
      end

    storage_url =
      if function_exported?(storage_adapter, :ffmpeg_input_url, 3) do
        storage_adapter.ffmpeg_input_url(bucket, key, region)
        |> normalize_ffmpeg_input_url()
      else
        {:error, :unsupported}
      end

    case presigned_url do
      {:ok, url} ->
        encoding_booster_https_url(url)

      {:error, _reason} ->
        encoding_booster_unsigned_storage_url(storage_url, source_ref, source_url, opts)
    end
  end

  defp presigned_booster_input?(bucket, opts) do
    Keyword.get(opts, :prefer_video_rendition, false) or not upload_bucket?(bucket)
  end

  defp upload_bucket?(bucket) when is_binary(bucket) do
    upload_config = Application.get_env(:mave_core, :upload, [])

    configured_bucket =
      cond do
        is_map(upload_config) ->
          Map.get(upload_config, :bucket) || Map.get(upload_config, "bucket")

        Keyword.keyword?(upload_config) ->
          Keyword.get(upload_config, :bucket)

        true ->
          nil
      end

    bucket == configured_bucket
  end

  defp upload_bucket?(_bucket), do: false

  defp recorded_upload_bucket?(run_input) when is_map(run_input) do
    upload_bucket?(Map.get(run_input, "source_bucket")) or
      upload_bucket?(Map.get(run_input, "upload_bucket"))
  end

  defp recorded_upload_bucket?(_run_input), do: false

  defp trusted_upload_ffmpeg_input_url?(run_input, url) do
    not remote_url?(url) or
      recorded_upload_bucket?(run_input) or
      Storage.upload_storage_url?(url) or
      Storage.upload_public_url?(url)
  end

  defp encoding_booster_unsigned_storage_url(storage_url, source_ref, source_url, opts) do
    case storage_url do
      {:ok, url} -> encoding_booster_https_url(url)
      {:error, _reason} -> encoding_booster_source_fallback(source_ref, source_url, opts)
    end
  end

  defp encoding_booster_source_fallback(source_ref, source_url, opts) when is_list(opts) do
    if Keyword.get(opts, :allow_remote_source_fallback, true) do
      resolve_encoding_booster_source_fallback(source_ref, source_url)
    else
      {:error, :durable_media_source_required}
    end
  end

  defp resolve_encoding_booster_source_fallback(source_ref, source_url) do
    case encoding_booster_https_url(source_ref) do
      {:ok, _url} = result -> result
      {:error, _reason} -> encoding_booster_https_url(source_url)
    end
  end

  defp encoding_booster_https_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        {:ok, url}

      _ ->
        {:error, :encoding_booster_input_must_be_https}
    end
  end

  defp encoding_booster_https_url(_url), do: {:error, :encoding_booster_input_must_be_https}

  defp direct_storage_ffmpeg_input? do
    case Application.get_env(:mave_core, :flow_direct_storage_ffmpeg_input, true) do
      value when value in [true, "true", "1", 1] -> true
      _ -> false
    end
  end

  defp normalize_ffmpeg_input_url({:ok, url}), do: normalize_ffmpeg_input_url(url)
  defp normalize_ffmpeg_input_url({:error, reason}), do: {:error, reason}

  defp normalize_ffmpeg_input_url(url) when is_binary(url) do
    if String.trim(url) == "", do: {:error, :empty_url}, else: {:ok, url}
  end

  defp normalize_ffmpeg_input_url(_), do: {:error, :invalid_url}

  defp remote_url?(value) when is_binary(value) do
    String.starts_with?(value, "http://") or String.starts_with?(value, "https://")
  end

  defp remote_url?(_value), do: false

  defp maybe_add_storage_referer(args, executable) do
    case {Path.basename(executable), Storage.ffmpeg_input_referer()} do
      {"ffmpeg", referer} when is_binary(referer) ->
        add_ffmpeg_storage_headers(args, referer)

      {"ffprobe", referer} when is_binary(referer) ->
        if Enum.any?(args, &Storage.ffmpeg_referer_required?/1) do
          ["-headers", storage_referer_header(referer) | args]
        else
          args
        end

      _other ->
        args
    end
  end

  defp add_ffmpeg_storage_headers(["-i", input | rest], referer) do
    input_args =
      if Storage.ffmpeg_referer_required?(input) do
        ["-headers", storage_referer_header(referer), "-i", input]
      else
        ["-i", input]
      end

    input_args ++ add_ffmpeg_storage_headers(rest, referer)
  end

  defp add_ffmpeg_storage_headers([arg | rest], referer),
    do: [arg | add_ffmpeg_storage_headers(rest, referer)]

  defp add_ffmpeg_storage_headers([], _referer), do: []

  defp storage_referer_header(referer), do: "Referer: #{referer}\r\n"

  defp sanitize_media_cmd_result({output, status}) when is_binary(output) do
    {sanitize_media_output(output), status}
  end

  defp sanitize_media_cmd_result(other), do: other

  # sobelow_skip ["CI.System"]
  defp do_run_media_cmd(executable, args, timeout_ms, progress) do
    ref = make_ref()

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:args, args},
        {:env,
         Enum.map(Command.environment(), fn {key, value} ->
           {String.to_charlist(key), if(value, do: String.to_charlist(value), else: false)}
         end)}
      ])

    timer_ref =
      if timeout_ms != :infinity,
        do: Process.send_after(self(), {:media_command_timeout, ref}, timeout_ms)

    collect_media_cmd(port, ref, timer_ref, timeout_ms, "", init_progress_state(progress))
  end

  defp collect_media_cmd(port, ref, timer_ref, timeout_ms, output, progress_state) do
    receive do
      {^port, {:data, data}} when is_binary(data) ->
        progress_state = handle_progress_data(progress_state, data)

        collect_media_cmd(
          port,
          ref,
          timer_ref,
          timeout_ms,
          bounded_output(output, data),
          progress_state
        )

      {^port, {:exit_status, status}} ->
        cancel_media_command_timer(timer_ref)
        {output_binary(output), status}

      {:media_command_timeout, ^ref} ->
        terminate_timed_out_media_cmd(port, timeout_ms, output)
    end
  end

  defp terminate_timed_out_media_cmd(port, timeout_ms, output) do
    pid = port_os_pid(port)
    signal_os_process(pid, "TERM")

    case collect_timed_out_media_cmd(
           port,
           output,
           media_command_deadline(@media_command_terminate_grace_ms)
         ) do
      {:done, output} ->
        media_command_timeout_result(output, timeout_ms)

      {:timeout, output} ->
        signal_os_process(pid, "KILL")

        case collect_timed_out_media_cmd(
               port,
               output,
               media_command_deadline(@media_command_kill_grace_ms)
             ) do
          {:done, output} ->
            media_command_timeout_result(output, timeout_ms)

          {:timeout, output} ->
            close_media_port(port)
            media_command_timeout_result(output, timeout_ms)
        end
    end
  end

  defp collect_timed_out_media_cmd(port, output, deadline) do
    timeout_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    if timeout_ms == 0 do
      {:timeout, output}
    else
      receive do
        {^port, {:data, data}} when is_binary(data) ->
          collect_timed_out_media_cmd(port, bounded_output(output, data), deadline)

        {^port, {:exit_status, _status}} ->
          {:done, output}
      after
        timeout_ms ->
          {:timeout, output}
      end
    end
  end

  defp media_command_timeout_result(output, timeout_ms) do
    output =
      output
      |> output_binary()
      |> append_timeout_message(timeout_ms)

    {output, @media_command_timeout_status}
  end

  defp append_timeout_message(output, timeout_ms) do
    separator = if output == "" or String.ends_with?(output, "\n"), do: "", else: "\n"
    "#{output}#{separator}media command timed out after #{timeout_ms} ms\n"
  end

  defp output_binary(output), do: output

  defp bounded_output(output, data) do
    combined = output <> data
    size = byte_size(combined)

    binary_part(
      combined,
      max(size - @max_command_output_bytes, 0),
      min(size, @max_command_output_bytes)
    )
  end

  defp media_command_deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms

  defp cancel_media_command_timer(nil), do: :ok

  defp cancel_media_command_timer(timer_ref) do
    Process.cancel_timer(timer_ref, async: false, info: false)
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) -> pid
      _ -> nil
    end
  end

  # sobelow_skip ["CI.System"]
  defp signal_os_process(pid, signal) when is_integer(pid) and signal in ["TERM", "KILL"] do
    case kill_executable() do
      nil ->
        :ok

      executable ->
        _ = System.cmd(executable, ["-#{signal}", Integer.to_string(pid)], stderr_to_stdout: true)
        :ok
    end
  rescue
    _ -> :ok
  end

  defp signal_os_process(_pid, _signal), do: :ok

  defp kill_executable do
    System.find_executable("kill") ||
      if(File.exists?("/bin/kill"), do: "/bin/kill")
  end

  defp close_media_port(port) do
    if Port.info(port) do
      Port.close(port)
    end
  rescue
    _ -> :ok
  end

  defp media_cmd_opts(opts) do
    Keyword.take(opts, [:timeout_ms, :command_timeout_ms, :progress])
  end

  defp media_command_timeout_ms(opts) do
    opts
    |> Keyword.get(:command_timeout_ms, Keyword.get(opts, :timeout_ms))
    |> normalize_media_command_timeout()
    |> case do
      nil -> configured_media_command_timeout_ms()
      timeout -> timeout
    end
  end

  defp configured_media_command_timeout_ms do
    :mave_core
    |> Application.get_env(:flow_media_command_timeout_ms)
    |> normalize_media_command_timeout()
    |> case do
      nil -> default_media_command_timeout_ms()
      timeout -> timeout
    end
  end

  defp media_command_progress(opts) do
    case Keyword.get(opts, :progress) do
      progress when is_list(progress) -> Map.new(progress)
      progress when is_map(progress) -> progress
      _other -> nil
    end
  end

  defp maybe_enable_ffmpeg_progress(_executable, args, nil), do: args

  defp maybe_enable_ffmpeg_progress(executable, args, _progress) do
    if ffmpeg_executable?(executable) and "-progress" not in args do
      ["-nostats", "-progress", "pipe:1" | args]
    else
      args
    end
  end

  defp ffmpeg_executable?(executable) do
    executable
    |> Path.basename()
    |> String.downcase()
    |> then(&(&1 in ["ffmpeg", "ffmpeg.exe"]))
  end

  defp duration_ms(value) when is_integer(value), do: value * 1000
  defp duration_ms(value) when is_float(value), do: round(value * 1000)

  defp duration_ms(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _rest} -> duration_ms(parsed)
      :error -> nil
    end
  end

  defp duration_ms(_value), do: nil

  defp init_progress_state(nil), do: nil

  defp init_progress_state(progress) do
    %{
      progress: progress,
      buffer: "",
      fields: %{},
      started_at_ms: System.monotonic_time(:millisecond)
    }
  end

  defp handle_progress_data(nil, _data), do: nil

  defp handle_progress_data(progress_state, data) do
    {lines, buffer} = complete_progress_lines(progress_state.buffer <> data)

    lines
    |> Enum.reduce(%{progress_state | buffer: buffer}, &handle_progress_line/2)
  end

  defp complete_progress_lines(data) do
    parts = String.split(data, "\n")

    if String.ends_with?(data, "\n") do
      {Enum.reject(parts, &(&1 == "")), ""}
    else
      {Enum.drop(parts, -1), truncate_binary(List.last(parts) || "", 65_536)}
    end
  end

  defp handle_progress_line(line, state) do
    case String.split(String.trim(line), "=", parts: 2) do
      [key, value]
      when key in ~w(frame fps stream_0_0_q bitrate total_size out_time_us out_time_ms out_time dup_frames drop_frames speed progress) ->
        fields = Map.put(state.fields, key, String.trim(value))
        state = %{state | fields: fields}

        if key == "progress" do
          report_ffmpeg_progress(state)
        else
          state
        end

      _other ->
        state
    end
  end

  defp report_ffmpeg_progress(state) do
    progress = state.progress
    total_ms = integer_progress_value(progress, "total_ms")
    out_time_ms = ffmpeg_out_time_ms(state.fields)
    ffmpeg_elapsed_ms = ffmpeg_elapsed_ms(state.started_at_ms)
    ratio = progress_ratio(out_time_ms, total_ms)
    ended? = state.fields["progress"] == "end"
    percent = progress_percent(ratio, ended?)

    report_progress(progress_value(progress, "reporter"), %{
      "source" => "ffmpeg",
      "status" => if(ended?, do: "completed", else: "executing"),
      "stage" => progress_value(progress, "stage") || "processing",
      "step_id" => progress_value(progress, "step_id"),
      "codec" => progress_value(progress, "codec"),
      "size" => progress_value(progress, "size"),
      "container" => progress_value(progress, "container"),
      "variants" => progress_value(progress, "variants"),
      "preset" => progress_value(progress, "preset"),
      "tune" => progress_value(progress, "tune"),
      "percent" => percent,
      "ratio" => ratio,
      "out_time_ms" => out_time_ms,
      "total_ms" => total_ms,
      "frame" => ffmpeg_integer_field(state.fields, "frame"),
      "fps" => ffmpeg_float_field(state.fields, "fps"),
      "speed_x" => ffmpeg_speed_x(state.fields, out_time_ms, ffmpeg_elapsed_ms),
      "ffmpeg_elapsed_ms" => ffmpeg_elapsed_ms,
      "total_size_bytes" => ffmpeg_integer_field(state.fields, "total_size"),
      "dup_frames" => ffmpeg_integer_field(state.fields, "dup_frames"),
      "drop_frames" => ffmpeg_integer_field(state.fields, "drop_frames"),
      "force" => ended?
    })

    state
  end

  defp progress_percent(nil, true), do: 99.0
  defp progress_percent(nil, false), do: nil
  defp progress_percent(_ratio, true), do: 99.0
  defp progress_percent(ratio, false), do: ratio |> Kernel.*(99.0) |> min(99.0)

  defp progress_ratio(nil, _total_ms), do: nil
  defp progress_ratio(_out_time_ms, nil), do: nil
  defp progress_ratio(_out_time_ms, total_ms) when total_ms <= 0, do: nil
  defp progress_ratio(out_time_ms, total_ms), do: min(out_time_ms / total_ms, 1.0)

  defp ffmpeg_elapsed_ms(started_at_ms) when is_integer(started_at_ms) do
    System.monotonic_time(:millisecond)
    |> Kernel.-(started_at_ms)
    |> max(1)
  end

  defp ffmpeg_speed_x(fields, out_time_ms, ffmpeg_elapsed_ms) do
    ffmpeg_float_field(fields, "speed") || derived_speed_x(out_time_ms, ffmpeg_elapsed_ms)
  end

  defp derived_speed_x(out_time_ms, ffmpeg_elapsed_ms)
       when is_integer(out_time_ms) and is_integer(ffmpeg_elapsed_ms) and ffmpeg_elapsed_ms > 0 do
    out_time_ms / ffmpeg_elapsed_ms
  end

  defp derived_speed_x(_out_time_ms, _ffmpeg_elapsed_ms), do: nil

  defp ffmpeg_integer_field(fields, key) do
    case Map.get(fields, key) do
      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {parsed, ""} -> parsed
          _other -> nil
        end

      _other ->
        nil
    end
  end

  defp ffmpeg_float_field(fields, key) do
    case Map.get(fields, key) do
      value when is_binary(value) ->
        value
        |> String.trim()
        |> String.trim_trailing("x")
        |> Float.parse()
        |> case do
          {parsed, ""} -> parsed
          _other -> nil
        end

      _other ->
        nil
    end
  end

  defp ffmpeg_out_time_ms(fields) do
    cond do
      integer_string?(fields["out_time_us"]) ->
        div(parse_integer!(fields["out_time_us"]), 1_000)

      integer_string?(fields["out_time_ms"]) ->
        div(parse_integer!(fields["out_time_ms"]), 1_000)

      is_binary(fields["out_time"]) ->
        parse_ffmpeg_time_ms(fields["out_time"])

      true ->
        nil
    end
  end

  defp parse_ffmpeg_time_ms(value) do
    case String.split(value, ":") do
      [hours, minutes, seconds] ->
        with {hours, ""} <- Integer.parse(hours),
             {minutes, ""} <- Integer.parse(minutes),
             {seconds, _rest} <- Float.parse(seconds) do
          round((hours * 3600 + minutes * 60 + seconds) * 1000)
        else
          _ -> nil
        end

      _other ->
        nil
    end
  end

  defp integer_progress_value(progress, key) do
    case progress_value(progress, key) do
      value when is_integer(value) -> value
      value when is_float(value) -> round(value)
      value when is_binary(value) and value != "" -> parse_integer(value)
      _other -> nil
    end
  end

  defp progress_value(progress, key) when is_map(progress) do
    Map.get(progress, key) || existing_progress_atom_value(progress, key)
  end

  defp progress_value(_progress, _key), do: nil

  defp existing_progress_atom_value(progress, key) do
    Map.get(progress, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp integer_string?(value) when is_binary(value) do
    match?({_integer, ""}, Integer.parse(value))
  end

  defp integer_string?(_value), do: false

  defp parse_integer(value) do
    case Integer.parse(value) do
      {integer, _rest} -> integer
      :error -> nil
    end
  end

  defp parse_integer!(value) do
    {integer, _rest} = Integer.parse(value)
    integer
  end

  defp default_media_command_timeout_ms do
    case Application.get_env(:mave_core, :flame_pool, []) do
      flame_pool_config when is_list(flame_pool_config) ->
        flame_pool_config
        |> Keyword.get(:timeout)
        |> default_media_command_timeout_ms()

      _other ->
        @default_media_command_timeout_ms
    end
  end

  defp default_media_command_timeout_ms(timeout_ms)
       when is_integer(timeout_ms) and timeout_ms > @flame_timeout_buffer_ms do
    min(@default_media_command_timeout_ms, timeout_ms - @flame_timeout_buffer_ms)
  end

  defp default_media_command_timeout_ms(_timeout_ms), do: @default_media_command_timeout_ms

  defp normalize_media_command_timeout(:infinity), do: :infinity

  defp normalize_media_command_timeout(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0,
    do: timeout_ms

  defp normalize_media_command_timeout(timeout_ms) when is_binary(timeout_ms) do
    case Integer.parse(timeout_ms) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp normalize_media_command_timeout(_timeout_ms), do: nil

  defp write_ffmpeg_input(tmp_dir, body, run_input, source_url) do
    source_content_type = Map.get(run_input, "source_content_type")

    source_extension =
      extension_from_content_type(source_content_type) || extension_from_url(source_url) ||
        "bin"

    with {:ok, input_path} <- tmp_file_path(tmp_dir, "input", source_extension),
         :ok <- write_tmp_file(input_path, body) do
      {:ok, input_path}
    end
  end

  defp tmp_root do
    path = tmp_root_path()
    SafeFile.mkdir_p!(path)
    Path.expand(path)
  end

  defp create_tmp_dir!(path) do
    case validate_tmp_path(path) do
      :ok -> SafeFile.mkdir_p!(path)
      {:error, reason} -> raise ArgumentError, "invalid temp path: #{inspect(reason)}"
    end
  end

  defp create_tmp_dir(path) do
    with :ok <- validate_tmp_path(path) do
      SafeFile.mkdir_p(path)
    end
  end

  defp remove_tmp_dir(path) do
    with :ok <- validate_tmp_path(path) do
      SafeFile.rm_rf(path)
    end
  end

  defp tmp_filename(basename, nil), do: basename

  defp tmp_filename(basename, extension) do
    "#{basename}.#{normalize_tmp_component!(extension, :extension)}"
  end

  defp normalize_tmp_component!(value, label) when is_binary(value) do
    if Regex.match?(@tmp_component, value), do: value, else: invalid_tmp_component!(value, label)
  end

  defp normalize_tmp_component!(value, label) do
    invalid_tmp_component!(value, label)
  end

  defp invalid_tmp_component!(value, label) do
    raise ArgumentError, "invalid temp #{label}: #{inspect(value)}"
  end

  defp validate_tmp_path(path) when is_binary(path) do
    expanded = Path.expand(path)
    root = tmp_root_path()

    if expanded == root or String.starts_with?(expanded, root <> "/") do
      :ok
    else
      {:error, {:invalid_temp_path, path}}
    end
  end

  defp validate_tmp_path(path), do: {:error, {:invalid_temp_path, path}}

  defp tmp_root_path do
    Path.expand(Path.join(System.tmp_dir!(), @tmp_root_name))
  end

  defp validate_media_executable(executable) do
    case Path.basename(executable) do
      tool when tool in @media_tools -> :ok
      _ -> {:error, {:invalid_media_executable, executable}}
    end
  end

  defp truthy?(value), do: value in [true, "true", 1, "1"]
end
