defmodule MaveCore.Transcription.SubtitleTranslationConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias MaveCore.{Assets, Embeds, Repo}
  alias MaveCore.Assets.Video
  alias MaveCore.Flow.{Run, Template}
  alias MaveCore.Spaces.Space
  alias MaveCore.Transcription.SubtitleTranslations

  test "independent simultaneous requests create one active translation for a video language" do
    supervisor = start_supervised!(Task.Supervisor)

    Sandbox.unboxed_run(Repo, fn ->
      existing_template = Repo.get_by(Template, slug: "translate_subtitle")

      space =
        Repo.insert!(%Space{hash: "translation-race-#{Ecto.UUID.generate()}", region: "default"})

      {:ok, embed} = Embeds.create_video_embed(space, %{name: "Concurrent translations"})
      {:ok, embed} = Embeds.begin_video_upload(space.hash, embed.hash, %{"title" => "source.mp4"})
      video = Repo.get!(Video, embed.asset.current_video_id)
      video |> Ecto.Changeset.change(status: "ready", duration: 5.0) |> Repo.update!()

      {:ok, source} =
        Assets.create_subtitle(%{
          video_id: video.id,
          language: "nl",
          path: "#{embed.hash}/subtitle_nl.vtt"
        })

      try do
        owner = self()

        tasks =
          for _ <- 1..2 do
            Task.Supervisor.async(supervisor, fn ->
              Sandbox.unboxed_run(Repo, fn ->
                send(owner, {:translation_ready, self()})

                receive do
                  :translate ->
                    SubtitleTranslations.request(space, embed, source.id, ["en"], enqueue: false)
                end
              end)
            end)
          end

        assert_receive {:translation_ready, first}
        assert_receive {:translation_ready, second}
        send(first, :translate)
        send(second, :translate)
        results = Enum.map(tasks, &Task.await/1)
        assert Enum.count(results, &match?({:ok, [_]}, &1)) == 1
        assert Enum.count(results, &(&1 == {:error, :translation_already_running})) == 1
        assert [_] = SubtitleTranslations.list(space, embed)
      after
        from(r in Run, where: fragment("?->>'video_id'", r.input) == ^video.id)
        |> Repo.delete_all()

        Repo.delete!(space)

        if is_nil(existing_template) do
          case Repo.get_by(Template, slug: "translate_subtitle") do
            nil -> :ok
            template -> Repo.delete!(template)
          end
        end
      end
    end)
  end
end
