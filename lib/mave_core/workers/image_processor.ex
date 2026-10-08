defmodule MaveCore.Workers.ImageProcessor do
  @moduledoc """
  Worker module to process video segments into images using FLAME.
  Supports jpg, webp, and avif output formats.
  """
  require Logger
  alias MaveCore.Flow.Steps.Support, as: StepSupport

  alias MaveCore.Media.{
    ImageGenerationBudget,
    ImageGenerationCoordinator,
    ImageVariantBudget,
    Manifest,
    Playlist,
    Storage
  }

  @default_generation_lock_ttl_ms 10 * 60 * 1000
  @default_generation_wait_timeout_ms 3 * 60 * 1000
  @default_generation_wait_poll_ms 500
  @dimension_steps [160, 320, 480, 640, 960, 1280, 1920, 2560, 3840]

  @format_config %{
    # Note: yuvj420p converts limited-range YUV (tv) to full-range for JPEG compatibility
    "jpg" => %{
      ext: "jpg",
      content_type: "image/jpeg",
      codec_args: ["-pix_fmt", "yuvj420p", "-q:v", "2"]
    },
    "jpeg" => %{
      ext: "jpg",
      content_type: "image/jpeg",
      codec_args: ["-pix_fmt", "yuvj420p", "-q:v", "2"]
    },
    "webp" => %{ext: "webp", content_type: "image/webp", codec_args: ["-quality", "85"]},
    "avif" => %{ext: "avif", content_type: "image/avif", codec_args: ["-crf", "23"]}
  }

  @doc """
  Generates an image for a given space, embed, and time.
  Checks S3 cache first - only generates via FLAME if not already cached.
  Supports formats: jpg, jpeg, webp, avif (via opts[:format])
  """
  def process(space_hash, embed_hash, time, opts \\ []) do
    region = MaveCore.Spaces.get_region(space_hash)
    storage = storage_module()
    bucket = storage.bucket_for_space(space_hash, region)
    manifest_path = "#{embed_hash}/manifest.json"

    with {:ok, manifest_json} <- storage.get(bucket, manifest_path, region),
         {:ok, manifest} <- Manifest.parse(manifest_json) do
      legacy_output_path = build_output_path(embed_hash, manifest, time, opts)

      case storage.get(bucket, legacy_output_path, region) do
        {:ok, cached_data} ->
          {:ok, legacy_output_path, cached_data}

        _cache_miss_or_error ->
          prepare_and_handle_request(
            storage,
            bucket,
            space_hash,
            embed_hash,
            manifest,
            time,
            opts,
            region
          )
      end
    else
      {:error, :not_found} ->
        {:error, :not_found}

      error ->
        Logger.error("Failed to load manifest for image generation: #{inspect(error)}")
        error
    end
  end

  defp prepare_and_handle_request(
         storage,
         bucket,
         space_hash,
         embed_hash,
         manifest,
         time,
         opts,
         region
       ) do
    with {:ok, request} <-
           prepare_request_for_cache(
             storage,
             bucket,
             embed_hash,
             manifest,
             time,
             opts,
             region
           ) do
      request
      |> Map.merge(%{
        storage: storage,
        bucket: bucket,
        space_hash: space_hash,
        embed_hash: embed_hash,
        manifest: manifest,
        region: region,
        output_path: build_output_path(embed_hash, manifest, request.time, request.opts)
      })
      |> handle_cached_image()
    end
  end

  @doc false
  def cache_output_path(embed_hash, manifest, time, opts \\ []) do
    build_output_path(embed_hash, manifest, time, opts)
  end

  defp build_output_path(embed_hash, manifest, time, opts) do
    suffix = build_dimension_suffix(opts)
    format = opts[:format] || "jpg"
    ext = get_format_config(format).ext
    filename = "#{embed_hash}_#{time}#{suffix}.#{ext}"
    asset_base = Manifest.asset_base_path(embed_hash, manifest)

    case Path.relative_to(asset_base, embed_hash) do
      "." ->
        Path.join([embed_hash, "_images", filename])

      relative_version ->
        Path.join([embed_hash, "_images", relative_version, filename])
    end
  end

  defp build_dimension_suffix(opts) do
    case {opts[:width], opts[:height]} do
      {nil, nil} -> ""
      {w, nil} -> "_w#{w}"
      {nil, h} -> "_h#{h}"
      {w, h} -> "_#{w}x#{h}"
    end
  end

  defp get_format_config(format) do
    Map.get(@format_config, format, @format_config["jpg"])
  end

  defp prepare_request(storage, bucket, embed_hash, manifest, time, opts, region) do
    canonical_time = Float.round(time * 1.0, 1)
    requested_opts = canonicalize_requested_dimensions(opts)

    with {:ok, asset_base, root_content} <-
           load_source_playlist(storage, bucket, embed_hash, manifest, region),
         {:ok, variant_path, variant_resolution} <-
           Playlist.select_variant(root_content, requested_opts),
         :ok <- validate_requested_dimensions(requested_opts, variant_resolution),
         canonical_opts = Playlist.clamp_opts(requested_opts, variant_resolution),
         full_variant_path = Path.join(asset_base, variant_path),
         {:ok, variant_content} <- storage.get(bucket, full_variant_path, region),
         {:ok, segment_info} <- Playlist.segment_at_time(variant_content, canonical_time) do
      segment_end = segment_info.start + segment_info.duration
      effective_time = canonical_time |> min(segment_end - 0.1) |> max(segment_info.start)

      {:ok,
       %{
         time: Float.round(effective_time, 1),
         opts: canonical_opts,
         source_available: true,
         source_asset_base: asset_base,
         variant_path: variant_path,
         segment_info: segment_info
       }}
    end
  end

  defp prepare_request_for_cache(storage, bucket, embed_hash, manifest, time, opts, region) do
    canonical_time = Float.round(time * 1.0, 1)

    case prepare_request(storage, bucket, embed_hash, manifest, time, opts, region) do
      {:error, :not_found} when canonical_time == 0.0 ->
        if is_nil(opts[:width]) and is_nil(opts[:height]) do
          {:ok, %{time: 0.0, opts: opts, source_available: false}}
        else
          {:error, :not_found}
        end

      result ->
        result
    end
  end

  defp load_source_playlist(storage, bucket, embed_hash, manifest, region) do
    embed_hash
    |> source_asset_base_candidates(manifest)
    |> Enum.reduce_while({:error, :not_found}, fn asset_base, _acc ->
      case storage.get(bucket, Path.join(asset_base, "playlist.m3u8"), region) do
        {:ok, content} -> {:halt, {:ok, asset_base, content}}
        {:error, :not_found} -> {:cont, {:error, :not_found}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_requested_dimensions(opts, nil) do
    if opts[:width] || opts[:height], do: {:error, :unsupported_dimensions}, else: :ok
  end

  defp validate_requested_dimensions(_opts, {_width, _height}), do: :ok

  defp canonicalize_requested_dimensions(opts) do
    opts
    |> Keyword.update(:width, nil, &canonical_dimension/1)
    |> Keyword.update(:height, nil, &canonical_dimension/1)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp canonical_dimension(nil), do: nil

  defp canonical_dimension(requested), do: Enum.min_by(@dimension_steps, &abs(&1 - requested))

  defp generate_image(ctx) do
    Logger.info(
      "Starting image generation for #{ctx.space_hash}/#{ctx.embed_hash} at #{ctx.time}s region=#{ctx.region} opts: #{inspect(ctx.opts)}"
    )

    storage = storage_module()
    bucket = storage.bucket_for_space(ctx.space_hash, ctx.region)
    format_config = get_format_config(ctx.opts[:format] || "jpg")

    with {:ok, full_data} <-
           fetch_full_segment_data(
             storage,
             bucket,
             ctx.source_asset_base,
             ctx.variant_path,
             ctx.segment_info,
             ctx.region
           ),
         {:ok, image_data} <-
           extract_frame(
             full_data,
             ctx.segment_info.start,
             ctx.time,
             ctx.opts,
             format_config
           ) do
      case storage.put_public(
             bucket,
             ctx.output_path,
             image_data,
             format_config.content_type,
             ctx.region
           ) do
        {:ok, _} -> {:ok, ctx.output_path, image_data}
        err -> err
      end
    else
      error ->
        Logger.error("Failed to generate image: #{inspect(error)}")
        error
    end
  end

  defp fetch_full_segment_data(storage, bucket, embed_hash, playlist_path, segment_info, region) do
    base_dir = Path.dirname(playlist_path)
    segment_path = Path.join([embed_hash, base_dir, segment_info.segment])

    with {:ok, segment_data} <- storage.get(bucket, segment_path, region) do
      Logger.info("Segment info init: #{inspect(segment_info[:init])}")

      maybe_prepend_init_segment(
        storage,
        bucket,
        embed_hash,
        base_dir,
        segment_info,
        segment_data,
        region
      )
    end
  end

  defp handle_cached_image(ctx) do
    case ctx.storage.get(ctx.bucket, ctx.output_path, ctx.region) do
      {:ok, cached_data} ->
        Logger.info("Cache hit for #{ctx.output_path}")
        {:ok, ctx.output_path, cached_data}

      {:error, :not_found} ->
        maybe_generate_for_cache_miss(ctx)

      {:error, reason} ->
        Logger.warning("S3 check failed: #{inspect(reason)}, falling back to generation")

        generate_via_flame_singleflight(ctx)
    end
  end

  defp maybe_generate_for_cache_miss(ctx) do
    case existing_thumbnail_for_default_request(ctx) do
      {:ok, thumbnail_path, image_data} ->
        seed_cached_image_from_thumbnail(ctx, thumbnail_path, image_data)

      :not_applicable ->
        maybe_generate_from_source_playlist(ctx)

      {:error, _reason} ->
        maybe_generate_from_source_playlist(ctx)
    end
  end

  defp maybe_generate_from_source_playlist(%{source_available: false} = ctx) do
    Logger.warning(
      "Skipping image generation for #{ctx.space_hash}/#{ctx.embed_hash}: source playlist not found"
    )

    {:error, :not_found}
  end

  defp maybe_generate_from_source_playlist(ctx) do
    generate_via_flame_singleflight(ctx)
  end

  defp existing_thumbnail_for_default_request(ctx) do
    format = ctx.opts[:format] || "jpg"

    if default_thumbnail_request?(ctx.time, ctx.opts) and format in ["jpg", "jpeg", "webp"] do
      thumbnail_path = "#{ctx.embed_hash}/thumbnail.#{get_format_config(format).ext}"

      case ctx.storage.get(ctx.bucket, thumbnail_path, ctx.region) do
        {:ok, image_data} -> {:ok, thumbnail_path, image_data}
        {:error, :not_found} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    else
      :not_applicable
    end
  end

  defp default_thumbnail_request?(time, opts) do
    time in [0, 0.0] and is_nil(opts[:width]) and is_nil(opts[:height])
  end

  defp seed_cached_image_from_thumbnail(ctx, thumbnail_path, image_data) do
    format_config = get_format_config(ctx.opts[:format] || "jpg")

    Logger.info(
      "Using existing thumbnail #{thumbnail_path} for #{ctx.space_hash}/#{ctx.embed_hash} image cache miss"
    )

    case ctx.storage.put_public(
           ctx.bucket,
           ctx.output_path,
           image_data,
           format_config.content_type,
           ctx.region
         ) do
      {:ok, _} ->
        {:ok, ctx.output_path, image_data}

      {:error, reason} ->
        Logger.warning(
          "Failed to seed image cache #{ctx.output_path} from #{thumbnail_path}: #{inspect(reason)}"
        )

        {:ok, thumbnail_path, image_data}
    end
  end

  defp source_asset_base_candidates(embed_hash, manifest) do
    [Manifest.asset_base_path(embed_hash, manifest), embed_hash]
    |> Enum.uniq()
  end

  defp generate_via_flame(ctx) do
    flame_caller().call(image_flame_pool(), fn ->
      generate_image(ctx)
    end)
  rescue
    error ->
      Logger.error(
        "Image generation via FLAME failed for #{ctx.output_path}: #{Exception.message(error)}"
      )

      {:error, {:flame_execution_failed, Exception.message(error)}}
  catch
    :exit, :timeout ->
      Logger.warning("Image generation via FLAME timed out while waiting for #{ctx.output_path}")
      {:error, :generation_in_progress}

    :exit, {:timeout, _details} ->
      Logger.warning("Image generation via FLAME timed out while waiting for #{ctx.output_path}")
      {:error, :generation_in_progress}

    :exit, reason ->
      Logger.error("Image generation via FLAME exited for #{ctx.output_path}: #{inspect(reason)}")
      {:error, {:flame_execution_failed, reason}}
  end

  defp generate_via_flame_singleflight(ctx) do
    lock_key = image_generation_lock_key(ctx.bucket, ctx.region, ctx.output_path)
    lock_module = image_generation_lock_module()

    case lock_module.claim(lock_key, generation_lock_ttl_ms()) do
      {:ok, owner_id} ->
        generate_with_claimed_image_lock(ctx, lock_module, lock_key, owner_id)

      :busy ->
        Logger.info(
          "Image generation already in progress for #{ctx.output_path}, waiting for cached result"
        )

        wait_for_generated_image(ctx, lock_module, lock_key)

      {:error, reason} ->
        Logger.warning(
          "Image generation lock failed for #{ctx.output_path}: #{inspect(reason)}, generating without coordination"
        )

        generate_via_flame_from_context(ctx)
    end
  end

  defp generate_with_claimed_image_lock(ctx, lock_module, lock_key, owner_id) do
    case ctx.storage.get(ctx.bucket, ctx.output_path, ctx.region) do
      {:ok, cached_data} ->
        Logger.info("Cache hit for #{ctx.output_path} after claiming image generation")
        {:ok, ctx.output_path, cached_data}

      {:error, :not_found} ->
        Logger.info("Cache miss for #{ctx.output_path}, claimed image generation via FLAME")
        generate_via_flame_from_context(ctx)

      {:error, reason} ->
        Logger.warning(
          "S3 recheck failed after claiming #{ctx.output_path}: #{inspect(reason)}, generating via FLAME"
        )

        generate_via_flame_from_context(ctx)
    end
  after
    release_image_generation_lock(lock_module, lock_key, owner_id)
  end

  defp wait_for_generated_image(ctx, lock_module, lock_key) do
    deadline = System.monotonic_time(:millisecond) + generation_wait_timeout_ms()
    do_wait_for_generated_image(ctx, lock_module, lock_key, deadline)
  end

  defp do_wait_for_generated_image(ctx, lock_module, lock_key, deadline) do
    case ctx.storage.get(ctx.bucket, ctx.output_path, ctx.region) do
      {:ok, cached_data} ->
        Logger.info("Cache filled for #{ctx.output_path} while waiting for image generation")
        {:ok, ctx.output_path, cached_data}

      {:error, :not_found} ->
        continue_or_retry_image_generation_wait(ctx, lock_module, lock_key, deadline)

      {:error, reason} ->
        Logger.warning(
          "S3 wait check failed for #{ctx.output_path}: #{inspect(reason)}, continuing image generation wait"
        )

        continue_or_retry_image_generation_wait(ctx, lock_module, lock_key, deadline)
    end
  end

  defp continue_or_retry_image_generation_wait(ctx, lock_module, lock_key, deadline) do
    remaining_ms = deadline - System.monotonic_time(:millisecond)

    if remaining_ms <= 0 do
      retry_claim_after_image_generation_wait(ctx, lock_module, lock_key)
    else
      Process.sleep(min(generation_wait_poll_ms(), remaining_ms))
      do_wait_for_generated_image(ctx, lock_module, lock_key, deadline)
    end
  end

  defp retry_claim_after_image_generation_wait(ctx, lock_module, lock_key) do
    case lock_module.claim(lock_key, generation_lock_ttl_ms()) do
      {:ok, owner_id} ->
        Logger.warning("Retrying image generation for #{ctx.output_path} after wait timeout")
        generate_with_claimed_image_lock(ctx, lock_module, lock_key, owner_id)

      :busy ->
        Logger.warning("Timed out waiting for in-flight image generation of #{ctx.output_path}")
        {:error, :generation_in_progress}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp generate_via_flame_from_context(ctx) do
    case image_generation_budget_module().reserve(ctx.space_hash, ctx.embed_hash) do
      :ok ->
        generate_with_variant_reservation(ctx)

      {:error, {:rate_limited, retry_after_ms}} = error ->
        Logger.warning(
          "Image generation rate limited for #{ctx.space_hash}/#{ctx.embed_hash}; retry in #{retry_after_ms}ms"
        )

        error

      {:error, {:unavailable, reason}} ->
        Logger.error(
          "Image generation budget unavailable for #{ctx.space_hash}/#{ctx.embed_hash}: #{inspect(reason)}"
        )

        {:error, :generation_budget_unavailable}

      other ->
        Logger.error(
          "Unexpected image generation budget result for #{ctx.space_hash}/#{ctx.embed_hash}: #{inspect(other)}"
        )

        {:error, :generation_budget_unavailable}
    end
  end

  defp generate_with_variant_reservation(ctx) do
    case image_variant_budget_module().reserve(
           ctx.space_hash,
           ctx.embed_hash,
           ctx.output_path
         ) do
      {:ok, reservation} ->
        Logger.debug(
          "Image variant reservation #{reservation} for #{ctx.space_hash}/#{ctx.embed_hash}/#{ctx.output_path}"
        )

        generate_via_flame(ctx)

      {:error, :limit_reached} ->
        {:error, :variant_limit_reached}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, {:unavailable, reason}} ->
        Logger.error(
          "Image variant budget unavailable for #{ctx.space_hash}/#{ctx.embed_hash}: #{inspect(reason)}"
        )

        {:error, :generation_budget_unavailable}

      other ->
        Logger.error(
          "Unexpected image variant budget result for #{ctx.space_hash}/#{ctx.embed_hash}: #{inspect(other)}"
        )

        {:error, :generation_budget_unavailable}
    end
  end

  defp release_image_generation_lock(lock_module, lock_key, owner_id) do
    case lock_module.release(lock_key, owner_id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to release image generation lock #{lock_key}: #{inspect(reason)}")
    end
  end

  defp image_generation_lock_key(bucket, region, output_path) do
    [bucket, region || "default", output_path]
    |> Enum.join(":")
  end

  defp image_generation_lock_module do
    Application.get_env(
      :mave_core,
      :image_generation_coordinator_module,
      ImageGenerationCoordinator
    )
  end

  defp image_generation_budget_module do
    Application.get_env(
      :mave_core,
      :image_generation_budget_module,
      ImageGenerationBudget
    )
  end

  defp image_variant_budget_module do
    Application.get_env(
      :mave_core,
      :image_variant_budget_module,
      ImageVariantBudget
    )
  end

  defp flame_caller do
    Application.get_env(:mave_core, :image_flame_caller, FLAME)
  end

  defp image_flame_pool do
    Application.get_env(:mave_core, :image_flame_pool, MaveCore.Workers.FlameRunner)
  end

  defp generation_lock_ttl_ms do
    singleflight_config(:lock_ttl_ms, @default_generation_lock_ttl_ms)
  end

  defp generation_wait_timeout_ms do
    singleflight_config(:wait_timeout_ms, @default_generation_wait_timeout_ms)
  end

  defp generation_wait_poll_ms do
    singleflight_config(:wait_poll_ms, @default_generation_wait_poll_ms)
  end

  defp singleflight_config(key, default) do
    :mave_core
    |> Application.get_env(:image_generation_singleflight, [])
    |> Access.get(key, default)
  end

  defp maybe_prepend_init_segment(
         storage,
         bucket,
         embed_hash,
         base_dir,
         segment_info,
         segment_data,
         region
       ) do
    case segment_info[:init] do
      init_segment when is_binary(init_segment) ->
        prepend_init_segment(
          storage,
          bucket,
          embed_hash,
          base_dir,
          init_segment,
          segment_data,
          region
        )

      _ ->
        {:ok, segment_data}
    end
  end

  defp prepend_init_segment(
         storage,
         bucket,
         embed_hash,
         base_dir,
         init_segment,
         segment_data,
         region
       ) do
    init_path = Path.join([embed_hash, base_dir, init_segment])
    Logger.info("Fetching init segment at #{init_path}")

    case storage.get(bucket, init_path, region) do
      {:ok, init_data} ->
        Logger.info("Init segment fetched, size: #{byte_size(init_data)}")
        {:ok, init_data <> segment_data}

      error ->
        Logger.warning("Failed to fetch init segment: #{inspect(error)}")
        {:ok, segment_data}
    end
  end

  defp extract_frame(segment_data, segment_start_time, target_time, opts, format_config) do
    offset = target_time - segment_start_time

    StepSupport.with_temp_dir("image_processor", fn tmp_dir ->
      with {:ok, ffmpeg_bin} <- StepSupport.find_ffmpeg(),
           {:ok, input_file} <- StepSupport.tmp_file_path(tmp_dir, "input", "mp4"),
           :ok <- StepSupport.write_tmp_file(input_file, segment_data),
           {:ok, output_file} <- StepSupport.tmp_file_path(tmp_dir, "output", format_config.ext),
           args <- build_extract_frame_args(input_file, output_file, offset, opts, format_config),
           {_output, 0} <-
             StepSupport.run_media_cmd(ffmpeg_bin, args,
               command_timeout_ms: image_command_timeout_ms()
             ),
           {:ok, frame_data} <- StepSupport.read_tmp_file(output_file) do
        {:ok, frame_data}
      else
        {output, status} when is_binary(output) and is_integer(status) ->
          Logger.error("FFmpeg failed. Status: #{status}. Output: #{output}")
          {:error, :ffmpeg_failed}

        {:error, reason} ->
          Logger.error("Image extract failed: #{inspect(reason)}")
          {:error, reason}
      end
    end)
  end

  defp build_extract_frame_args(input_file, output_file, offset, opts, format_config) do
    [
      "-y",
      "-i",
      input_file,
      "-ss",
      Float.to_string(offset)
    ] ++
      scale_filter_args(opts) ++
      ["-frames:v", "1"] ++
      format_config.codec_args ++
      [output_file]
  end

  defp scale_filter_args(opts) do
    case {opts[:width], opts[:height]} do
      {w, h} when is_integer(w) and is_integer(h) -> ["-vf", "scale=#{w}:#{h}"]
      {w, _} when is_integer(w) -> ["-vf", "scale=#{w}:-1"]
      {_, h} when is_integer(h) -> ["-vf", "scale=-1:#{h}"]
      _ -> []
    end
  end

  defp storage_module do
    Application.get_env(:mave_core, :storage_module, Storage)
  end

  defp image_command_timeout_ms do
    Application.get_env(:mave_core, :image_generation_media_command_timeout_ms)
  end
end
