defmodule MaveCore.Flow.Steps.MediaGenerateStoryboardStep do
  @moduledoc """
  Produces storyboard artifacts (`storyboard.jpg` and `storyboard.vtt`).

  Modes:
  - `auto` (default): FFmpeg for normal sources; copy-mode only for inline `source_body`
  - `copy`: compatibility mode for inline `source_body`
  - `ffmpeg`: always use FFmpeg storyboard generation
  """
  @behaviour MaveCore.Flow.Step

  alias MaveCore.EncodingBooster
  alias MaveCore.Flow.Steps.Support, as: StepSupport
  alias MaveCore.Media.{RenditionSizing, Storage}

  @supported_modes ~w(auto copy ffmpeg)
  @default_max_thumbs_count 60

  @impl true
  def run(step_definition, context) do
    run_input = Map.get(context, :run_input, %{})
    dependency_outputs = Map.get(context, :dependency_outputs, %{})
    params = Map.get(step_definition, "params", %{})
    step_id = Map.get(step_definition, "id", "storyboard")

    source_url = Map.get(run_input, "input_url") || Map.get(run_input, "source_url")
    space_hash = Map.get(run_input, "space_hash")
    embed_hash = Map.get(run_input, "embed_hash")
    version = Map.get(run_input, "version", 0)
    region = Map.get(run_input, "region")
    codec = StepSupport.normalize_param_downcase(Map.get(params, "codec"), "jpg")
    size = StepSupport.normalize_param_downcase(Map.get(params, "size"), "sd")

    thumbs_count =
      normalize_positive_integer(Map.get(params, "count"), @default_max_thumbs_count)

    mode =
      StepSupport.normalize_mode(run_input, "media_generate_storyboard_mode", @supported_modes)

    strict? = StepSupport.strict_enabled?(params, run_input, "media_generate_storyboard_strict")
    storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter, Storage)
    bucket = Storage.bucket_for_space(space_hash, region)

    progress =
      StepSupport.ffmpeg_progress(Map.get(context, :progress_reporter), %{
        stage: "generate_storyboard",
        step_id: step_id,
        codec: codec,
        size: size,
        container: codec,
        total_ms: StepSupport.inspect_duration_ms(dependency_outputs)
      })

    if StepSupport.inspect_reports_no_video?(dependency_outputs) do
      {:ok, skipped_output(step_id, codec, size, "no video stream"), []}
    else
      generate_storyboard(
        run_input,
        dependency_outputs,
        source_url,
        space_hash,
        embed_hash,
        version,
        region,
        codec,
        size,
        thumbs_count,
        mode,
        strict?,
        storage_adapter,
        bucket,
        step_id,
        progress,
        Map.get(context, :progress_reporter),
        Map.get(context, :encoding_booster_dispatch),
        Map.get(context, :encoding_booster_fallback_code)
      )
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  defp generate_storyboard(
         run_input,
         dependency_outputs,
         source_url,
         space_hash,
         embed_hash,
         version,
         region,
         codec,
         size,
         thumbs_count,
         mode,
         strict?,
         storage_adapter,
         bucket,
         step_id,
         progress,
         progress_reporter,
         encoding_booster_dispatch,
         encoding_booster_fallback_code
       ) do
    with {:ok, space_hash} <- StepSupport.require_binary(space_hash, :space_hash),
         {:ok, embed_hash} <- StepSupport.require_binary(embed_hash, :embed_hash),
         {:ok, source_url} <- StepSupport.require_binary(source_url, :source_url),
         {:ok, image_key, vtt_key} <- build_keys(embed_hash, version, codec),
         {:ok, stored_storyboard, meta, actual_mode, mode_meta} <-
           build_and_put_storyboard(
             Map.merge(
               %{
                 bucket: bucket,
                 codec: codec,
                 dependency_outputs: dependency_outputs,
                 dispatch: encoding_booster_dispatch,
                 fallback_code: encoding_booster_fallback_code,
                 progress_reporter: progress_reporter,
                 region: region,
                 run_input: run_input,
                 source_url: source_url,
                 step_id: step_id,
                 storage_adapter: storage_adapter,
                 thumbs_count: thumbs_count
               },
               %{
                 image_key: image_key,
                 mode: mode,
                 progress: progress,
                 vtt_key: vtt_key
               }
             )
           ) do
      image_uri = stored_storyboard.image_uri
      image_size = stored_storyboard.image_size
      vtt_uri = stored_storyboard.vtt_uri
      vtt_size = stored_storyboard.vtt_size

      rendition =
        storyboard_rendition(codec, size, image_key, image_uri, vtt_uri, image_size, meta)

      output =
        %{
          "status" => "ok",
          "step_type" => "media.generate_storyboard",
          "mode" => actual_mode,
          "step_id" => step_id,
          "codec" => codec,
          "container" => codec,
          "size" => size,
          "image_key" => image_key,
          "image_uri" => image_uri,
          "vtt_key" => vtt_key,
          "vtt_uri" => vtt_uri,
          "file_size" => image_size,
          "rendition" => rendition,
          "renditions" => [rendition]
        }
        |> Map.merge(mode_meta)

      artifacts = [
        %{
          name: "storyboard",
          uri: image_uri,
          media_type: media_type(codec),
          size_bytes: image_size,
          metadata: %{
            "type" => "image",
            "role" => "storyboard",
            "codec" => codec,
            "space_hash" => space_hash,
            "embed_hash" => embed_hash,
            "version" => StepSupport.normalize_version(version)
          }
        },
        %{
          name: "storyboard_vtt",
          uri: vtt_uri,
          media_type: "text/vtt",
          size_bytes: vtt_size,
          metadata: %{
            "type" => "text",
            "role" => "storyboard",
            "space_hash" => space_hash,
            "embed_hash" => embed_hash,
            "version" => StepSupport.normalize_version(version)
          }
        }
      ]

      {:ok, output, artifacts}
    else
      {:error, {:encoding_booster_fallback_required, _code, _reason} = reason} ->
        {:error, reason}

      {:error, reason} when strict? ->
        {:error, {:media_generate_storyboard_failed, reason}}

      {:error, reason} ->
        {:ok, unavailable_output(step_id, codec, size, reason), []}
    end
  end

  defp build_and_put_storyboard(%{dispatch: :direct} = context) do
    generate_storyboard_with_booster(context, context.image_key, context.vtt_key)
  end

  defp build_and_put_storyboard(context) do
    with {:ok, image_body, vtt_body, meta, actual_mode, mode_meta} <-
           build_storyboard(
             context.mode,
             context.run_input,
             context.source_url,
             context.dependency_outputs,
             context.codec,
             context.thumbs_count,
             context.progress
           ),
         {:ok, image_uri} <-
           put_object(
             context.storage_adapter,
             context.bucket,
             context.image_key,
             image_body,
             media_type(context.codec),
             context.region
           ),
         {:ok, vtt_uri} <-
           put_object(
             context.storage_adapter,
             context.bucket,
             context.vtt_key,
             vtt_body,
             "text/vtt",
             context.region
           ) do
      mode_meta = maybe_put_fallback(mode_meta, context.fallback_code)

      {:ok,
       %{
         image_uri: image_uri,
         image_size: byte_size(image_body),
         vtt_uri: vtt_uri,
         vtt_size: byte_size(vtt_body)
       }, meta, actual_mode, mode_meta}
    end
  end

  defp generate_storyboard_with_booster(context, image_key, vtt_key) do
    duration = media_duration_seconds(context.dependency_outputs, 60.0)
    count = storyboard_frame_count(duration, context.thumbs_count)
    columns = min(count, 10)
    rows = max(div(count + columns - 1, columns), 1)
    {thumb_width, thumb_height} = storyboard_thumb_dimensions(context.dependency_outputs)

    meta = %{
      "thumbs_count" => count,
      "columns" => columns,
      "rows" => rows,
      "interval_seconds" => max(duration / max(count, 1), 1.0),
      "thumb_width" => thumb_width,
      "thumb_height" => thumb_height
    }

    with {:ok, input_url} <-
           StepSupport.encoding_booster_input_url(
             context.run_input,
             context.source_url,
             context.dependency_outputs,
             prefer_video_rendition: true,
             preferred_video_step_id: "video_h264_sd",
             preferred_video_sizes: ["sd"],
             preferred_video_codec: "h264"
           ),
         {:ok, session} <-
           context.storage_adapter.start_presigned_multipart_upload(
             context.bucket,
             image_key,
             context.region,
             media_type(context.codec),
             max_bytes: 64 * 1024 * 1024
           ) do
      upload_storyboard_with_booster(
        context,
        image_key,
        vtt_key,
        input_url,
        session,
        duration,
        meta
      )
    else
      {:error, reason} -> booster_error(reason)
    end
  end

  defp upload_storyboard_with_booster(
         context,
         image_key,
         vtt_key,
         input_url,
         session,
         duration,
         meta
       ) do
    options =
      [
        operation: "storyboard",
        frame_codec: context.codec,
        duration_seconds: duration,
        count: meta["thumbs_count"],
        on_chunk: booster_progress_callback(context)
      ]
      |> maybe_add_encoding_booster_referer(input_url)

    case encoding_booster_adapter().encode_to_storage(input_url, session.payload, options) do
      {:ok, timing} ->
        verify_booster_storyboard(context, image_key, vtt_key, timing, duration, meta)

      {:error, reason} ->
        _ = context.storage_adapter.abort_presigned_multipart_upload(session)
        booster_error(reason)
    end
  end

  defp verify_booster_storyboard(context, image_key, vtt_key, timing, duration, meta) do
    with {:ok, %{size_bytes: image_size}} when is_integer(image_size) and image_size > 0 <-
           context.storage_adapter.object_info(context.bucket, image_key, context.region),
         vtt_body <-
           build_vtt(
             duration,
             meta["thumbs_count"],
             meta["rows"],
             meta["columns"],
             meta["thumb_width"],
             meta["thumb_height"],
             "storyboard.jpg"
           ),
         {:ok, vtt_uri} <-
           put_object(
             context.storage_adapter,
             context.bucket,
             vtt_key,
             vtt_body,
             "text/vtt",
             context.region
           ) do
      report_booster_completed(context, timing, image_size)

      mode_meta =
        %{
          "encoding_booster" => true,
          "encoding_booster_elapsed_ms" => Map.get(timing, :elapsed_ms, 0)
        }
        |> maybe_put_booster_instance(timing)

      {:ok,
       %{
         image_uri: "s3://#{context.bucket}/#{image_key}",
         image_size: image_size,
         vtt_uri: vtt_uri,
         vtt_size: byte_size(vtt_body)
       }, meta, "encoding_booster", mode_meta}
    else
      {:error, reason} -> booster_error({:storyboard_upload_verification_failed, reason})
      _other -> booster_error({:storyboard_upload_verification_failed, :empty_object})
    end
  end

  defp build_storyboard(
         "copy",
         run_input,
         source_url,
         dependency_outputs,
         _codec,
         thumbs_count,
         _progress
       ) do
    with {:ok, source_body} <-
           StepSupport.resolve_source_body(run_input, source_url, dependency_outputs) do
      vtt_body = build_vtt(10.0, thumbs_count, 1, thumbs_count, 320, 180, "storyboard.jpg")
      meta = %{"thumbs_count" => thumbs_count, "columns" => thumbs_count, "rows" => 1}
      {:ok, source_body, vtt_body, meta, "copy", %{}}
    end
  end

  defp build_storyboard(
         "ffmpeg",
         run_input,
         source_url,
         dependency_outputs,
         codec,
         thumbs_count,
         progress
       ) do
    generate_with_ffmpeg(
      run_input,
      source_url,
      dependency_outputs,
      codec,
      thumbs_count,
      progress
    )
  end

  defp build_storyboard(
         "auto",
         run_input,
         source_url,
         dependency_outputs,
         codec,
         thumbs_count,
         progress
       ) do
    if Map.has_key?(run_input, "source_body") do
      build_storyboard(
        "copy",
        run_input,
        source_url,
        dependency_outputs,
        codec,
        thumbs_count,
        progress
      )
    else
      generate_with_ffmpeg(
        run_input,
        source_url,
        dependency_outputs,
        codec,
        thumbs_count,
        progress
      )
    end
  end

  defp generate_with_ffmpeg(
         run_input,
         source_url,
         dependency_outputs,
         codec,
         thumbs_count,
         progress
       ) do
    StepSupport.with_temp_dir("storyboard", fn tmp_dir ->
      with {:ok, ffmpeg_bin} <- StepSupport.find_ffmpeg(),
           {:ok, input_ref} <-
             StepSupport.prepare_ffmpeg_input(
               tmp_dir,
               run_input,
               source_url,
               dependency_outputs,
               prefer_video_rendition: true,
               preferred_video_step_id: "video_h264_sd",
               preferred_video_sizes: ["sd"],
               preferred_video_codec: "h264"
             ),
           duration <- probe_duration(input_ref),
           {:ok, image_path, meta} <-
             generate_storyboard_image(
               ffmpeg_bin,
               input_ref,
               tmp_dir,
               codec,
               duration,
               thumbs_count,
               progress
             ),
           {:ok, image_body} <- StepSupport.read_tmp_file(image_path),
           {:ok, width, height} <- probe_image_dimensions(image_path),
           {:ok, vtt_body} <- build_storyboard_vtt(meta, width, height, duration) do
        {:ok, image_body, vtt_body, meta, "ffmpeg", %{}}
      else
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp generate_storyboard_image(
         ffmpeg_bin,
         input_ref,
         tmp_dir,
         codec,
         duration,
         thumbs_count,
         progress
       ) do
    count = storyboard_frame_count(duration, thumbs_count)
    cols = min(count, 10)
    rows = max(div(count + cols - 1, cols), 1)
    interval = max(duration / max(count, 1), 1.0)
    interval_str = :erlang.float_to_binary(interval, decimals: 3)

    with {:ok, output_path} <- StepSupport.tmp_file_path(tmp_dir, "storyboard", codec) do
      vf = "fps=1/#{interval_str},scale=320:-2,setsar=1,tile=#{cols}x#{rows}"

      args =
        [
          "-y",
          "-hide_banner",
          "-loglevel",
          "error",
          "-i",
          input_ref,
          "-vf",
          vf,
          "-frames:v",
          "1"
        ] ++ codec_args(codec) ++ [output_path]

      case StepSupport.run_media_cmd(ffmpeg_bin, args, progress: progress) do
        {_, 0} ->
          {:ok, output_path,
           %{
             "thumbs_count" => count,
             "columns" => cols,
             "rows" => rows,
             "interval_seconds" => interval
           }}

        {stderr, status} ->
          {:error, {:ffmpeg_exit, status, StepSupport.truncate_binary(stderr, 1000)}}
      end
    end
  end

  defp storyboard_thumb_dimensions(dependency_outputs) do
    resolution =
      dependency_outputs
      |> Map.get("video_h264_sd", %{})
      |> then(fn output ->
        Map.get(output, "resolution") ||
          get_in(output, ["variant_outputs", "sd", "resolution"])
      end)
      |> case do
        value when is_binary(value) ->
          value

        _other ->
          dependency_outputs
          |> Map.get("inspect_media", %{})
          |> then(&RenditionSizing.scaled_resolution("sd", &1))
          |> case do
            {:ok, value} -> value
            {:error, _reason} -> nil
          end
      end

    case parse_resolution(resolution) do
      {:ok, source_width, source_height} ->
        height =
          source_height
          |> Kernel.*(320)
          |> Kernel./(source_width)
          |> round()
          |> div(2)
          |> max(1)
          |> Kernel.*(2)

        {320, height}

      :error ->
        {320, 180}
    end
  end

  defp parse_resolution(resolution) when is_binary(resolution) do
    case String.split(resolution, "x", parts: 2) do
      [width, height] ->
        with {width, ""} when width > 0 <- Integer.parse(width),
             {height, ""} when height > 0 <- Integer.parse(height) do
          {:ok, width, height}
        else
          _other -> :error
        end

      _other ->
        :error
    end
  end

  defp parse_resolution(_resolution), do: :error

  defp build_storyboard_vtt(meta, width, height, duration) do
    count = meta["thumbs_count"]
    cols = meta["columns"]
    rows = max(meta["rows"], 1)
    thumb_width = max(div(width, max(cols, 1)), 1)
    thumb_height = max(div(height, max(rows, 1)), 1)

    vtt =
      build_vtt(duration, count, rows, cols, thumb_width, thumb_height, "storyboard.jpg")

    {:ok, vtt}
  end

  defp build_vtt(duration, count, _rows, cols, thumb_width, thumb_height, ref) do
    cues =
      0..(count - 1)
      |> Enum.map(fn index ->
        start_seconds = index * (duration / max(count, 1))
        end_seconds = min(duration, (index + 1) * (duration / max(count, 1)))

        x = rem(index, cols) * thumb_width
        y = div(index, cols) * thumb_height

        [
          format_time(start_seconds),
          " --> ",
          format_time(max(end_seconds, start_seconds + 0.1)),
          "\n",
          ref,
          "#xywh=",
          Integer.to_string(x),
          ",",
          Integer.to_string(y),
          ",",
          Integer.to_string(thumb_width),
          ",",
          Integer.to_string(thumb_height),
          "\n\n"
        ]
      end)

    ["WEBVTT\n\n", cues]
    |> IO.iodata_to_binary()
  end

  defp format_time(seconds) do
    total_ms = trunc(max(seconds, 0.0) * 1000)
    hours = div(total_ms, 3_600_000)
    minutes = div(rem(total_ms, 3_600_000), 60_000)
    secs = div(rem(total_ms, 60_000), 1000)
    millis = rem(total_ms, 1000)
    :io_lib.format("~2..0B:~2..0B:~2..0B.~3..0B", [hours, minutes, secs, millis]) |> to_string()
  end

  defp put_object(storage_adapter, bucket, key, body, content_type, region) do
    case storage_adapter.put_public(bucket, key, body, content_type, region) do
      {:ok, _body} -> {:ok, "s3://#{bucket}/#{key}"}
      {:error, reason} -> {:error, {:upload_failed, key, reason}}
    end
  end

  defp build_keys(embed_hash, version, codec) do
    with {:ok, embed_hash} <- StepSupport.require_binary(embed_hash, :embed_hash),
         {:ok, codec} <- StepSupport.require_binary(codec, :codec) do
      image_filename = "storyboard.#{codec}"
      vtt_filename = "storyboard.vtt"

      if StepSupport.normalize_version(version) > 0 do
        {:ok, "#{embed_hash}/v#{StepSupport.normalize_version(version)}/#{image_filename}",
         "#{embed_hash}/v#{StepSupport.normalize_version(version)}/#{vtt_filename}"}
      else
        {:ok, "#{embed_hash}/#{image_filename}", "#{embed_hash}/#{vtt_filename}"}
      end
    end
  end

  defp storyboard_rendition(codec, size, image_key, image_uri, vtt_uri, image_size, meta) do
    %{
      "type" => "storyboard",
      "codec" => codec,
      "container" => codec,
      "size" => size,
      "progress" => 100.0,
      "rendition_key" => image_key,
      "src" => image_uri,
      "vtt_src" => vtt_uri,
      "file_size" => image_size,
      "thumbs_count" => meta["thumbs_count"],
      "columns" => meta["columns"],
      "rows" => meta["rows"]
    }
  end

  defp probe_duration(input_ref) do
    case StepSupport.find_ffprobe() do
      {:error, :ffprobe_not_found} ->
        60.0

      {:ok, ffprobe_bin} ->
        args = [
          "-v",
          "error",
          "-show_entries",
          "format=duration",
          "-of",
          "default=noprint_wrappers=1:nokey=1",
          input_ref
        ]

        case StepSupport.run_media_cmd(ffprobe_bin, args) do
          {duration_raw, 0} ->
            duration_raw
            |> String.trim()
            |> parse_float(60.0)
            |> max(1.0)

          _ ->
            60.0
        end
    end
  end

  defp probe_image_dimensions(image_path) do
    case StepSupport.find_ffprobe() do
      {:error, :ffprobe_not_found} ->
        {:ok, 3200, 180}

      {:ok, ffprobe_bin} ->
        args = [
          "-v",
          "error",
          "-select_streams",
          "v:0",
          "-show_entries",
          "stream=width,height",
          "-of",
          "csv=p=0:s=x",
          image_path
        ]

        case StepSupport.run_media_cmd(ffprobe_bin, args) do
          {raw, 0} ->
            parse_storyboard_dimensions(raw)

          _ ->
            {:ok, 3200, 180}
        end
    end
  end

  defp parse_storyboard_dimensions(raw) do
    case String.trim(raw) |> String.split("x", parts: 2) do
      [w, h] ->
        {:ok, parse_integer(w, 3200), parse_integer(h, 180)}

      _ ->
        {:ok, 3200, 180}
    end
  end

  # Keep JPEG generation compatible with FFmpeg 7+ strict compliance defaults.
  defp codec_args("jpg"), do: ["-c:v", "mjpeg", "-strict", "unofficial", "-q:v", "6"]
  defp codec_args("jpeg"), do: ["-c:v", "mjpeg", "-strict", "unofficial", "-q:v", "6"]
  defp codec_args("webp"), do: ["-c:v", "libwebp", "-quality", "80"]
  defp codec_args(_), do: ["-c:v", "mjpeg", "-strict", "unofficial", "-q:v", "6"]

  defp media_type("jpg"), do: "image/jpeg"
  defp media_type("jpeg"), do: "image/jpeg"
  defp media_type("webp"), do: "image/webp"
  defp media_type(_), do: "application/octet-stream"

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0,
    do: value

  defp normalize_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp normalize_positive_integer(_, default), do: default

  defp storyboard_frame_count(duration, max_count)
       when is_number(duration) and is_integer(max_count) and max_count > 0 do
    duration
    |> ceil()
    |> max(1)
    |> min(max_count)
  end

  defp storyboard_frame_count(_duration, max_count), do: max(max_count, 1)

  defp parse_float(value, default) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _rest} -> parsed
      :error -> default
    end
  end

  defp parse_float(_, default), do: default

  defp parse_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} -> parsed
      :error -> default
    end
  end

  defp parse_integer(_, default), do: default

  defp media_duration_seconds(dependency_outputs, default) do
    case StepSupport.inspect_duration_ms(dependency_outputs) do
      duration_ms when is_integer(duration_ms) and duration_ms > 0 -> duration_ms / 1_000
      _other -> default
    end
  end

  defp booster_progress_callback(context) do
    fn bytes ->
      StepSupport.report_progress(context.progress_reporter, %{
        "source" => "encoding_booster",
        "executor" => "encoding_booster",
        "status" => "generating",
        "stage" => "generate_storyboard",
        "step_id" => context.step_id,
        "codec" => context.codec,
        "total_size_bytes" => bytes
      })
    end
  end

  defp report_booster_completed(context, timing, size_bytes) do
    total_ms = StepSupport.inspect_duration_ms(context.dependency_outputs)
    ffmpeg_elapsed_ms = Map.get(timing, :ffmpeg_elapsed_ms) || Map.get(timing, :elapsed_ms)

    StepSupport.report_progress(context.progress_reporter, %{
      "source" => "ffmpeg",
      "executor" => "encoding_booster",
      "status" => "completed",
      "stage" => "generate_storyboard",
      "step_id" => context.step_id,
      "codec" => context.codec,
      "percent" => 100.0,
      "total_ms" => total_ms,
      "ffmpeg_elapsed_ms" => ffmpeg_elapsed_ms,
      "speed_x" => derived_speed(total_ms, ffmpeg_elapsed_ms),
      "total_size_bytes" => size_bytes,
      "force" => true
    })
  end

  defp derived_speed(total_ms, elapsed_ms)
       when is_integer(total_ms) and is_integer(elapsed_ms) and elapsed_ms > 0,
       do: total_ms / elapsed_ms

  defp derived_speed(_total_ms, _elapsed_ms), do: nil

  defp maybe_add_encoding_booster_referer(options, input_url) do
    if Storage.ffmpeg_storage_url?(input_url) do
      case Storage.ffmpeg_input_referer() do
        referer when is_binary(referer) -> Keyword.put(options, :input_referer, referer)
        _other -> options
      end
    else
      options
    end
  end

  defp encoding_booster_adapter do
    Application.get_env(:mave_core, :encoding_booster_adapter, EncodingBooster)
  end

  defp booster_error(:encoding_booster_busy), do: {:error, :encoding_booster_busy}

  defp booster_error(reason) do
    if EncodingBooster.fallback_enabled?() do
      {:error, {:encoding_booster_fallback_required, encoding_booster_error_code(reason), reason}}
    else
      {:error, reason}
    end
  end

  defp encoding_booster_error_code(reason) do
    reason
    |> inspect(limit: 10, printable_limit: 200)
    |> String.replace(~r/[^a-zA-Z0-9]+/, "_")
    |> String.trim("_")
    |> String.downcase()
    |> String.slice(0, 80)
    |> case do
      "" -> "error"
      code -> code
    end
  end

  defp maybe_put_booster_instance(metadata, %{instance_id: instance_id})
       when is_binary(instance_id),
       do: Map.put(metadata, "encoding_booster_instances", [instance_id])

  defp maybe_put_booster_instance(metadata, _timing), do: metadata

  defp maybe_put_fallback(metadata, nil), do: metadata

  defp maybe_put_fallback(metadata, code),
    do: Map.put(metadata, "encoding_booster_fallback", code)

  defp unavailable_output(step_id, codec, size, reason) do
    %{
      "status" => "unavailable",
      "step_type" => "media.generate_storyboard",
      "mode" => "failed",
      "step_id" => step_id,
      "codec" => codec,
      "size" => size,
      "error" => inspect(reason)
    }
  end

  defp skipped_output(step_id, codec, size, reason) do
    %{
      "status" => "skipped",
      "step_type" => "media.generate_storyboard",
      "mode" => "skipped",
      "step_id" => step_id,
      "codec" => codec,
      "container" => codec,
      "size" => size,
      "reason" => reason
    }
  end
end
