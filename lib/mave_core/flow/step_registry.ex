defmodule MaveCore.Flow.StepRegistry do
  @moduledoc """
  Static step type registry for API discoverability and clear visual-builder naming.
  """

  alias MaveCore.Flow.Steps.{
    AiTranscribeAudioStep,
    AiTranslateSubtitlesStep,
    AssetUploadOriginalStep,
    CdnPurgeStep,
    EventNotifyWebhookStep,
    ManifestBuildStep,
    MediaBuildHlsMasterStep,
    MediaExtractFrameStep,
    MediaGenerateAudioPeaksStep,
    MediaGenerateSegmentsStep,
    MediaGenerateStoryboardStep,
    MediaInspectStep,
    MediaPackageHlsAudioStep,
    MediaPackageHlsVariantStep,
    MediaTranscodeAudioStep,
    MediaTranscodeH264LadderStep,
    MediaTranscodeVideoStep,
    MediaTranscodeWaveformStep,
    PassThroughStep,
    SourceResolveStep,
    StorageEnsureSpaceBucketStep
  }

  @strict_option %{
    "key" => "strict",
    "type" => "boolean",
    "default" => false,
    "description" => "Fail this step when it cannot produce output."
  }

  @step_types %{
    "source.resolve" => %{
      name: "Resolve Source",
      category: "source",
      description: "Resolves source media URL and input metadata.",
      handler: SourceResolveStep,
      executor: :inline
    },
    "storage.ensure_space_bucket" => %{
      name: "Ensure Space Bucket",
      category: "storage",
      description: "Ensures destination space bucket exists and is writable.",
      handler: StorageEnsureSpaceBucketStep,
      executor: :inline
    },
    "asset.upload_original" => %{
      name: "Upload Original",
      category: "asset",
      description: "Stores the original uploaded media asset.",
      handler: AssetUploadOriginalStep,
      executor: :flame
    },
    "media.inspect" => %{
      name: "Inspect Media",
      category: "media",
      description: "Extracts stream and duration metadata from source media.",
      handler: MediaInspectStep,
      options: [@strict_option],
      executor: :inline
    },
    "media.transcode_video" => %{
      name: "Transcode Video",
      category: "media",
      description: "Creates video renditions via FFmpeg.",
      handler: MediaTranscodeVideoStep,
      options: [@strict_option],
      executor: :flame
    },
    "media.transcode_h264_ladder" => %{
      name: "Transcode H264 Ladder",
      category: "media",
      description: "Creates one or more H.264 video renditions via FFmpeg.",
      handler: MediaTranscodeH264LadderStep,
      options: [@strict_option],
      executor: :flame
    },
    "media.package_hls_variant" => %{
      name: "Package HLS Variant",
      category: "media",
      description: "Packages a video rendition into HLS (fMP4) variant files.",
      handler: MediaPackageHlsVariantStep,
      options: [@strict_option],
      executor: :inline
    },
    "media.package_hls_audio" => %{
      name: "Package HLS Audio",
      category: "media",
      description: "Packages an audio rendition into HLS (fMP4) audio files.",
      handler: MediaPackageHlsAudioStep,
      options: [@strict_option],
      executor: :inline
    },
    "media.build_hls_master" => %{
      name: "Build HLS Master",
      category: "media",
      description: "Builds the root HLS playlist from packaged variants.",
      handler: MediaBuildHlsMasterStep,
      options: [@strict_option],
      executor: :inline
    },
    "media.transcode_audio" => %{
      name: "Transcode Audio",
      category: "media",
      description: "Creates audio track outputs and renditions via FFmpeg.",
      handler: MediaTranscodeAudioStep,
      options: [@strict_option],
      executor: :flame
    },
    "media.transcode_waveform" => %{
      name: "Transcode Waveform (retired)",
      category: "media",
      description: "Compatibility no-op for older flow versions; use Generate Audio Peaks.",
      handler: MediaTranscodeWaveformStep,
      executor: :inline
    },
    "media.generate_audio_peaks" => %{
      name: "Generate Audio Peaks",
      category: "media",
      description:
        "Measures audio amplitude from audio and video uploads for waveform timelines.",
      handler: MediaGenerateAudioPeaksStep,
      executor: :flame
    },
    "media.extract_frame" => %{
      name: "Extract Frame",
      category: "media",
      description: "Extracts poster/thumbnail/placeholder/custom frame assets.",
      handler: MediaExtractFrameStep,
      options: [@strict_option],
      executor: :flame
    },
    "media.generate_segments" => %{
      name: "Generate Segments",
      category: "media",
      description: "Generates thumbnail segment frames over media duration.",
      handler: MediaGenerateSegmentsStep,
      options: [@strict_option],
      executor: :flame
    },
    "media.generate_storyboard" => %{
      name: "Generate Storyboard",
      category: "media",
      description: "Generates storyboard sprite and VTT metadata.",
      handler: MediaGenerateStoryboardStep,
      options: [@strict_option],
      executor: :flame
    },
    "ai.transcribe_audio" => %{
      name: "Transcribe Audio",
      category: "ai",
      description: "Sends extracted audio to an LLM transcription provider.",
      handler: AiTranscribeAudioStep,
      options: [@strict_option],
      executor: :inline
    },
    "ai.translate_subtitles" => %{
      name: "Translate Subtitles",
      category: "ai",
      description: "Translates generated subtitle JSON into an English subtitle track.",
      handler: AiTranslateSubtitlesStep,
      options: [@strict_option],
      executor: :inline
    },
    "subtitle.upload" => %{
      name: "Upload Subtitle",
      category: "subtitle",
      description: "Uploads subtitle artifacts and metadata.",
      handler: PassThroughStep,
      executor: :inline
    },
    "manifest.build" => %{
      name: "Build Manifest",
      category: "manifest",
      description: "Builds/records manifest.json output used by the player.",
      handler: ManifestBuildStep,
      executor: :inline
    },
    "cdn.purge" => %{
      name: "Purge CDN",
      category: "cdn",
      description: "Purges stale CDN paths or prefixes.",
      handler: CdnPurgeStep,
      options: [@strict_option],
      executor: :inline
    },
    "embed.set_visibility" => %{
      name: "Set Visibility",
      category: "embed",
      description: "Updates visibility of all embed assets.",
      handler: PassThroughStep,
      executor: :inline
    },
    "event.notify_webhook" => %{
      name: "Notify Webhook",
      category: "event",
      description: "Posts progress/completion events to callback endpoints.",
      handler: EventNotifyWebhookStep,
      options: [@strict_option],
      executor: :inline
    }
  }

  def all do
    @step_types
    |> Enum.map(fn {type, meta} ->
      %{
        "type" => type,
        "name" => meta.name,
        "category" => meta.category,
        "description" => meta.description,
        "options" => Map.get(meta, :options, [])
      }
    end)
    |> Enum.sort_by(& &1["type"])
  end

  def known_type?(type), do: Map.has_key?(@step_types, type)

  def handler_for(type) do
    case Map.get(@step_types, type) do
      nil -> nil
      meta -> meta.handler
    end
  end

  def executor_for(type) do
    case Map.get(@step_types, type) do
      nil -> :inline
      meta -> Map.get(meta, :executor, :inline)
    end
  end
end
