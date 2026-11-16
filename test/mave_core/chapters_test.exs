defmodule MaveCore.ChaptersTest do
  use MaveCore.DataCase, async: false
  use Oban.Testing, repo: MaveCore.Repo

  alias MaveCore.Accounts
  alias MaveCore.Assets.{Asset, ChapterSet, Subtitle, Video}
  alias MaveCore.Chapters
  alias MaveCore.Embeds
  alias MaveCore.Embeds.{Embed, ManifestPublisher}
  alias MaveCore.Flow
  alias MaveCore.Spaces.Space
  alias MaveCore.TestSupport.ChapterTranscriptFixture, as: Fixture
  alias MaveCore.TestSupport.FlowStorageAdapterStub, as: Storage
  alias MaveCore.Workers.ChapterSuggestionWorker

  @bucket "space-abcde"

  defmodule NoChapters do
    @behaviour MaveCore.UsageLimits
    def can_create_video_embed?(_space), do: :ok
    def can_add_space_member?(_space, _role), do: :ok
    def can_use_automatic_chapters?(_space), do: {:error, :paid_plan_required}
  end

  setup do
    previous = Application.get_env(:mave_core, :flow_storage_adapter)
    previous_purger = Application.get_env(:mave_core, :cdn_cache_purger)
    previous_chapters = Application.get_env(:mave_core, :chapters)
    previous_backend = Application.get_env(:mave_core, :usage_limits_backend)
    Application.put_env(:mave_core, :flow_storage_adapter, Storage)
    Application.put_env(:mave_core, :cdn_cache_purger, fn _, _, _ -> :ok end)
    Application.put_env(:mave_core, :chapters, writer: MaveCore.Chapters.LocalWriter)
    Storage.reset!()

    on_exit(fn ->
      restore_env(:flow_storage_adapter, previous)
      restore_env(:cdn_cache_purger, previous_purger)
      restore_env(:chapters, previous_chapters)
      restore_env(:usage_limits_backend, previous_backend)
      Storage.reset!()
    end)

    :ok
  end

  describe "save_draft/2" do
    test "stores sorted, tidied chapters without publishing them" do
      %{video: video} = fixture()

      assert {:ok, %ChapterSet{draft: draft, published: []} = set} =
               Chapters.save_draft(video, [
                 %{"start" => 61.23456, "title" => " 2. Second  part. "},
                 %{"start" => 0, "title" => "Intro"}
               ])

      assert draft == [
               %{"start" => 0.0, "title" => "Intro"},
               %{"start" => 61.235, "title" => "Second part"}
             ]

      assert Chapters.unpublished_changes?(set)
      assert Chapters.published_cues(video) == []
    end

    test "rejects chapters that cannot be played" do
      %{video: video} = fixture()

      assert Chapters.save_draft(video, [%{"start" => "soon", "title" => "A"}]) ==
               {:error, :invalid_start}

      assert Chapters.save_draft(video, [%{"start" => 1, "title" => " "}]) ==
               {:error, :missing_title}

      assert Chapters.save_draft(video, [%{"start" => 9_999, "title" => "A"}]) ==
               {:error, :start_after_end}

      assert Chapters.save_draft(video, [
               %{"start" => 5, "title" => "A"},
               %{"start" => 5.0001, "title" => "B"}
             ]) == {:error, :duplicate_start}

      assert Chapters.get_set(video.id) == nil
    end
  end

  describe "publish/1 and unpublish/1" do
    test "publishing writes the chapters file and lists the chapters in the manifest" do
      %{embed: embed, video: video} = fixture()
      assert Chapters.publish(embed) == {:error, :no_chapters}

      {:ok, _set} =
        Chapters.save_draft(video, [
          %{"start" => 0, "title" => "Intro"},
          %{"start" => 35.7, "title" => "Tires & <chain>"}
        ])

      assert {:ok, manifest} = ManifestPublisher.current(embed)
      refute Map.has_key?(manifest, "chapters")

      assert {:ok, %ChapterSet{published: [_, _], published_at: %DateTime{}} = set} =
               Chapters.publish(embed)

      refute Chapters.unpublished_changes?(set)

      assert {:ok, vtt} = Storage.get(@bucket, "abcdefghij/chapters.vtt", "eu")
      assert Storage.public?(@bucket, "abcdefghij/chapters.vtt", "eu")

      assert vtt == """
             WEBVTT

             1
             00:00:00.000 --> 00:00:35.700
             Intro

             2
             00:00:35.700 --> 00:02:22.200
             Tires &amp; &lt;chain&gt;
             """

      {:ok, body} = Storage.get(@bucket, "abcdefghij/manifest.json", "eu")

      assert %{
               "chapters" => %{
                 "path" => path,
                 "cues" => [
                   %{"start" => +0.0, "end" => 35.7, "title" => "Intro"},
                   %{"start" => 35.7, "end" => 142.2, "title" => "Tires & <chain>"}
                 ]
               }
             } = Jason.decode!(body)

      assert path =~ ~r{/abcdefghij/chapters\.vtt\?e=\d+\z}

      assert Chapters.published_cues(video) == [
               %{"start" => 0.0, "end" => 35.7, "title" => "Intro"},
               %{"start" => 35.7, "end" => 142.2, "title" => "Tires & <chain>"}
             ]
    end

    test "edits after publishing stay in the draft until published again" do
      %{embed: embed, video: video} = fixture()
      {:ok, _set} = Chapters.save_draft(video, [%{"start" => 0, "title" => "Intro"}])
      {:ok, _set} = Chapters.publish(embed)

      {:ok, set} = Chapters.save_draft(video, [%{"start" => 0, "title" => "Welcome"}])
      assert Chapters.unpublished_changes?(set)
      assert [%{"title" => "Intro"}] = Chapters.published_cues(video)

      {:ok, _set} = Chapters.publish(embed)
      assert [%{"title" => "Welcome"}] = Chapters.published_cues(video)
    end

    test "unpublishing removes the chapters from playback and keeps the draft" do
      %{embed: embed, video: video} = fixture()
      {:ok, _set} = Chapters.save_draft(video, [%{"start" => 0, "title" => "Intro"}])
      {:ok, _set} = Chapters.publish(embed)

      assert {:ok, %ChapterSet{published: [], draft: [_]}} = Chapters.unpublish(embed)

      assert {:error, _reason} = Storage.get(@bucket, "abcdefghij/chapters.vtt", "eu")
      {:ok, body} = Storage.get(@bucket, "abcdefghij/manifest.json", "eu")
      refute Map.has_key?(Jason.decode!(body), "chapters")
      assert Chapters.published_cues(video) == []
    end

    test "chapters of a replaced video are not published with the new version" do
      %{embed: embed, video: video, asset: asset} = fixture()
      {:ok, _set} = Chapters.save_draft(video, [%{"start" => 0, "title" => "Intro"}])
      {:ok, _set} = Chapters.publish(embed)

      replacement = Repo.insert!(%Video{asset_id: asset.id, duration: 80.0, status: "ready"})
      asset |> Ecto.Changeset.change(current_video_id: replacement.id) |> Repo.update!()
      embed = Repo.get!(Embed, embed.id) |> Repo.preload([:space, asset: [:current_video]])

      assert Chapters.get_set_for_embed(embed) == nil
      assert {:ok, manifest} = ManifestPublisher.current(embed)
      refute Map.has_key?(manifest, "chapters")
    end
  end

  describe "generate/3" do
    test "suggests a draft from an uploaded subtitle file" do
      %{embed: embed, video: video} = fixture()
      subtitle(video, "en", "abcdefghij/subtitles/custom.vtt", Fixture.vtt())

      assert {:ok, %ChapterSet{} = set} = Chapters.generate(embed, video.id)

      assert %ChapterSet{
               status: "idle",
               generator: "local",
               inputs: ["transcript"],
               language: "en",
               published: [],
               generated_at: %DateTime{}
             } = set

      assert Enum.map(set.draft, & &1["start"]) == Fixture.topic_starts()
      assert Chapters.published_cues(video) == []
    end

    test "prefers the stored transcription and uses scene cuts when the video was analysed" do
      %{embed: embed, video: video} = fixture()
      subtitle(video, "en", "abcdefghij/subtitle_en.vtt", "WEBVTT\n")

      Storage.put(
        @bucket,
        "abcdefghij/subtitle_en.json",
        Fixture.json(),
        "application/json",
        "eu"
      )

      cuts = Fixture.topic_starts() |> tl() |> Enum.map(&Float.round(&1 - 0.8, 3))

      Storage.put(
        @bucket,
        "abcdefghij/audio_description/scenes.json",
        Jason.encode!(%{"cuts" => cuts}),
        "application/json",
        "eu"
      )

      assert {:ok, %ChapterSet{inputs: ["transcript", "scenes"], draft: draft}} =
               Chapters.generate(embed, video.id)

      assert Enum.map(draft, & &1["start"]) == [0.0 | cuts]
    end

    test "uses the transcript in the video's own language" do
      %{embed: embed, video: video} = fixture()
      video = video |> Ecto.Changeset.change(language: "en") |> Repo.update!()
      subtitle(video, "nl", "abcdefghij/subtitle_nl.vtt", "WEBVTT\n")
      subtitle(video, "en", "abcdefghij/subtitle_en.vtt", Fixture.vtt())

      assert {:ok, %ChapterSet{language: "en", draft: [_, _ | _]}} =
               Chapters.generate(embed, video.id)
    end

    test "records why there is no suggestion and keeps the existing draft" do
      %{embed: embed, video: video} = fixture()
      {:ok, _set} = Chapters.save_draft(video, [%{"start" => 0, "title" => "Mine"}])

      assert {:ok, %ChapterSet{status: "failed", reason: "no_transcript", draft: [_]}} =
               Chapters.generate(embed, video.id)

      assert Chapters.generate(embed, Ecto.UUID.generate()) == {:error, :video_not_found}
    end
  end

  describe "requesting suggestions" do
    test "request_suggestion/1 marks the set as generating and the job stores the draft" do
      %{embed: embed, video: video} = fixture()
      subtitle(video, "en", "abcdefghij/subtitle_en.vtt", Fixture.vtt())

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, %ChapterSet{status: "generating"}} = Chapters.request_suggestion(embed)

        assert_enqueued(
          worker: ChapterSuggestionWorker,
          args: %{"embed_id" => embed.id, "video_id" => video.id}
        )
      end)

      assert :ok =
               perform_job(ChapterSuggestionWorker, %{
                 "embed_id" => embed.id,
                 "video_id" => video.id
               })

      assert %ChapterSet{status: "idle", draft: [_, _, _, _]} = Chapters.get_set(video.id)
    end

    test "the job does nothing for a deleted embed" do
      %{embed: embed, video: video} = fixture()
      embed |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update!()

      assert :ok =
               perform_job(ChapterSuggestionWorker, %{
                 "embed_id" => embed.id,
                 "video_id" => video.id
               })

      assert Chapters.get_set(video.id) == nil
    end

    test "is refused when the host does not allow chapter suggestions" do
      %{embed: embed} = fixture()
      Application.put_env(:mave_core, :usage_limits_backend, NoChapters)

      assert Chapters.request_suggestion(embed) == {:error, :paid_plan_required}
    end

    test "a new transcript gets a suggestion only when the space turned automatic chapters on" do
      %{embed: embed, video: video, space: space} = fixture()
      subtitle(video, "en", "abcdefghij/subtitle_en.vtt", Fixture.vtt())

      assert Chapters.maybe_request_automatic_suggestion(embed, video) == :ok
      assert Chapters.get_set(video.id) == nil

      space |> Ecto.Changeset.change(automatic_chapters_enabled: true) |> Repo.update!()
      embed = Repo.get!(Embed, embed.id)

      # Jobs run inline in tests, so the draft is there right away.
      assert {:ok, _set} = Chapters.maybe_request_automatic_suggestion(embed, video)
      assert %ChapterSet{draft: [_, _, _, _]} = Chapters.get_set(video.id)
    end

    test "a finished transcription asks for a suggestion in spaces with automatic chapters" do
      assert {:ok, _installed} = Flow.install_preset("publish_default")

      for automatic? <- [false, true] do
        {:ok, user} =
          Accounts.create_user("chapters-flow-#{System.unique_integer([:positive])}@example.com")

        space =
          user.current_space_membership.space
          |> Ecto.Changeset.change(automatic_chapters_enabled: automatic?)
          |> Repo.update!()

        {:ok, embed} = Embeds.create_video_embed(space, %{name: "Talk"})

        {:ok, embed} =
          Embeds.begin_video_upload(space.hash, embed.hash, %{
            "title" => "talk.mp4",
            "source_url" => "https://example.com/talk.mp4",
            "upload_size" => 15
          })

        assert {:ok, %{status: "succeeded"}} =
                 Flow.run_inline("publish_default", %{
                   "space_hash" => space.hash,
                   "embed_hash" => embed.hash,
                   "input_url" => "https://example.com/talk.mp4",
                   "source_body" => "stub-media-body",
                   "source_content_type" => "video/mp4",
                   "media_package_hls_variant_strict" => false,
                   "media_package_hls_audio_strict" => false,
                   "media_probe" => %{
                     "duration" => 10.0,
                     "size_bytes" => 15,
                     "filetype" => "mp4",
                     "aspect_ratio" => "16 / 9",
                     "streams" => []
                   },
                   "transcription_text" => "Hello world from a chapters test",
                   "transcription_language" => "en"
                 })

        set = Chapters.get_set(embed.asset.current_video_id)

        # Ten seconds is too short for chapters; the attempt shows it was asked for.
        if automatic?,
          do: assert(%ChapterSet{status: "failed", reason: "too_short", draft: []} = set),
          else: assert(set == nil)
      end
    end

    test "a new transcript never replaces chapters somebody worked on" do
      %{embed: embed, video: video, space: space} = fixture()
      space |> Ecto.Changeset.change(automatic_chapters_enabled: true) |> Repo.update!()
      subtitle(video, "en", "abcdefghij/subtitle_en.vtt", Fixture.vtt())
      {:ok, _set} = Chapters.save_draft(video, [%{"start" => 0, "title" => "Mine"}])

      assert Chapters.maybe_request_automatic_suggestion(Repo.get!(Embed, embed.id), video) == :ok
      assert %ChapterSet{draft: [%{"title" => "Mine"}]} = Chapters.get_set(video.id)
    end

    test "a transcript for a video that is no longer current gets no suggestion" do
      %{embed: embed, video: video, space: space, asset: asset} = fixture()
      space |> Ecto.Changeset.change(automatic_chapters_enabled: true) |> Repo.update!()
      replacement = Repo.insert!(%Video{asset_id: asset.id, duration: 80.0, status: "ready"})
      asset |> Ecto.Changeset.change(current_video_id: replacement.id) |> Repo.update!()

      assert Chapters.maybe_request_automatic_suggestion(Repo.get!(Embed, embed.id), video) == :ok
      assert Chapters.get_set(video.id) == nil
    end
  end

  defp fixture do
    space = Repo.insert!(%Space{hash: "abcde", region: "eu"})
    asset = Repo.insert!(%Asset{space_id: space.id})

    video =
      Repo.insert!(%Video{asset_id: asset.id, duration: Fixture.duration(), status: "ready"})

    asset = asset |> Ecto.Changeset.change(current_video_id: video.id) |> Repo.update!()

    embed =
      Repo.insert!(%Embed{space_id: space.id, asset_id: asset.id, hash: "abcdefghij"})
      |> Repo.preload([:space, asset: [:current_video]])

    %{space: space, asset: asset, video: video, embed: embed}
  end

  defp subtitle(video, language, path, body) do
    Storage.put(@bucket, path, body, "text/vtt", "eu")
    Repo.insert!(%Subtitle{video_id: video.id, language: language, path: path})
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)
end
