defmodule MaveCore.Workers.SubtitleTranslationWorker do
  @moduledoc false
  use Oban.Worker,
    queue: :flow_low,
    max_attempts: 3,
    unique: [
      period: :infinity,
      keys: [:video_id, :target],
      states: [:available, :executing, :scheduled, :retryable]
    ]

  alias MaveCore.Assets
  alias MaveCore.Assets.{Subtitle, Video}
  alias MaveCore.Embeds.{Embed, Events}
  alias MaveCore.{Languages, Repo}
  alias MaveCore.Transcription.SubtitleDocument
  import Ecto.Query

  def pending(%Video{id: id}) do
    worker = Oban.Worker.to_string(__MODULE__)

    from(j in Oban.Job,
      where:
        j.worker == ^worker and j.state in ["available", "scheduled", "executing", "retryable"],
      where: fragment("? @> ?", j.args, ^%{"video_id" => id}),
      order_by: j.id,
      select: {j.args, j.state}
    )
    |> Repo.all()
    |> Enum.map(fn {args, state} -> pending_row(args["target"], state) end)
  end

  def pending(nil), do: []

  def pending_row(language, state) do
    %{
      id: "subtitle-translation-#{language}",
      language: language,
      label: Languages.spoken_language(language) || language,
      state: if(state == "executing", do: :processing, else: :queued)
    }
  end

  def enqueue(%Embed{} = embed, source_id, target) do
    embed = Repo.preload(embed, [:space, asset: :current_video], force: true)

    with :enabled <- if(embed.space.automatic_subtitles_enabled, do: :enabled, else: :disabled),
         %Video{} = video <- embed.asset.current_video,
         %Subtitle{} = source <- Assets.get_subtitle_for_video(source_id, video.id),
         true <- source.language == Assets.subtitle_source_language(video),
         true <- is_binary(target) and Languages.spoken_language(target) != nil,
         false <- target_exists?(video.id, target),
         {:ok, editor} <- Assets.load_subtitle_document(embed, source.id) do
      quantity =
        Enum.sum(Enum.map(SubtitleDocument.cues(editor.document), &String.length(&1.text)))

      args = %{
        "embed_id" => embed.id,
        "video_id" => video.id,
        "source_id" => source.id,
        "target" => target,
        "revision" => Base.encode16(editor.revision),
        "subtitle_vocabulary" => embed.space.subtitle_vocabulary,
        "quantity" => quantity
      }

      Repo.transaction(fn ->
        with {:ok, job} <- Oban.insert(new(args)),
             :ok <- observe(:reserve_translation, [embed, job]) do
          job
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      :disabled -> {:error, :automatic_subtitles_disabled}
      _ -> {:error, :invalid_translation}
    end
  end

  @impl true
  def perform(%Oban.Job{args: args} = job) do
    with %Embed{deleted_at: nil} = embed <- Repo.get(Embed, args["embed_id"]) do
      embed = Repo.preload(embed, [:space, asset: :current_video])
      result = generate(embed, job)

      cond do
        result == :ok ->
          Events.broadcast_updated(embed.space_id, embed.id, %{
            "subtitle_translation" => "published"
          })

        match?({:cancel, _}, result) or job.attempt == job.max_attempts ->
          Events.broadcast_updated(embed.space_id, embed.id, %{
            "subtitle_translation" => "failed",
            "language" => args["target"]
          })

        true ->
          :ok
      end

      result
    else
      _ -> {:cancel, :embed_missing}
    end
  end

  defp generate(embed, %{args: args} = job) do
    target = args["target"]

    provider =
      Application.get_env(
        :mave_core,
        :subtitle_translation_provider,
        MaveCore.Transcription.MistralTranslator
      )

    id = args["video_id"]

    with %Video{id: ^id} = video <- embed.asset.current_video,
         false <- target_exists?(id, target),
         {:ok, editor} <- Assets.load_subtitle_document(embed, args["source_id"]),
         true <-
           editor.language == Assets.subtitle_source_language(video) and
             Base.encode16(editor.revision) == args["revision"],
         cues = SubtitleDocument.cues(editor.document),
         segments =
           Enum.map(cues, &%{start: &1.start_seconds, end: &1.end_seconds, text: &1.text}),
         {:ok, %{segments: translated}} <-
           provider.translate(%{segments: segments},
             vocabulary: args["subtitle_vocabulary"] || [],
             source_language: editor.language,
             target_language: target,
             usage_context: %{
               space_id: embed.space_id,
               video_id: id,
               step_id: "translate_subtitles"
             }
           ),
         :ok <- validate_translation(cues, translated),
         texts =
           Map.new(Enum.zip(cues, translated), fn {cue, segment} -> {cue.id, segment.text} end),
         {:ok, body} <- SubtitleDocument.render(editor.document, texts) do
      Repo.transaction(fn ->
        Repo.one!(from(v in Video, where: v.id == ^id, lock: "FOR UPDATE"))
        if target_exists?(id, target), do: Repo.rollback(:obsolete)

        with {:ok, current} <- Assets.load_subtitle_document(embed, args["source_id"]),
             true <- current.revision == editor.revision and current.language == editor.language,
             {:ok, _} <- Assets.publish_translated_subtitle(embed, video, target, body),
             :ok <- observe(:translation_published, [embed, job]) do
          :ok
        else
          false -> Repo.rollback(:obsolete)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, :ok} -> :ok
        {:error, :obsolete} -> {:cancel, :obsolete}
        error -> error
      end
    else
      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      {:error, {:mistral_translation_failed, status, _}} when is_integer(status) ->
        {:error, {:translation_http_error, status}}

      {:error, _} ->
        {:error, :translation_failed}

      _ ->
        {:cancel, :obsolete}
    end
  end

  def validate_translation(cues, translated) when length(cues) == length(translated) do
    sentences =
      Enum.zip(cues, translated)
      |> Enum.filter(fn {cue, _} -> length(String.split(cue.text)) >= 4 end)

    copied =
      Enum.count(sentences, fn {cue, segment} ->
        String.split(cue.text) == String.split(segment.text)
      end)

    if length(sentences) >= 5 and copied * 10 >= length(sentences) * 9,
      do: {:error, :copied_source_text},
      else: :ok
  end

  def validate_translation(_, _), do: {:error, :incomplete_translation}

  defp target_exists?(video, target),
    do: Repo.exists?(from(s in Subtitle, where: s.video_id == ^video and s.language == ^target))

  defp observe(callback, args) do
    observer =
      Application.get_env(:mave_core, :subtitle_translation_publication) ||
        Application.get_env(:mave_core, :audio_description_publication)

    if observer && Code.ensure_loaded?(observer) &&
         function_exported?(observer, callback, length(args)),
       do: apply(observer, callback, args),
       else: :ok
  end
end
