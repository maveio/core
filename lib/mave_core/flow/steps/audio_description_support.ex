defmodule MaveCore.Flow.Steps.AudioDescriptionSupport do
  @moduledoc """
  Shared plumbing of the audio-description flow steps: run coordinates, private
  working objects and the result shapes.

  Every step skips itself when the run didn't ask for audio descriptions, so the
  steps cost nothing in the publishing presets for other spaces. Transient
  provider and storage errors are returned as errors (the flow engine retries
  them); anything else makes the step `unavailable`, which never blocks
  publication.
  """

  alias MaveCore.AudioDescription
  alias MaveCore.Flow.RetryPolicy
  alias MaveCore.Flow.Steps.Support, as: StepSupport
  alias MaveCore.Media.Storage

  @failure_tags %{
    "media.detect_scenes" => :media_detect_scenes_failed,
    "ai.describe_video" => :ai_describe_video_failed,
    "ai.translate_descriptions" => :ai_translate_descriptions_failed,
    "ai.speak_descriptions" => :ai_speak_descriptions_failed,
    "media.mix_audio_description" => :media_mix_audio_description_failed
  }

  def run_context(step, context) do
    run_input = Map.get(context, :run_input, %{})
    outputs = Map.get(context, :dependency_outputs, %{})
    source = Map.get(outputs, "source", %{})
    params = Map.get(step, "params", %{})
    space_hash = source["space_hash"] || run_input["space_hash"]
    region = run_input["region"]

    %{
      step_id: Map.get(step, "id"),
      params: params,
      run_input: run_input,
      outputs: outputs,
      space_hash: space_hash,
      embed_hash: source["embed_hash"] || run_input["embed_hash"],
      version: StepSupport.normalize_version(source["version"] || run_input["version"]),
      region: region,
      bucket: Storage.bucket_for_space(space_hash, region),
      storage: Application.get_env(:mave_core, :flow_storage_adapter, Storage),
      languages: AudioDescription.requested_languages(run_input),
      strict?: StepSupport.strict_enabled?(params, run_input, "audio_description_strict")
    }
  end

  @doc "`:ok`, or the reason the step has nothing to do."
  def check_requested(%{languages: []}), do: {:skip, "not_requested"}

  def check_requested(%{params: %{"language" => language}, languages: languages}) do
    if language in languages, do: :ok, else: {:skip, "language_not_requested"}
  end

  def check_requested(_ctx), do: :ok

  @doc "The status of a dependency step that must have succeeded."
  def check_dependency(ctx, step_id) do
    case Map.get(ctx.outputs, step_id) do
      %{"status" => "ok"} = output ->
        {:ok, output}

      %{"status" => status, "reason" => reason} when status in ["skipped", "unavailable"] ->
        {:skip, reason}

      %{"status" => status} when status in ["skipped", "unavailable"] ->
        {:skip, "#{step_id}_#{status}"}

      _ ->
        {:skip, "#{step_id}_missing"}
    end
  end

  @doc "The dependency named by `params[\"source_step_id\"]`."
  def source_step_id(ctx, default), do: Map.get(ctx.params, "source_step_id", default)

  def language(ctx), do: Map.get(ctx.params, "language", AudioDescription.source_language())

  def work_key(ctx, name),
    do: "#{AudioDescription.work_prefix(ctx.embed_hash, ctx.version)}/#{name}"

  def output_key(ctx, filename),
    do: "#{AudioDescription.version_prefix(ctx.embed_hash, ctx.version)}/#{filename}"

  @doc "Stores a private JSON working object."
  def put_json(ctx, key, value) do
    body = Jason.encode!(value)

    case ctx.storage.put(ctx.bucket, key, body, "application/json", ctx.region) do
      {:ok, _} -> {:ok, key}
      {:error, reason} -> {:error, {:storage_put_failed, key, reason}}
    end
  end

  def get_json(ctx, key) when is_binary(key) do
    with {:ok, body} <- ctx.storage.get(ctx.bucket, key, ctx.region),
         {:ok, value} <- Jason.decode(body) do
      {:ok, value}
    else
      {:error, %Jason.DecodeError{}} -> {:error, {:invalid_json, key}}
      {:error, reason} -> {:error, {:storage_get_failed, key, reason}}
    end
  end

  def get_json(_ctx, key), do: {:error, {:missing_key, key}}

  def put_private(ctx, key, body, content_type) do
    case ctx.storage.put(ctx.bucket, key, body, content_type, ctx.region) do
      {:ok, _} -> {:ok, key}
      {:error, reason} -> {:error, {:storage_put_failed, key, reason}}
    end
  end

  def chat_provider do
    AudioDescription.config(:chat_provider, MaveCore.AudioDescription.Scaleway)
  end

  def speech_provider do
    AudioDescription.config(:speech_provider, MaveCore.AudioDescription.MistralSpeech)
  end

  def skipped(step_type, ctx, reason, extra \\ %{}) do
    Map.merge(
      %{
        "status" => "skipped",
        "step_type" => step_type,
        "step_id" => ctx.step_id,
        "reason" => reason
      },
      extra
    )
  end

  @doc "The step result for a failure: retried when transient, otherwise `unavailable`."
  def failure(step_type, ctx, reason) do
    if ctx.strict? or RetryPolicy.transient_error?(reason) do
      {:error, {Map.fetch!(@failure_tags, step_type), reason}}
    else
      {:ok,
       %{
         "status" => "unavailable",
         "step_type" => step_type,
         "step_id" => ctx.step_id,
         "error" => inspect(reason)
       }, []}
    end
  end

  def artifact(name, ctx, key, media_type, size, metadata \\ %{}) do
    %{
      name: name,
      uri: "s3://#{ctx.bucket}/#{key}",
      media_type: media_type,
      size_bytes: size,
      metadata:
        Map.merge(
          %{
            "type" => "audio_description",
            "space_hash" => ctx.space_hash,
            "embed_hash" => ctx.embed_hash,
            "version" => ctx.version
          },
          metadata
        )
    }
  end
end
