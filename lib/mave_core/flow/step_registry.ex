defmodule MaveCore.Flow.StepRegistry do
  @moduledoc """
  Static step type registry for API discoverability and clear visual-builder naming.

  Besides the handler and executor, a step type describes what a pipeline
  editor needs to know about it:

  - `stage`: where the step sits on the path from upload to delivery
    (`ingest`, `audio`, `video`, `images`, `subtitles`, `audio_description`,
    `publish` or `deliver`).
  - `dependencies`: what happens when one of its dependencies is turned off.
    `:all` (default) means the step cannot do its work without every
    dependency. `:any` means it works with whatever is left. `:accumulate`
    means it adds to what an earlier step of the same type published: it takes
    over the dependencies of a predecessor that was turned off and has nothing
    to add once only such predecessors remain.
  - `options`: step parameters. Options marked `"editable" => true` are safe to
    change per space; the others are for custom flows and debugging.

  Step types from `MaveCore.Flow.StepPlugin` modules listed under
  `config :mave_core, :flow_step_plugins` are part of the registry too. They
  additionally describe their `inputs`, `outputs`, `progress` and `results`.
  """

  require Logger

  alias MaveCore.Flow.StepPlugin

  alias MaveCore.Flow.Steps.{
    AiDescribeVideoStep,
    AiSpeakDescriptionsStep,
    AiTranscribeAudioStep,
    AiTranslateDescriptionsStep,
    AiTranslateSubtitlesStep,
    AssetUploadOriginalStep,
    CdnPurgeStep,
    EventNotifyWebhookStep,
    ManifestBuildStep,
    MediaBuildHlsMasterStep,
    MediaDetectScenesStep,
    MediaExtractFrameStep,
    MediaGenerateAudioPeaksStep,
    MediaGenerateSegmentsStep,
    MediaGenerateStoryboardStep,
    MediaInspectStep,
    MediaMixAudioDescriptionStep,
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

  @transcription_context_option %{
    "key" => "context",
    "type" => "text",
    "label" => "Vocabulary",
    "description" =>
      "Names and terms that should be spelled correctly in subtitles, such as a company or product name.",
    "placeholder" => "Mave, Hovercraft",
    "max_length" => 600,
    "editable" => true
  }

  @storyboard_count_option %{
    "key" => "count",
    "type" => "integer",
    "label" => "Preview frames",
    "description" => "Maximum number of frames in the scrubbing preview.",
    "default" => 60,
    "min" => 10,
    "max" => 120,
    "editable" => true
  }

  @stages ~w(ingest audio video images subtitles audio_description publish deliver)

  @step_types %{
    "source.resolve" => %{
      stage: "ingest",
      name: "Resolve Source",
      category: "source",
      description: "Resolves source media URL and input metadata.",
      handler: SourceResolveStep,
      executor: :inline
    },
    "storage.ensure_space_bucket" => %{
      stage: "ingest",
      name: "Ensure Space Bucket",
      category: "storage",
      description: "Ensures destination space bucket exists and is writable.",
      handler: StorageEnsureSpaceBucketStep,
      executor: :inline
    },
    "asset.upload_original" => %{
      stage: "ingest",
      name: "Upload Original",
      category: "asset",
      description: "Stores the original uploaded media asset.",
      handler: AssetUploadOriginalStep,
      executor: :flame
    },
    "media.inspect" => %{
      stage: "ingest",
      name: "Inspect Media",
      category: "media",
      description: "Extracts stream and duration metadata from source media.",
      handler: MediaInspectStep,
      options: [@strict_option],
      executor: :inline
    },
    "media.transcode_video" => %{
      stage: "video",
      name: "Transcode Video",
      category: "media",
      description: "Creates video renditions via FFmpeg.",
      handler: MediaTranscodeVideoStep,
      options: [@strict_option],
      executor: :flame
    },
    "media.transcode_h264_ladder" => %{
      stage: "video",
      name: "Transcode H264 Ladder",
      category: "media",
      description: "Creates one or more H.264 video renditions via FFmpeg.",
      handler: MediaTranscodeH264LadderStep,
      options: [@strict_option],
      executor: :flame
    },
    "media.package_hls_variant" => %{
      stage: "video",
      name: "Package HLS Variant",
      category: "media",
      description: "Packages a video rendition into HLS (fMP4) variant files.",
      handler: MediaPackageHlsVariantStep,
      options: [@strict_option],
      executor: :inline
    },
    "media.package_hls_audio" => %{
      stage: "audio",
      name: "Package HLS Audio",
      category: "media",
      description: "Packages an audio rendition into HLS (fMP4) audio files.",
      handler: MediaPackageHlsAudioStep,
      options: [@strict_option],
      executor: :inline
    },
    "media.build_hls_master" => %{
      stage: "publish",
      dependencies: :accumulate,
      name: "Build HLS Master",
      category: "media",
      description: "Builds the root HLS playlist from packaged variants.",
      handler: MediaBuildHlsMasterStep,
      options: [@strict_option],
      executor: :inline
    },
    "media.transcode_audio" => %{
      stage: "audio",
      name: "Transcode Audio",
      category: "media",
      description: "Creates audio track outputs and renditions via FFmpeg.",
      handler: MediaTranscodeAudioStep,
      options: [@strict_option],
      executor: :flame
    },
    "media.transcode_waveform" => %{
      stage: "audio",
      name: "Transcode Waveform (retired)",
      category: "media",
      description: "Compatibility no-op for older flow versions; use Generate Audio Peaks.",
      handler: MediaTranscodeWaveformStep,
      executor: :inline
    },
    "media.generate_audio_peaks" => %{
      stage: "audio",
      name: "Generate Audio Peaks",
      category: "media",
      description:
        "Measures audio amplitude from audio and video uploads for waveform timelines.",
      handler: MediaGenerateAudioPeaksStep,
      executor: :flame
    },
    "media.extract_frame" => %{
      stage: "images",
      name: "Extract Frame",
      category: "media",
      description: "Extracts poster/thumbnail/placeholder/custom frame assets.",
      handler: MediaExtractFrameStep,
      options: [@strict_option],
      executor: :flame
    },
    "media.generate_segments" => %{
      stage: "images",
      name: "Generate Segments",
      category: "media",
      description: "Generates thumbnail segment frames over media duration.",
      handler: MediaGenerateSegmentsStep,
      options: [@strict_option],
      executor: :flame
    },
    "media.generate_storyboard" => %{
      stage: "images",
      name: "Generate Storyboard",
      category: "media",
      description: "Generates storyboard sprite and VTT metadata.",
      handler: MediaGenerateStoryboardStep,
      options: [@strict_option, @storyboard_count_option],
      executor: :flame
    },
    "ai.transcribe_audio" => %{
      stage: "subtitles",
      name: "Transcribe Audio",
      category: "ai",
      description: "Sends extracted audio to an LLM transcription provider.",
      handler: AiTranscribeAudioStep,
      options: [@strict_option, @transcription_context_option],
      executor: :inline
    },
    "ai.translate_subtitles" => %{
      stage: "subtitles",
      name: "Translate Subtitles",
      category: "ai",
      description: "Translates generated subtitle JSON into an English subtitle track.",
      handler: AiTranslateSubtitlesStep,
      options: [@strict_option],
      executor: :inline
    },
    "media.detect_scenes" => %{
      stage: "audio_description",
      name: "Detect Scenes",
      category: "media",
      description:
        "Detects camera cuts, groups them into scenes and extracts labelled stills for audio description.",
      handler: MediaDetectScenesStep,
      options: [@strict_option],
      executor: :flame
    },
    "ai.describe_video" => %{
      stage: "audio_description",
      name: "Describe Video",
      category: "ai",
      description:
        "Plans original-language audio descriptions and relevant on-screen text within speech pauses.",
      handler: AiDescribeVideoStep,
      options: [@strict_option],
      executor: :inline
    },
    "ai.translate_descriptions" => %{
      stage: "audio_description",
      name: "Translate Descriptions",
      category: "ai",
      description: "Translates the English audio description cues into another language.",
      handler: AiTranslateDescriptionsStep,
      options: [@strict_option],
      executor: :inline
    },
    "ai.speak_descriptions" => %{
      stage: "audio_description",
      name: "Speak Descriptions",
      category: "ai",
      description: "Speaks the audio description cues of one language with text-to-speech.",
      handler: AiSpeakDescriptionsStep,
      options: [@strict_option],
      executor: :inline
    },
    "media.mix_audio_description" => %{
      stage: "audio_description",
      name: "Mix Audio Description",
      category: "media",
      description:
        "Mixes the spoken descriptions into the video's audio (ducked under speech) and writes the descriptions VTT.",
      handler: MediaMixAudioDescriptionStep,
      options: [@strict_option],
      executor: :flame
    },
    "subtitle.upload" => %{
      stage: "subtitles",
      name: "Upload Subtitle",
      category: "subtitle",
      description: "Uploads subtitle artifacts and metadata.",
      handler: PassThroughStep,
      executor: :inline
    },
    "manifest.build" => %{
      stage: "publish",
      dependencies: :any,
      name: "Build Manifest",
      category: "manifest",
      description: "Builds/records manifest.json output used by the player.",
      handler: ManifestBuildStep,
      executor: :inline
    },
    "cdn.purge" => %{
      stage: "deliver",
      dependencies: :any,
      name: "Purge CDN",
      category: "cdn",
      description: "Purges stale CDN paths or prefixes.",
      handler: CdnPurgeStep,
      options: [@strict_option],
      executor: :inline
    },
    "embed.set_visibility" => %{
      stage: "deliver",
      name: "Set Visibility",
      category: "embed",
      description: "Updates visibility of all embed assets.",
      handler: PassThroughStep,
      executor: :inline
    },
    "event.notify_webhook" => %{
      stage: "deliver",
      dependencies: :any,
      name: "Notify Webhook",
      category: "event",
      description: "Posts progress/completion events to callback endpoints.",
      handler: EventNotifyWebhookStep,
      options: [@strict_option],
      executor: :inline
    }
  }

  def all do
    types()
    |> Enum.map(fn {type, meta} ->
      %{
        "type" => type,
        "name" => meta.name,
        "category" => meta.category,
        "stage" => meta.stage,
        "dependencies" => Atom.to_string(Map.get(meta, :dependencies, :all)),
        "description" => meta.description,
        "options" => Map.get(meta, :options, [])
      }
      |> Map.merge(plugin_listing(meta))
    end)
    |> Enum.sort_by(& &1["type"])
  end

  defp plugin_listing(%{plugin: _module} = meta) do
    %{
      "plugin" => true,
      "inputs" => meta.inputs,
      "outputs" => meta.outputs,
      "progress" => meta.progress,
      "results" => meta.results
    }
  end

  defp plugin_listing(_meta), do: %{}

  @doc "Stages in the order media moves through them. Plugin stages come last."
  def stages do
    plugin_stages = for {_type, meta} <- plugin_types(), meta.stage not in @stages, do: meta.stage
    @stages ++ Enum.uniq(plugin_stages)
  end

  def known_type?(type), do: lookup(type) != nil

  @doc "Whether the step type comes from a plugin."
  def plugin?(type), do: match?(%{plugin: _module}, lookup(type))

  @doc "Display metadata for one step type, or `nil` when the type is unknown."
  def fetch(type) do
    case lookup(type) do
      nil ->
        nil

      meta ->
        %{
          type: type,
          name: meta.name,
          category: meta.category,
          stage: meta.stage,
          description: meta.description,
          dependencies: Map.get(meta, :dependencies, :all),
          options: Map.get(meta, :options, []),
          plugin: Map.has_key?(meta, :plugin),
          inputs: Map.get(meta, :inputs, []),
          outputs: Map.get(meta, :outputs, []),
          progress: Map.get(meta, :progress, %{}),
          results: Map.get(meta, :results, [])
        }
    end
  end

  @doc "Options of a step type that may be changed per space."
  def editable_options(type) do
    case lookup(type) do
      nil -> []
      meta -> meta |> Map.get(:options, []) |> Enum.filter(&(&1["editable"] == true))
    end
  end

  @doc "How a step type copes with a dependency that was turned off."
  def dependency_policy(type) do
    case lookup(type) do
      nil -> :all
      meta -> Map.get(meta, :dependencies, :all)
    end
  end

  def handler_for(type) do
    case lookup(type) do
      nil -> nil
      meta -> meta.handler
    end
  end

  def executor_for(type) do
    case lookup(type) do
      nil -> :inline
      meta -> Map.get(meta, :executor, :inline)
    end
  end

  @doc """
  Whether this installation can run the step type: `:ok` or
  `{:unavailable, reason}`. Built-in types are always available.
  """
  def availability(type) do
    case lookup(type) do
      %{plugin: module} ->
        if exports?(module, :availability, 0),
          do: safe_availability(module),
          else: :ok

      _ ->
        :ok
    end
  end

  defp safe_availability(module) do
    case module.availability() do
      {:unavailable, reason} when is_binary(reason) -> {:unavailable, reason}
      _ -> :ok
    end
  rescue
    error ->
      Logger.warning("Step plugin #{inspect(module)} availability failed: #{inspect(error)}")
      {:unavailable, "This step could not be checked on this installation."}
  end

  @doc "How a running step of this type names its work, such as \"measuring\"."
  def progress_label(type) do
    case lookup(type) do
      %{progress: %{"label" => label}} when is_binary(label) and label != "" -> label
      _ -> nil
    end
  end

  @doc """
  The values a step type wants shown from a step output, as
  `%{key, label, value, text, primary}`. Results the output lacks are left out.
  """
  def results(type, output) when is_map(output) do
    case lookup(type) do
      %{results: results} -> Enum.flat_map(results, &result_value(&1, output))
      _ -> []
    end
  end

  def results(_type, _output), do: []

  defp result_value(result, output) do
    case get_in(output, String.split(result["key"], ".")) do
      nil ->
        []

      value ->
        [
          %{
            key: result["key"],
            label: result["label"],
            value: value,
            text: format_result(result, value),
            primary: result["primary"] == true
          }
        ]
    end
  end

  defp format_result(%{"format" => "number"} = result, value) when is_number(value) do
    decimals = Map.get(result, "decimals", 1)
    with_unit(:erlang.float_to_binary(value * 1.0, decimals: decimals), result)
  end

  defp format_result(%{"format" => "integer"} = result, value) when is_number(value),
    do: with_unit(Integer.to_string(round(value)), result)

  defp format_result(%{"format" => "boolean"}, value) when is_boolean(value),
    do: if(value, do: "Yes", else: "No")

  defp format_result(result, value) when is_binary(value) or is_number(value),
    do: with_unit(to_string(value), result)

  defp format_result(_result, value), do: inspect(value)

  defp with_unit(text, %{"unit" => unit}) when is_binary(unit) and unit != "",
    do: "#{text} #{unit}"

  defp with_unit(text, _result), do: text

  @doc """
  Steps that plugins offer for a flow definition, ready to be appended to it.

  Offered steps are optional, depend only on steps the definition has and never
  reuse an existing step id.
  """
  def offered_steps(definition) do
    existing = for %{"id" => id} <- definition_steps(definition), into: MapSet.new(), do: id

    {steps, _taken} =
      plugin_types()
      |> Enum.sort_by(fn {type, _meta} -> type end)
      |> Enum.flat_map(fn {type, meta} -> placements(meta.plugin, type, definition) end)
      |> Enum.reduce({[], existing}, fn step, {steps, taken} ->
        if offered_step_fits?(step, existing, taken),
          do: {[step | steps], MapSet.put(taken, step["id"])},
          else: {steps, taken}
      end)

    Enum.reverse(steps)
  end

  defp definition_steps(%{"steps" => steps}) when is_list(steps), do: steps
  defp definition_steps(_definition), do: []

  defp placements(module, type, definition) do
    if exports?(module, :placements, 1) do
      definition
      |> module.placements()
      |> List.wrap()
      |> Enum.flat_map(&offered_step(&1, type))
    else
      []
    end
  rescue
    error ->
      Logger.warning("Step plugin #{inspect(module)} placements failed: #{inspect(error)}")
      []
  end

  defp offered_step(%{"id" => id} = step, type) when is_binary(id) and id != "" do
    name = Map.get(step, "name")

    [
      %{
        "id" => id,
        "type" => type,
        "name" => if(is_binary(name) and name != "", do: name, else: id),
        "depends_on" => step |> Map.get("depends_on", []) |> List.wrap(),
        "required" => false,
        "lane" => Map.get(step, "lane", "background"),
        "params" => step |> Map.get("params", %{}) |> then(&if(is_map(&1), do: &1, else: %{}))
      }
    ]
  end

  defp offered_step(_step, _type), do: []

  defp offered_step_fits?(step, existing, taken) do
    not MapSet.member?(taken, step["id"]) and
      Enum.all?(step["depends_on"], &(is_binary(&1) and MapSet.member?(existing, &1)))
  end

  defp lookup(type) when is_binary(type) do
    case Map.get(@step_types, type) do
      nil -> Map.get(plugin_types(), type)
      meta -> meta
    end
  end

  defp lookup(_type), do: nil

  defp types, do: Map.merge(plugin_types(), @step_types)

  # Contracts are validated once and again when the configured plugins or
  # their code change, so a plugin can be edited with code reloading.
  defp plugin_types do
    modules = List.wrap(Application.get_env(:mave_core, :flow_step_plugins, []))
    signature = Enum.map(modules, &{&1, module_version(&1)})

    case :persistent_term.get({__MODULE__, :plugin_types}, nil) do
      {^signature, types} ->
        types

      _ ->
        types = load_plugins(modules)
        :persistent_term.put({__MODULE__, :plugin_types}, {signature, types})
        types
    end
  end

  defp module_version(module) when is_atom(module) do
    if Code.ensure_loaded?(module), do: module.module_info(:md5)
  end

  defp module_version(_module), do: nil

  # `function_exported?/3` alone is false for a module that is not loaded yet.
  defp exports?(module, function, arity),
    do: Code.ensure_loaded?(module) and function_exported?(module, function, arity)

  defp load_plugins(modules) do
    Enum.reduce(modules, %{}, fn module, types ->
      case StepPlugin.validate(module) do
        {:ok, %{type: type} = contract} ->
          register_plugin(types, type, module, contract)

        {:error, reasons} ->
          Logger.warning("Ignoring step plugin #{inspect(module)}: #{Enum.join(reasons, "; ")}")
          types
      end
    end)
  end

  defp register_plugin(types, type, module, contract) do
    if Map.has_key?(@step_types, type) or Map.has_key?(types, type) do
      Logger.warning("Ignoring step plugin #{inspect(module)}: step type #{type} already exists")
      types
    else
      Map.put(types, type, contract |> Map.put(:handler, module) |> Map.put(:plugin, module))
    end
  end
end
