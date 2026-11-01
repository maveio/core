defmodule MaveCore.Flow.Steps.AiSpeakDescriptionsStep do
  @moduledoc """
  Speaks every description cue of one language with text-to-speech, in a voice
  of that language. Clips are stored privately as trimmed mono 24 kHz PCM; a
  clip that already exists is reused, so a retry only speaks what is missing.
  """
  @behaviour MaveCore.Flow.Step

  alias MaveCore.AudioDescription.{Cues, Wav}
  alias MaveCore.Flow.Steps.AudioDescriptionSupport, as: AD

  @step_type "ai.speak_descriptions"
  @concurrency 5
  @timeout_ms 3 * 60 * 1000

  @impl true
  def run(step, context) do
    ctx = AD.run_context(step, context)
    language = AD.language(ctx)
    source_step_id = AD.source_step_id(ctx, "describe_video")

    with :ok <- AD.check_requested(ctx),
         {:ok, source} <- AD.check_dependency(ctx, source_step_id) do
      speak(ctx, source, language)
    else
      {:skip, reason} -> {:ok, AD.skipped(@step_type, ctx, reason, %{"language" => language}), []}
    end
  end

  defp speak(ctx, source, language) do
    with {:ok, json} <- AD.get_json(ctx, source["cues_key"]),
         cues = Cues.from_json(json),
         {:ok, clips} <- speak_cues(ctx, cues, language) do
      {:ok,
       source
       |> Map.take(["speech_key", "duration", "cues_key"])
       |> Map.merge(%{
         "status" => "ok",
         "step_type" => @step_type,
         "step_id" => ctx.step_id,
         "language" => language,
         "sample_rate" => Wav.sample_rate(),
         "clips" => clips
       }), []}
    else
      {:error, reason} -> AD.failure(@step_type, ctx, reason)
    end
  end

  defp speak_cues(ctx, cues, language) do
    cues
    |> Enum.with_index()
    |> Task.async_stream(fn {cue, index} -> speak_cue(ctx, cue, index, language) end,
      max_concurrency: @concurrency,
      timeout: @timeout_ms,
      ordered: true
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, clip}}, {:ok, clips} -> {:cont, {:ok, [clip | clips]}}
      {:ok, {:error, reason}}, _acc -> {:halt, {:error, reason}}
      {:exit, reason}, _acc -> {:halt, {:error, {:speech_task_exit, reason}}}
    end)
    |> case do
      {:ok, clips} -> {:ok, Enum.reverse(clips)}
      error -> error
    end
  end

  defp speak_cue(ctx, cue, index, language) do
    key = AD.work_key(ctx, "#{language}/speech/#{String.pad_leading("#{index}", 5, "0")}.pcm")

    case ctx.storage.get(ctx.bucket, key, ctx.region) do
      {:ok, pcm} ->
        {:ok, %{"key" => key, "samples" => div(byte_size(pcm), 2)}}

      {:error, _not_found} ->
        with {:ok, audio} <- AD.speech_provider().speak(cue.text, language),
             {:ok, pcm} <- Wav.clip(audio),
             {:ok, _} <- AD.put_private(ctx, key, pcm, "application/octet-stream") do
          {:ok, %{"key" => key, "samples" => div(byte_size(pcm), 2)}}
        end
    end
  end
end
