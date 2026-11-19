defmodule MaveCore.Workers.DescriptionAudioWorker do
  @moduledoc false
  use Oban.Worker, queue: :flow_media, max_attempts: 3

  import Ecto.Query
  alias MaveCore.{Assets, Embeds, Repo, Spaces}
  alias MaveCore.Assets.AudioDescription
  alias MaveCore.AudioDescription.EditorAudio
  alias MaveCore.Embeds.{Embed, Events}
  alias MaveCore.Flow.{Run, StepRun}
  alias MaveCore.Flow.Steps.AudioDescriptionSupport, as: AD

  @impl true
  def perform(%Oban.Job{args: args} = job) do
    id = args["render_id"]

    with %Embed{deleted_at: nil} = embed <- Repo.get(Embed, args["embed_id"]),
         embed = Repo.preload(embed, [:space, asset: :current_video]),
         %AudioDescription{audio_origin: :generated, text_draft: %{"render_id" => ^id}} =
           description <-
           Assets.get_audio_description_for_embed(args["description_id"], embed) do
      case render(embed, description, args) do
        {:ok, :published} ->
          Events.broadcast_updated(embed.space_id, embed.id, %{
            "description_audio" => "published",
            "render_id" => id
          })

        {:ok, :obsolete} ->
          :ok

        {:error, reason} ->
          terminal =
            match?({:description_does_not_fit, _}, reason) or
              reason in [:generation_disabled, :stale_document, :insufficient_ad_credit] or
              job.attempt >= job.max_attempts

          if terminal do
            mark_failed(description.id, id, reason)

            Events.broadcast_updated(embed.space_id, embed.id, %{
              "description_audio" => "failed",
              "insufficient_credit" => reason == :insufficient_ad_credit,
              "render_id" => id
            })

            {:cancel, "Description audio could not be updated"}
          else
            {:error, :description_audio_unavailable}
          end
      end
    else
      %AudioDescription{audio_origin: :uploaded, text_draft: %{"render_id" => ^id}} = description ->
        mark_failed(description.id, id, :uploaded_audio_description)
        :ok

      _obsolete ->
        :ok
    end
  end

  defp render(embed, description, args) do
    render_id = args["render_id"]
    video = embed.asset.current_video

    run_input = %{
      "space_hash" => embed.space.hash,
      "embed_hash" => embed.hash,
      "video_id" => video.id,
      "version" => Embeds.current_video_version(video),
      "region" => embed.space.region || "default",
      "audio_description" => args["speech_config"]
    }

    ctx = AD.run_context(%{"id" => "edit_description_audio"}, %{run_input: run_input})
    ctx = %{ctx | usage_context: Map.put(ctx.usage_context, :space_id, embed.space_id)}

    with true <-
           Spaces.audio_description_active?(embed.space) and
             video.duration <= MaveCore.AudioDescription.max_seconds(),
         {:ok, editor} <- Assets.load_description_document(embed, description.id),
         {_, %{"render_id" => ^render_id}} <- editor.revision,
         {:ok, outputs} <- original_audio(ctx, video),
         {:ok, attrs, characters} <-
           EditorAudio.render(
             ctx
             |> Map.put(:outputs, outputs)
             |> Map.put(
               :before_speech,
               &MaveCore.AudioDescription.Publication.reserve_edit(
                 embed,
                 description,
                 render_id,
                 &1
               )
             ),
             render_lines(editor),
             video.duration,
             description.language,
             args["render_id"],
             description.text_draft["vtt"]
           ) do
      publish(embed, description, attrs, characters, render_id)
    else
      false -> {:error, :generation_disabled}
      {:error, reason} -> {:error, reason}
      _obsolete -> {:ok, :obsolete}
    end
  end

  defp render_lines(%{vtt_basis: true} = editor) do
    ends =
      Map.new(
        MaveCore.Transcription.SubtitleDocument.cues(editor.document),
        &{&1.id, &1.end_seconds}
      )

    Enum.map(editor.moments, &Map.put(&1, "end", Map.fetch!(ends, &1["id"])))
  end

  defp render_lines(editor), do: editor.moments

  defp original_audio(ctx, video) do
    track = Enum.find(Assets.audio_tracks_for_video(video.id), & &1.default)

    if is_nil(track) and silent_video?(ctx, video.id) do
      {:ok, %{}}
    else
      filename = if track, do: track.filename, else: "audio.mp3"
      key = AD.output_key(ctx, filename)
      {:ok, %{"transcode_audio" => %{"status" => "ok", "bucket" => ctx.bucket, "key" => key}}}
    end
  end

  defp silent_video?(ctx, video_id) do
    Repo.one(
      from(s in StepRun,
        join: r in Run,
        on: s.flow_run_id == r.id,
        where:
          s.step_id == "inspect_media" and s.status == "succeeded" and
            fragment("?->>'space_hash' = ?", r.input, ^ctx.space_hash) and
            fragment("?->>'embed_hash' = ?", r.input, ^ctx.embed_hash) and
            fragment("?->>'video_id' = ?", r.input, ^video_id),
        order_by: [desc: s.completed_at],
        limit: 1,
        select: s.output
      )
    )
    |> case do
      %{"has_audio" => false} -> true
      _ -> false
    end
  end

  defp publish(embed, original, attrs, characters, render_id) do
    Repo.transaction(fn ->
      current =
        Repo.one(from(d in AudioDescription, where: d.id == ^original.id, lock: "FOR UPDATE"))

      fresh = Repo.preload(embed, [:asset, :space], force: true)

      if current && !current.deleted_at && current.audio_origin == :generated &&
           current.text_draft == original.text_draft &&
           current.language == original.language &&
           current.audio_filename == original.audio_filename &&
           current.vtt_filename == original.vtt_filename &&
           fresh.asset.current_video_id == original.video_id do
        with {:ok, _} <-
               current
               |> AudioDescription.changeset(attrs)
               |> Ecto.Changeset.put_change(:text_draft, nil)
               |> Repo.update(),
             :ok <- Assets.refresh_audio_outputs(fresh),
             :ok <-
               MaveCore.AudioDescription.Publication.published(
                 fresh,
                 original.video_id,
                 original.language,
                 :edit,
                 render_id,
                 characters
               ) do
          :published
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        :obsolete
      end
    end)
  end

  defp mark_failed(description_id, render_id, reason) do
    Repo.transaction(fn ->
      case Repo.one(
             from(d in AudioDescription, where: d.id == ^description_id, lock: "FOR UPDATE")
           ) do
        %AudioDescription{text_draft: %{"render_id" => ^render_id} = draft} = description ->
          draft =
            case reason do
              {:description_does_not_fit, details} ->
                Map.merge(draft, %{"render_status" => "does_not_fit", "fit_error" => details})

              :insufficient_ad_credit ->
                Map.put(draft, "render_status", "insufficient_credit")

              _ ->
                Map.put(draft, "render_status", "failed")
            end

          description
          |> Ecto.Changeset.change(text_draft: draft)
          |> Repo.update!()

        _ ->
          :ok
      end
    end)
  end
end
