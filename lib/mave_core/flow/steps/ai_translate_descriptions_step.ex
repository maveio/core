defmodule MaveCore.Flow.Steps.AiTranslateDescriptionsStep do
  @moduledoc """
  Translates the English description cues into `params["language"]`. Timings stay
  the same; each translation has to fit the time slot of its cue.
  """
  @behaviour MaveCore.Flow.Step

  alias MaveCore.AudioDescription.{Cues, Prompts}
  alias MaveCore.Flow.Steps.AudioDescriptionSupport, as: AD

  @step_type "ai.translate_descriptions"

  @impl true
  def run(step, context) do
    ctx = AD.run_context(step, context)
    language = AD.language(ctx)

    with :ok <- AD.check_requested(ctx),
         {:ok, source} <- AD.check_dependency(ctx, AD.source_step_id(ctx, "describe_video")) do
      translate(ctx, source, language)
    else
      {:skip, reason} -> {:ok, AD.skipped(@step_type, ctx, reason, %{"language" => language}), []}
    end
  end

  defp translate(ctx, source, language) do
    with {:ok, json} <- AD.get_json(ctx, source["cues_key"]),
         cues = Cues.from_json(json),
         {instruction, input} = Prompts.translation_request(cues, language),
         {:ok, answer} <-
           AD.chat_provider().chat_json(
             instruction,
             [%{"type" => "text", "text" => Jason.encode!(input)}],
             schema: Prompts.translations_schema(),
             max_tokens: 16_000
           ),
         {:ok, texts} <- Prompts.check_translations(answer["translations"], length(cues)),
         translated =
           cues |> Enum.zip(texts) |> Enum.map(fn {cue, text} -> %{cue | text: text} end),
         {:ok, cues_key} <-
           AD.put_json(ctx, AD.work_key(ctx, "#{language}/cues.json"), Cues.to_json(translated)) do
      {:ok,
       source
       |> Map.take(["speech_key", "duration"])
       |> Map.merge(%{
         "status" => "ok",
         "step_type" => @step_type,
         "step_id" => ctx.step_id,
         "language" => language,
         "cues_key" => cues_key,
         "cue_count" => length(translated)
       }), []}
    else
      {:error, reason} -> AD.failure(@step_type, ctx, reason)
    end
  end
end
