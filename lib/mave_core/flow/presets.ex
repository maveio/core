defmodule MaveCore.Flow.Presets do
  @moduledoc """
  Built-in flow templates used as migration starting points.
  """

  alias MaveCore.Media.ProductionEncodingProfile

  @spec all() :: [map()]
  def all do
    [
      %{
        "slug" => "publish_default",
        "name" => "Publish Default",
        "description" =>
          "Encoder-compatible default publish flow with upload, transcode, manifest, and webhook steps."
      },
      %{
        "slug" => "publish_local",
        "name" => "Publish Local",
        "description" =>
          "Lighter local-development publish flow that skips heavy codec variants while still producing a manifest."
      }
    ]
  end

  @spec fetch(String.t()) :: {:ok, map()} | {:error, :preset_not_found}
  def fetch("publish_default") do
    {:ok,
     %{
       "slug" => "publish_default",
       "name" => "Publish Default",
       "description" =>
         "Encoder-compatible default publish flow with upload, transcode, manifest, and webhook steps.",
       "definition" => publish_default_definition() |> with_audio_peaks()
     }
     |> maybe_override_preset("publish_default")}
  end

  def fetch("publish_local") do
    {:ok,
     %{
       "slug" => "publish_local",
       "name" => "Publish Local",
       "description" =>
         "Lighter local-development publish flow that skips heavy codec variants while still producing a manifest.",
       "definition" => publish_local_definition() |> with_audio_peaks()
     }
     |> maybe_override_preset("publish_local")}
  end

  # Remote inputs use these serialized variants so the original becomes durable
  # before any inspector or encoder can consume it.
  def fetch("publish_remote") do
    {:ok,
     %{
       "slug" => "publish_remote",
       "name" => "Publish Remote",
       "description" =>
         "Remote-source publish flow that makes the original durable before inspecting or encoding it.",
       "definition" => durable_remote_definition(publish_default_definition())
     }
     |> maybe_override_preset("publish_remote")}
  end

  def fetch("publish_remote_local") do
    {:ok,
     %{
       "slug" => "publish_remote_local",
       "name" => "Publish Remote Local",
       "description" =>
         "Lighter remote-source flow that makes the original durable before local processing.",
       "definition" => durable_remote_definition(publish_local_definition())
     }
     |> maybe_override_preset("publish_remote_local")}
  end

  def fetch(_), do: {:error, :preset_not_found}

  defp durable_remote_definition(%{"steps" => steps} = definition) do
    durable_steps =
      Enum.map(steps, fn
        %{"id" => "inspect_media"} = step -> Map.put(step, "depends_on", ["upload_original"])
        step -> step
      end)

    definition |> Map.put("steps", durable_steps) |> with_audio_peaks()
  end

  defp with_audio_peaks(definition) do
    Map.update!(
      definition,
      "steps",
      &(&1 ++
          [
            %{
              "id" => "audio_peaks",
              "type" => "media.generate_audio_peaks",
              "name" => "Generate Audio Timeline",
              "depends_on" => ["inspect_media", "transcode_audio"],
              "lane" => "background",
              "required" => false
            }
          ])
    )
  end

  defp maybe_override_preset(preset, slug) do
    case Application.get_env(:mave_core, :flow_preset_overrides, %{}) do
      overrides when is_map(overrides) ->
        case Map.get(overrides, slug) do
          override when is_map(override) -> Map.merge(preset, override)
          _ -> preset
        end

      _ ->
        preset
    end
  end

  defp publish_default_definition do
    %{
      "encoding_booster_contract" => ProductionEncodingProfile.name(),
      "steps" => [
        %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"},
        %{
          "id" => "ensure_bucket",
          "type" => "storage.ensure_space_bucket",
          "name" => "Ensure Space Bucket",
          "depends_on" => ["source"]
        },
        %{
          "id" => "upload_original",
          "type" => "asset.upload_original",
          "name" => "Upload Original",
          "depends_on" => ["ensure_bucket"],
          "lane" => "fast"
        },
        %{
          "id" => "inspect_media",
          "type" => "media.inspect",
          "name" => "Inspect Media",
          "depends_on" => ["ensure_bucket"],
          "params" => %{"strict" => true},
          "lane" => "fast"
        },
        %{
          "id" => "transcode_audio",
          "type" => "media.transcode_audio",
          "name" => "Transcode Audio",
          "depends_on" => ["inspect_media"],
          "params" => %{
            "codec" => "mp3",
            "container" => "mp3",
            "label" => "Original",
            "strict" => true
          },
          "lane" => "fast"
        },
        %{
          "id" => "transcribe_audio",
          "type" => "ai.transcribe_audio",
          "name" => "Transcribe Audio",
          "depends_on" => ["transcode_audio"],
          "lane" => "background",
          "required" => false
        },
        %{
          "id" => "translate_subtitles",
          "type" => "ai.translate_subtitles",
          "name" => "Translate Subtitles",
          "depends_on" => ["transcribe_audio"],
          "lane" => "background",
          "required" => false
        },
        %{
          "id" => "poster_frame",
          "type" => "media.extract_frame",
          "name" => "Extract Poster",
          "depends_on" => ["inspect_media"],
          "params" => %{"role" => "poster", "codec" => "jpg", "strict" => true},
          "lane" => "fast",
          "required" => false
        },
        %{
          "id" => "poster_frame_webp",
          "type" => "media.extract_frame",
          "name" => "Extract Poster WebP",
          "depends_on" => ["inspect_media"],
          "params" => %{
            "role" => "poster",
            "codec" => "webp",
            "strict" => true
          },
          "lane" => "background",
          "required" => false
        },
        %{
          "id" => "poster_frame_avif",
          "type" => "media.extract_frame",
          "name" => "Extract Poster AVIF",
          "depends_on" => ["inspect_media"],
          "params" => %{
            "role" => "poster",
            "codec" => "avif",
            "strict" => true
          },
          "lane" => "background",
          "required" => false
        },
        %{
          "id" => "thumbnail_frame",
          "type" => "media.extract_frame",
          "name" => "Extract Thumbnail",
          "depends_on" => ["inspect_media"],
          "params" => %{"role" => "thumbnail", "codec" => "jpg", "strict" => true},
          "lane" => "fast",
          "required" => false
        },
        %{
          "id" => "thumbnail_frame_webp",
          "type" => "media.extract_frame",
          "name" => "Extract Thumbnail WebP",
          "depends_on" => ["inspect_media"],
          "params" => %{
            "role" => "thumbnail",
            "codec" => "webp",
            "strict" => true
          },
          "lane" => "background",
          "required" => false
        },
        %{
          "id" => "thumbnail_frame_avif",
          "type" => "media.extract_frame",
          "name" => "Extract Thumbnail AVIF",
          "depends_on" => ["inspect_media"],
          "params" => %{
            "role" => "thumbnail",
            "codec" => "avif",
            "strict" => true
          },
          "lane" => "background",
          "required" => false
        },
        %{
          "id" => "placeholder_frame",
          "type" => "media.extract_frame",
          "name" => "Extract Placeholder",
          "depends_on" => ["inspect_media"],
          "params" => %{"role" => "placeholder", "codec" => "jpg", "strict" => true},
          "lane" => "fast",
          "required" => false
        },
        %{
          "id" => "video_h264_sd",
          "type" => "media.transcode_h264_ladder",
          "name" => "Transcode Video H264 SD",
          "depends_on" => ["inspect_media"],
          "params" => %{
            "sizes" => ["sd"],
            "keyframe_interval" => 250,
            "strict" => true
          },
          "lane" => "fast"
        },
        %{
          "id" => "video_h264_hd",
          "type" => "media.transcode_h264_ladder",
          "name" => "Transcode Video H264 HD",
          "depends_on" => ["inspect_media"],
          "params" => %{
            "sizes" => ["hd"],
            "keyframe_interval" => 250,
            "require_source_resolution" => true,
            "strict" => true
          },
          "lane" => "fast"
        },
        %{
          "id" => "video_h264_fhd",
          "type" => "media.transcode_h264_ladder",
          "name" => "Transcode Video H264 FHD",
          "depends_on" => ["inspect_media"],
          "params" => %{
            "sizes" => ["fhd"],
            "keyframe_interval" => 250,
            "require_source_resolution" => true,
            "strict" => true
          },
          "lane" => "fast"
        },
        %{
          "id" => "video_h264_qhd",
          "type" => "media.transcode_h264_ladder",
          "name" => "Transcode Video H264 QHD",
          "depends_on" => ["inspect_media", "manifest"],
          "params" => %{
            "sizes" => ["qhd"],
            "keyframe_interval" => 250,
            "require_source_resolution" => true,
            "strict" => true
          },
          "lane" => "background",
          "required" => false
        },
        %{
          "id" => "video_h264_uhd",
          "type" => "media.transcode_h264_ladder",
          "name" => "Transcode Video H264 UHD",
          "depends_on" => ["inspect_media", "manifest"],
          "params" => %{
            "sizes" => ["uhd"],
            "keyframe_interval" => 250,
            "require_source_resolution" => true,
            "strict" => true
          },
          "lane" => "background",
          "required" => false
        },
        %{
          "id" => "clip_h264_sd_keyframes",
          "type" => "media.transcode_video",
          "name" => "Transcode H264 SD Clip Keyframes",
          "depends_on" => ["inspect_media", "video_h264_sd"],
          "params" => %{
            "codec" => "h264",
            "size" => "sd",
            "conditional_size" => true,
            "keyframe_interval" => 2,
            "strict" => true
          },
          "lane" => "background",
          "required" => false
        },
        %{
          "id" => "clip_h264_hd_keyframes",
          "type" => "media.transcode_video",
          "name" => "Transcode H264 HD Clip Keyframes",
          "depends_on" => ["inspect_media", "video_h264_hd"],
          "params" => %{
            "codec" => "h264",
            "size" => "hd",
            "conditional_size" => true,
            "keyframe_interval" => 2,
            "strict" => true
          },
          "lane" => "background",
          "required" => false
        },
        %{
          "id" => "clip_h264_fhd_keyframes",
          "type" => "media.transcode_video",
          "name" => "Transcode H264 FHD Clip Keyframes",
          "depends_on" => ["inspect_media", "video_h264_fhd"],
          "params" => %{
            "codec" => "h264",
            "size" => "fhd",
            "conditional_size" => true,
            "keyframe_interval" => 2,
            "strict" => true
          },
          "lane" => "background",
          "required" => false
        },
        %{
          "id" => "clip_hevc_sd",
          "type" => "media.transcode_video",
          "name" => "Transcode HEVC SD Clip",
          "depends_on" => ["inspect_media", "video_h264_sd"],
          "params" => %{
            "codec" => "hevc",
            "size" => "sd",
            "conditional_size" => true,
            "keyframe_interval" => 250,
            "strict" => true
          },
          "lane" => "background",
          "required" => false
        },
        %{
          "id" => "clip_hevc_hd",
          "type" => "media.transcode_video",
          "name" => "Transcode HEVC HD Clip",
          "depends_on" => ["inspect_media", "video_h264_hd"],
          "params" => %{
            "codec" => "hevc",
            "size" => "hd",
            "conditional_size" => true,
            "keyframe_interval" => 250,
            "strict" => true
          },
          "lane" => "background",
          "required" => false
        },
        %{
          "id" => "clip_hevc_fhd",
          "type" => "media.transcode_video",
          "name" => "Transcode HEVC FHD Clip",
          "depends_on" => ["inspect_media", "video_h264_fhd"],
          "params" => %{
            "codec" => "hevc",
            "size" => "fhd",
            "conditional_size" => true,
            "keyframe_interval" => 250,
            "strict" => true
          },
          "lane" => "background",
          "required" => false
        },
        %{
          "id" => "clip_hevc_qhd",
          "type" => "media.transcode_video",
          "name" => "Transcode HEVC QHD Clip",
          "depends_on" => ["inspect_media", "video_h264_qhd"],
          "params" => %{
            "codec" => "hevc",
            "size" => "qhd",
            "conditional_size" => true,
            "keyframe_interval" => 250,
            "strict" => true
          },
          "lane" => "background",
          "required" => false
        },
        %{
          "id" => "clip_hevc_uhd",
          "type" => "media.transcode_video",
          "name" => "Transcode HEVC UHD Clip",
          "depends_on" => ["inspect_media", "video_h264_uhd"],
          "params" => %{
            "codec" => "hevc",
            "size" => "uhd",
            "conditional_size" => true,
            "keyframe_interval" => 250,
            "strict" => true
          },
          "lane" => "background",
          "required" => false
        },
        %{
          "id" => "clip_av1_sd",
          "type" => "media.transcode_video",
          "name" => "Transcode AV1 SD Clip",
          "depends_on" => ["inspect_media", "video_h264_sd"],
          "params" => %{
            "codec" => "av1",
            "size" => "sd",
            "conditional_size" => true,
            "keyframe_interval" => 250,
            "strict" => true
          },
          "lane" => "background",
          "required" => false
        },
        %{
          "id" => "clip_av1_hd",
          "type" => "media.transcode_video",
          "name" => "Transcode AV1 HD Clip",
          "depends_on" => ["inspect_media", "video_h264_hd"],
          "params" => %{
            "codec" => "av1",
            "size" => "hd",
            "conditional_size" => true,
            "keyframe_interval" => 250,
            "strict" => true
          },
          "lane" => "background",
          "required" => false
        },
        %{
          "id" => "clip_av1_fhd",
          "type" => "media.transcode_video",
          "name" => "Transcode AV1 FHD Clip",
          "depends_on" => ["inspect_media", "video_h264_fhd"],
          "params" => %{
            "codec" => "av1",
            "size" => "fhd",
            "conditional_size" => true,
            "keyframe_interval" => 250,
            "strict" => true
          },
          "lane" => "background",
          "required" => false
        },
        %{
          "id" => "clip_av1_qhd",
          "type" => "media.transcode_video",
          "name" => "Transcode AV1 QHD Clip",
          "depends_on" => ["inspect_media", "video_h264_qhd"],
          "params" => %{
            "codec" => "av1",
            "size" => "qhd",
            "conditional_size" => true,
            "keyframe_interval" => 250,
            "strict" => true
          },
          "lane" => "background",
          "required" => false
        },
        %{
          "id" => "clip_av1_uhd",
          "type" => "media.transcode_video",
          "name" => "Transcode AV1 UHD Clip",
          "depends_on" => ["inspect_media", "video_h264_uhd"],
          "params" => %{
            "codec" => "av1",
            "size" => "uhd",
            "conditional_size" => true,
            "keyframe_interval" => 250,
            "strict" => true
          },
          "lane" => "background",
          "required" => false
        },
        %{
          "id" => "hls_h264_sd",
          "type" => "media.package_hls_variant",
          "name" => "Package HLS H264 SD",
          "depends_on" => ["video_h264_sd"],
          "params" => %{
            "codec" => "h264",
            "size" => "sd",
            "source_step_id" => "video_h264_sd",
            "strict" => true
          },
          "lane" => "fast"
        },
        %{
          "id" => "hls_h264_hd",
          "type" => "media.package_hls_variant",
          "name" => "Package HLS H264 HD",
          "depends_on" => ["video_h264_hd"],
          "params" => %{
            "codec" => "h264",
            "size" => "hd",
            "source_step_id" => "video_h264_hd",
            "strict" => true
          },
          "lane" => "fast",
          "required" => false
        },
        %{
          "id" => "hls_h264_fhd",
          "type" => "media.package_hls_variant",
          "name" => "Package HLS H264 FHD",
          "depends_on" => ["video_h264_fhd"],
          "params" => %{
            "codec" => "h264",
            "size" => "fhd",
            "source_step_id" => "video_h264_fhd",
            "strict" => true
          },
          "lane" => "fast",
          "required" => false
        },
        %{
          "id" => "hls_h264_qhd",
          "type" => "media.package_hls_variant",
          "name" => "Package HLS H264 QHD",
          "depends_on" => ["video_h264_qhd"],
          "params" => %{
            "codec" => "h264",
            "size" => "qhd",
            "source_step_id" => "video_h264_qhd",
            "strict" => true
          },
          "lane" => "background",
          "required" => false
        },
        %{
          "id" => "hls_h264_uhd",
          "type" => "media.package_hls_variant",
          "name" => "Package HLS H264 UHD",
          "depends_on" => ["video_h264_uhd"],
          "params" => %{
            "codec" => "h264",
            "size" => "uhd",
            "source_step_id" => "video_h264_uhd",
            "strict" => true
          },
          "lane" => "background",
          "required" => false
        },
        %{
          "id" => "hls_audio_default",
          "type" => "media.package_hls_audio",
          "name" => "Package HLS Audio Default",
          "depends_on" => ["transcode_audio"],
          "params" => %{"source_step_id" => "transcode_audio", "strict" => true},
          "lane" => "fast"
        },
        %{
          "id" => "hls_master_sd",
          "type" => "media.build_hls_master",
          "name" => "Publish HLS Master With SD",
          "depends_on" => [
            "hls_h264_sd",
            "hls_audio_default"
          ],
          "params" => %{"strict" => true}
        },
        %{
          "id" => "hls_master_hd",
          "type" => "media.build_hls_master",
          "name" => "Refresh HLS Master With HD",
          "depends_on" => ["hls_master_sd", "hls_h264_hd"],
          "params" => %{"strict" => true}
        },
        %{
          "id" => "hls_master",
          "type" => "media.build_hls_master",
          "name" => "Refresh HLS Master With FHD",
          "depends_on" => ["hls_master_hd", "hls_h264_fhd"],
          "params" => %{"strict" => true}
        },
        %{
          "id" => "hls_master_metadata",
          "type" => "media.build_hls_master",
          "name" => "Refresh HLS Master With Audio And Subtitles",
          "depends_on" => [
            "hls_master",
            "inspect_media",
            "transcribe_audio",
            "translate_subtitles"
          ],
          "params" => %{"strict" => true}
        },
        %{
          "id" => "hls_master_qhd",
          "type" => "media.build_hls_master",
          "name" => "Refresh HLS Master Playlist With QHD",
          "depends_on" => [
            "hls_master_metadata",
            "hls_h264_qhd"
          ],
          "params" => %{"strict" => true},
          "lane" => "background",
          "required" => false
        },
        %{
          "id" => "hls_master_high",
          "type" => "media.build_hls_master",
          "name" => "Refresh HLS Master Playlist With UHD",
          "depends_on" => [
            "hls_master_qhd",
            "hls_h264_uhd"
          ],
          "params" => %{"strict" => true},
          "lane" => "background",
          "required" => false
        },
        %{
          "id" => "segments",
          "type" => "media.generate_segments",
          "name" => "Generate Segments",
          "depends_on" => ["video_h264_sd"],
          "params" => %{"strict" => true},
          "lane" => "background",
          "required" => false
        },
        %{
          "id" => "storyboard",
          "type" => "media.generate_storyboard",
          "name" => "Generate Storyboard",
          "depends_on" => ["inspect_media", "video_h264_sd"],
          "params" => %{"count" => 60, "strict" => true},
          "lane" => "background",
          "required" => false
        },
        %{
          "id" => "manifest",
          "type" => "manifest.build",
          "name" => "Build Manifest",
          "depends_on" => [
            "inspect_media",
            "upload_original",
            "transcode_audio",
            "transcribe_audio",
            "translate_subtitles",
            "poster_frame",
            "thumbnail_frame",
            "placeholder_frame",
            "video_h264_sd",
            "video_h264_hd",
            "video_h264_fhd",
            "hls_master_metadata"
          ]
        },
        %{
          "id" => "purge_cdn",
          "type" => "cdn.purge",
          "name" => "Purge CDN",
          "depends_on" => ["manifest"],
          "required" => false
        },
        %{
          "id" => "notify_webhook",
          "type" => "event.notify_webhook",
          "name" => "Notify Webhook",
          "depends_on" => ["manifest"],
          "required" => false
        }
      ]
    }
  end

  defp publish_local_definition do
    %{
      "steps" => [
        %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"},
        %{
          "id" => "ensure_bucket",
          "type" => "storage.ensure_space_bucket",
          "name" => "Ensure Space Bucket",
          "depends_on" => ["source"]
        },
        %{
          "id" => "upload_original",
          "type" => "asset.upload_original",
          "name" => "Upload Original",
          "depends_on" => ["ensure_bucket"],
          "lane" => "fast"
        },
        %{
          "id" => "inspect_media",
          "type" => "media.inspect",
          "name" => "Inspect Media",
          "depends_on" => ["ensure_bucket"],
          "params" => %{"strict" => true},
          "lane" => "fast"
        },
        %{
          "id" => "transcode_audio",
          "type" => "media.transcode_audio",
          "name" => "Transcode Audio",
          "depends_on" => ["inspect_media"],
          "params" => %{
            "codec" => "mp3",
            "container" => "mp3",
            "label" => "Original",
            "strict" => true
          },
          "lane" => "fast"
        },
        %{
          "id" => "transcribe_audio",
          "type" => "ai.transcribe_audio",
          "name" => "Transcribe Audio",
          "depends_on" => ["transcode_audio"],
          "lane" => "background",
          "required" => false
        },
        %{
          "id" => "translate_subtitles",
          "type" => "ai.translate_subtitles",
          "name" => "Translate Subtitles",
          "depends_on" => ["transcribe_audio"],
          "lane" => "background",
          "required" => false
        },
        %{
          "id" => "poster_frame",
          "type" => "media.extract_frame",
          "name" => "Extract Poster",
          "depends_on" => ["inspect_media"],
          "params" => %{"role" => "poster", "codec" => "jpg", "strict" => true},
          "lane" => "fast",
          "required" => false
        },
        %{
          "id" => "poster_frame_webp",
          "type" => "media.extract_frame",
          "name" => "Extract Poster WebP",
          "depends_on" => ["inspect_media"],
          "params" => %{
            "role" => "poster",
            "codec" => "webp",
            "strict" => true
          },
          "lane" => "background",
          "required" => false
        },
        %{
          "id" => "poster_frame_avif",
          "type" => "media.extract_frame",
          "name" => "Extract Poster AVIF",
          "depends_on" => ["inspect_media"],
          "params" => %{
            "role" => "poster",
            "codec" => "avif",
            "strict" => true
          },
          "lane" => "background",
          "required" => false
        },
        %{
          "id" => "thumbnail_frame",
          "type" => "media.extract_frame",
          "name" => "Extract Thumbnail",
          "depends_on" => ["inspect_media"],
          "params" => %{"role" => "thumbnail", "codec" => "jpg", "strict" => true},
          "lane" => "fast",
          "required" => false
        },
        %{
          "id" => "thumbnail_frame_webp",
          "type" => "media.extract_frame",
          "name" => "Extract Thumbnail WebP",
          "depends_on" => ["inspect_media"],
          "params" => %{
            "role" => "thumbnail",
            "codec" => "webp",
            "strict" => true
          },
          "lane" => "background",
          "required" => false
        },
        %{
          "id" => "thumbnail_frame_avif",
          "type" => "media.extract_frame",
          "name" => "Extract Thumbnail AVIF",
          "depends_on" => ["inspect_media"],
          "params" => %{
            "role" => "thumbnail",
            "codec" => "avif",
            "strict" => true
          },
          "lane" => "background",
          "required" => false
        },
        %{
          "id" => "placeholder_frame",
          "type" => "media.extract_frame",
          "name" => "Extract Placeholder",
          "depends_on" => ["inspect_media"],
          "params" => %{"role" => "placeholder", "codec" => "jpg", "strict" => true},
          "lane" => "fast",
          "required" => false
        },
        %{
          "id" => "video_h264_ladder",
          "type" => "media.transcode_h264_ladder",
          "name" => "Transcode Video H264 Ladder",
          "depends_on" => ["inspect_media"],
          "params" => %{
            "sizes" => ["sd", "hd"],
            "keyframe_interval" => 250,
            "strict" => true
          },
          "lane" => "fast"
        },
        %{
          "id" => "clip_h264_sd_keyframes",
          "type" => "media.transcode_video",
          "name" => "Transcode H264 SD Clip Keyframes",
          "depends_on" => ["inspect_media", "video_h264_ladder"],
          "params" => %{
            "codec" => "h264",
            "size" => "sd",
            "source_step_id" => "video_h264_ladder",
            "keyframe_interval" => 2,
            "strict" => true
          },
          "lane" => "background",
          "required" => false
        },
        %{
          "id" => "hls_h264_sd",
          "type" => "media.package_hls_variant",
          "name" => "Package HLS H264 SD",
          "depends_on" => ["video_h264_ladder"],
          "params" => %{
            "codec" => "h264",
            "size" => "sd",
            "source_step_id" => "video_h264_ladder",
            "strict" => true
          },
          "lane" => "fast"
        },
        %{
          "id" => "hls_h264_hd",
          "type" => "media.package_hls_variant",
          "name" => "Package HLS H264 HD",
          "depends_on" => ["video_h264_ladder"],
          "params" => %{
            "codec" => "h264",
            "size" => "hd",
            "source_step_id" => "video_h264_ladder",
            "strict" => true
          },
          "lane" => "fast",
          "required" => false
        },
        %{
          "id" => "hls_audio_default",
          "type" => "media.package_hls_audio",
          "name" => "Package HLS Audio Default",
          "depends_on" => ["transcode_audio"],
          "params" => %{"source_step_id" => "transcode_audio", "strict" => true},
          "lane" => "fast"
        },
        %{
          "id" => "hls_master_sd",
          "type" => "media.build_hls_master",
          "name" => "Publish HLS Master With SD",
          "depends_on" => ["hls_h264_sd", "hls_audio_default"],
          "params" => %{"strict" => true}
        },
        %{
          "id" => "hls_master",
          "type" => "media.build_hls_master",
          "name" => "Refresh HLS Master With HD",
          "depends_on" => ["hls_master_sd", "hls_h264_hd"],
          "params" => %{"strict" => true}
        },
        %{
          "id" => "hls_master_metadata",
          "type" => "media.build_hls_master",
          "name" => "Refresh HLS Master With Audio And Subtitles",
          "depends_on" => [
            "hls_master",
            "inspect_media",
            "transcribe_audio",
            "translate_subtitles"
          ],
          "params" => %{"strict" => true}
        },
        %{
          "id" => "segments",
          "type" => "media.generate_segments",
          "name" => "Generate Segments",
          "depends_on" => ["video_h264_ladder"],
          "params" => %{"strict" => true},
          "lane" => "background",
          "required" => false
        },
        %{
          "id" => "storyboard",
          "type" => "media.generate_storyboard",
          "name" => "Generate Storyboard",
          "depends_on" => ["inspect_media", "video_h264_ladder"],
          "params" => %{"count" => 60, "strict" => true},
          "lane" => "background",
          "required" => false
        },
        %{
          "id" => "manifest",
          "type" => "manifest.build",
          "name" => "Build Manifest",
          "depends_on" => [
            "inspect_media",
            "upload_original",
            "transcode_audio",
            "transcribe_audio",
            "translate_subtitles",
            "poster_frame",
            "thumbnail_frame",
            "placeholder_frame",
            "video_h264_ladder",
            "hls_master_metadata"
          ]
        },
        %{
          "id" => "purge_cdn",
          "type" => "cdn.purge",
          "name" => "Purge CDN",
          "depends_on" => ["manifest"],
          "required" => false
        },
        %{
          "id" => "notify_webhook",
          "type" => "event.notify_webhook",
          "name" => "Notify Webhook",
          "depends_on" => ["manifest"],
          "required" => false
        }
      ]
    }
  end
end
