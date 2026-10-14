defmodule MaveCore.Transcription.SubtitleTranslationsTest do
  use MaveCore.DataCase, async: false

  alias MaveCore.{Accounts, Assets, Embeds, Flow, Repo}
  alias MaveCore.Assets.{AudioTrack, Rendition, Subtitle, Video}
  alias MaveCore.Flow.Run
  alias MaveCore.Media.Storage

  alias MaveCore.TestSupport.{
    FlowStorageAdapterStub,
    SubtitleTranslationProviderStub,
    SubtitleTranslationUsageStub
  }

  alias MaveCore.Transcription.SubtitleTranslations

  setup do
    previous =
      Map.new(
        [:flow_storage_adapter, :subtitle_translation_provider, :usage_limits_backend],
        &{&1, Application.get_env(:mave_core, &1)}
      )

    Application.put_env(:mave_core, :flow_storage_adapter, FlowStorageAdapterStub)

    Application.put_env(
      :mave_core,
      :subtitle_translation_provider,
      SubtitleTranslationProviderStub
    )

    Application.put_env(:mave_core, :usage_limits_backend, SubtitleTranslationUsageStub)
    FlowStorageAdapterStub.reset!()

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if value,
          do: Application.put_env(:mave_core, key, value),
          else: Application.delete_env(:mave_core, key)
      end)

      FlowStorageAdapterStub.reset!()
    end)

    {:ok, user} =
      Accounts.create_user(
        "subtitle-translation-#{System.unique_integer([:positive])}@example.com"
      )

    space = user.current_space_membership.space
    {:ok, embed} = Embeds.create_video_embed(space, %{name: "Translation source"})
    {:ok, embed} = Embeds.begin_video_upload(space.hash, embed.hash, %{"title" => "source.mp4"})

    video =
      embed.asset.current_video
      |> Ecto.Changeset.change(status: "ready", duration: 5.0)
      |> Repo.update!()

    version = Embeds.current_video_version(embed)
    prefix = if version > 0, do: "#{embed.hash}/v#{version}", else: embed.hash

    {:ok, source} =
      Assets.create_subtitle(%{
        video_id: video.id,
        language: "nl",
        path: prefix <> "/subtitle_nl.vtt"
      })

    bucket = Storage.bucket_for_space(space.hash, space.region)

    {:ok, _} =
      FlowStorageAdapterStub.put_public(
        bucket,
        source.path,
        "WEBVTT\n\n00:00:01.125 --> 00:00:03.500\nHallo wereld\n",
        "text/vtt",
        space.region
      )

    rendition =
      Repo.insert!(%Rendition{
        video_id: video.id,
        rendition_key: prefix <> "/h264_sd_hls/playlist.m3u8",
        type: :video,
        codec: :h264,
        container: :hls,
        size: :sd,
        progress: 100.0,
        file_size: 1000
      })

    audio =
      Repo.insert!(%AudioTrack{
        video_id: video.id,
        filename: "audio_nl.mp3",
        language: "nl",
        default: true,
        codec: "mp3"
      })

    %{
      space: space,
      embed: embed,
      video: video,
      source: source,
      bucket: bucket,
      prefix: prefix,
      rendition: rendition,
      audio: audio
    }
  end

  test "each target gets a small immutable flow and adds only its subtitle", ctx do
    assert {:ok, [en, fr]} = request(ctx, ["en", "fr"])
    assert en.input["video_id"] == ctx.video.id
    assert en.input["source_subtitle_id"] == ctx.source.id

    assert Enum.map(en.step_runs, & &1.step_type) |> Enum.sort() == [
             "ai.translate_subtitles",
             "subtitle.load_translation_source",
             "subtitle.publish_translation"
           ]

    assert complete(en).status == "succeeded"
    assert complete(fr).status == "succeeded"
    assert_receive {:subtitle_translation_requested, %{segments: [%{start: 1.125, end: 3.5}]}, _}
    assert Repo.get!(Rendition, ctx.rendition.id) == ctx.rendition
    assert Repo.get!(AudioTrack, ctx.audio.id) == ctx.audio
    assert Repo.get!(Subtitle, ctx.source.id) == ctx.source
    assert Repo.get!(Video, ctx.video.id) == ctx.video

    assert Enum.sort(Enum.map(Assets.all_subtitles_for_video(ctx.video.id), & &1.language)) == [
             "en",
             "fr",
             "nl"
           ]

    translated = Repo.get_by!(Subtitle, video_id: ctx.video.id, language: "en")
    assert translated.source == "translated"
    assert translated.path =~ "/translations/"
    assert {:ok, body} = FlowStorageAdapterStub.get(ctx.bucket, translated.path, ctx.space.region)
    assert body =~ "00:00:01.125 --> 00:00:03.500"

    assert {:ok, manifest} =
             FlowStorageAdapterStub.get(
               ctx.bucket,
               ctx.embed.hash <> "/manifest.json",
               ctx.space.region
             )

    assert Enum.sort(Enum.map(Jason.decode!(manifest)["subtitles"], & &1["language"])) == [
             "en",
             "fr",
             "nl"
           ]

    assert {:ok, playlist} =
             FlowStorageAdapterStub.get(
               ctx.bucket,
               ctx.prefix <> "/playlist.m3u8",
               ctx.space.region
             )

    assert playlist =~ "LANGUAGE=\"en\""
    assert playlist =~ "LANGUAGE=\"fr\""
    assert {:error, :target_language_exists} = request(ctx, ["en"])
  end

  test "valid sub-100ms cues keep their exact timing in translated VTT and JSON", ctx do
    {:ok, _} =
      FlowStorageAdapterStub.put_public(
        ctx.bucket,
        ctx.source.path,
        "WEBVTT\n\n00:00:01.000 --> 00:00:01.050\nHallo\n",
        "text/vtt",
        ctx.space.region
      )

    {:ok, [run]} = request(ctx, ["en"])
    assert complete(run).status == "succeeded"
    subtitle = Repo.get_by!(Subtitle, video_id: ctx.video.id, language: "en")
    {:ok, vtt} = FlowStorageAdapterStub.get(ctx.bucket, subtitle.path, ctx.space.region)
    assert vtt =~ "00:00:01.000 --> 00:00:01.050"

    {:ok, json} =
      FlowStorageAdapterStub.get(
        ctx.bucket,
        String.replace_suffix(subtitle.path, ".vtt", ".json"),
        ctx.space.region
      )

    assert [%{"start" => 1.0, "end" => 1.05}] = Jason.decode!(json)["segments"]
  end

  test "background publication blocks requests and execution until it is finished", ctx do
    {:ok, [translation]} = request(ctx, ["en"])

    {:ok, publishing} =
      Flow.start_run(
        "publish_local",
        %{
          "space_hash" => ctx.space.hash,
          "embed_hash" => ctx.embed.hash,
          "version" => Embeds.current_video_version(ctx.embed)
        },
        enqueue: false
      )

    assert {:error, :video_still_publishing} = request(ctx, ["fr"])

    publishing =
      publishing
      |> Ecto.Changeset.change(input: Map.delete(publishing.input, "video_id"))
      |> Repo.update!()

    assert {:error, :video_still_publishing} = request(ctx, ["fr"])

    assert {:error, :video_still_publishing} =
             SubtitleTranslations.authorize_execution(translation.input)

    publishing |> Ecto.Changeset.change(status: "succeeded") |> Repo.update!()
    assert complete(translation).status == "succeeded"
    assert {:ok, [_]} = request(ctx, ["fr"])
  end

  test "uploaded SRT and transcription JSON follow the same timed translation path", ctx do
    sources = [
      {"en", "1\n00:00:01,125 --> 00:00:03,500\nHallo wereld\n"},
      {"fr",
       Jason.encode!(%{
         "text" => "Hallo wereld",
         "segments" => [%{"start" => 1.125, "end" => 3.5, "text" => "Hallo wereld"}]
       })}
    ]

    for {target, body} <- sources do
      {:ok, _} =
        FlowStorageAdapterStub.put_public(
          ctx.bucket,
          ctx.source.path,
          body,
          "text/plain",
          ctx.space.region
        )

      {:ok, [run]} = request(ctx, [target])
      assert complete(run).status == "succeeded"
      translated = Repo.get_by!(Subtitle, video_id: ctx.video.id, language: target)
      {:ok, vtt} = FlowStorageAdapterStub.get(ctx.bucket, translated.path, ctx.space.region)
      assert vtt =~ "00:00:01.125 --> 00:00:03.500"
    end
  end

  test "duplicates, existing languages and foreign source IDs are rejected", ctx do
    assert {:error, :source_language_selected} = request(ctx, ["nl"])

    assert {:error, :source_subtitle_not_found} =
             SubtitleTranslations.request(ctx.space, ctx.embed, Ecto.UUID.generate(), ["en"],
               enqueue: false
             )

    assert {:ok, [_]} = request(ctx, ["en", "en"])
    assert {:error, :translation_already_running} = request(ctx, ["en"])
    assert {:error, :invalid_target_language} = request(ctx, ["../../en"])
    assert {:error, :target_languages_required} = request(ctx, [])
  end

  test "target choices exclude existing languages and all active runs beyond history limit",
       ctx do
    {:ok, [active]} = request(ctx, ["en"])

    for _ <- 1..31 do
      Repo.insert!(%Run{
        flow_template_id: active.flow_template_id,
        flow_version_id: active.flow_version_id,
        status: "failed",
        input: Map.put(active.input, "target_language", "fr")
      })
    end

    options = SubtitleTranslations.target_languages(ctx.space, ctx.embed)
    refute Enum.any?(options, fn {_label, language} -> language in ["nl", "en"] end)
    assert Enum.any?(options, fn {_label, language} -> language == "fr" end)
  end

  test "a denied request creates no flows and execution rechecks the callback", ctx do
    Process.put(:allow_subtitle_translation, false)
    assert {:error, {:translation_not_allowed, :limit_reached}} = request(ctx, ["en"])
    assert SubtitleTranslations.list(ctx.space, ctx.embed) == []
    Process.put(:allow_subtitle_translation, true)
    {:ok, [run]} = request(ctx, ["en"])
    Process.put(:allow_subtitle_translation, false)
    assert complete(run).status == "failed"
    refute_received {:subtitle_translation_requested, _, _}
    assert Assets.all_subtitles_for_video(ctx.video.id) == [ctx.source]
  end

  test "provider failures are explicit and preserve all media", ctx do
    Embeds.Events.subscribe(ctx.space.id, ctx.embed.id)
    Process.put(:subtitle_translation_response, {:error, :provider_unavailable})
    {:ok, [run]} = request(ctx, ["en"])
    assert complete(run).status == "failed"
    assert_receive {:embed_updated, %{"action" => "subtitle_translation", "status" => "failed"}}
    assert Repo.get!(Rendition, ctx.rendition.id)
    assert Repo.get!(AudioTrack, ctx.audio.id)
    assert Assets.all_subtitles_for_video(ctx.video.id) == [ctx.source]
  end

  test "late normal step synchronization retains translations and avoids duplicate target languages",
       ctx do
    {:ok, [translation]} = request(ctx, ["en"])
    assert complete(translation).status == "succeeded"
    translated = Repo.get_by!(Subtitle, video_id: ctx.video.id, language: "en")

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "late-subtitle-sync-#{System.unique_integer([:positive])}",
        "name" => "Late subtitle synchronization"
      })

    {:ok, _} =
      Flow.create_version(template.id, %{
        "definition" => %{
          "steps" => [
            %{"id" => "transcribe_audio", "type" => "ai.transcribe_audio", "name" => "Source"},
            %{
              "id" => "translate_subtitles",
              "type" => "ai.translate_subtitles",
              "name" => "Translate",
              "depends_on" => ["transcribe_audio"],
              "params" => %{"strict" => true}
            }
          ]
        }
      })

    {:ok, normal} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => ctx.space.hash,
          "embed_hash" => ctx.embed.hash,
          "region" => ctx.space.region,
          "version" => Embeds.current_video_version(ctx.embed)
        }, enqueue: false)

    # Represent the original source step whose output is already persisted. The
    # remaining ordinary step exercises the same post-commit metadata sync that
    # can arrive after a separately completed translation.
    source_step = Enum.find(normal.step_runs, &(&1.step_id == "transcribe_audio"))

    source_step
    |> Ecto.Changeset.change(
      status: "succeeded",
      output: %{
        "status" => "ok",
        "language" => "nl",
        "subtitle_json_key" =>
          SubtitleTranslations.output_prefix(translation.input) <> "/source.json",
        "subtitles" => [%{"language" => "nl", "path" => ctx.source.path}]
      }
    )
    |> Repo.update!()

    assert {:ok, _} = execute(normal, "translate_subtitles")
    assert Repo.get!(Subtitle, translated.id) == translated
    assert Enum.count(Assets.all_subtitles_for_video(ctx.video.id), &(&1.language == "en")) == 1

    # Normal full-flow finalization uses the same preservation rule.
    assert {:ok, %{status: "succeeded"}} = Flow.reconcile_run(normal.id, enqueue_jobs: false)
    assert Repo.get!(Subtitle, translated.id) == translated
    assert Enum.count(Assets.all_subtitles_for_video(ctx.video.id), &(&1.language == "en")) == 1
  end

  test "usage permission is checked again before calling the paid provider", ctx do
    {:ok, [run]} = request(ctx, ["en"])
    assert {:ok, _} = execute(run, "transcribe_audio")
    Process.put(:allow_subtitle_translation, false)
    assert {:error, _} = execute(run, "translate_subtitles")
    refute_received {:subtitle_translation_requested, _, _}
  end

  test "a replacement before loading the source does not invoke the provider", ctx do
    {:ok, [run]} = request(ctx, ["en"])

    {:ok, _} =
      Embeds.begin_video_upload(ctx.space.hash, ctx.embed.hash, %{"title" => "replacement.mp4"})

    assert complete(run).status == "failed"
    refute_received {:subtitle_translation_requested, _, _}
  end

  test "replacement after translation prevents publishing onto either version", ctx do
    {:ok, [run]} = request(ctx, ["en"])
    execute(run, "transcribe_audio")
    execute(run, "translate_subtitles")

    {:ok, replacement} =
      Embeds.begin_video_upload(ctx.space.hash, ctx.embed.hash, %{"title" => "replacement.mp4"})

    refute replacement.asset.current_video_id == ctx.video.id
    assert {:error, _} = execute(run, "publish_subtitle")
    assert Assets.all_subtitles_for_video(ctx.video.id) == [ctx.source]
    assert Assets.all_subtitles_for_video(replacement.asset.current_video_id) == []
    assert Repo.get!(Rendition, ctx.rendition.id)
  end

  test "replaying publication is idempotent", ctx do
    {:ok, [run]} = request(ctx, ["en"])
    completed = complete(run)
    output = Enum.find(completed.step_runs, &(&1.step_id == "translate_subtitles")).output
    assert {:ok, first} = SubtitleTranslations.publish(run.input, output)
    assert {:ok, second} = SubtitleTranslations.publish(run.input, output)
    assert first.id == second.id
    assert length(Assets.all_subtitles_for_video(ctx.video.id)) == 2
  end

  test "publication errors fail the finalizer and can be retried without deleting other tracks",
       ctx do
    {:ok, [run]} = request(ctx, ["en"])

    FlowStorageAdapterStub.fail_public_put!(
      ctx.bucket,
      ctx.embed.hash <> "/manifest.json",
      ctx.space.region
    )

    assert complete(run).status == "failed"
    assert Assets.all_subtitles_for_video(ctx.video.id) == [ctx.source]
    assert Repo.get!(Rendition, ctx.rendition.id)
  end

  test "default self-hosting policy allows translation without a callback", ctx do
    Application.delete_env(:mave_core, :usage_limits_backend)
    assert {:ok, [_]} = request(ctx, ["en"])
  end

  test "HLS storage errors fail publication instead of silently reporting completion", ctx do
    {:ok, [run]} = request(ctx, ["en"])

    FlowStorageAdapterStub.fail_public_put!(
      ctx.bucket,
      ctx.prefix <> "/playlist.m3u8",
      ctx.space.region
    )

    assert complete(run).status == "failed"
    assert Assets.all_subtitles_for_video(ctx.video.id) == [ctx.source]
    assert Repo.get!(Rendition, ctx.rendition.id) == ctx.rendition
    assert Repo.get!(AudioTrack, ctx.audio.id) == ctx.audio
  end

  test "videos without HLS can still publish translated subtitle manifests", ctx do
    Repo.delete!(ctx.rendition)
    {:ok, [run]} = request(ctx, ["en"])
    assert complete(run).status == "succeeded"
    assert Repo.get_by!(Subtitle, video_id: ctx.video.id, language: "en").source == "translated"
  end

  defp request(ctx, targets),
    do: SubtitleTranslations.request(ctx.space, ctx.embed, ctx.source.id, targets, enqueue: false)

  defp execute(run, step) do
    {:ok, _} = Flow.reconcile_run(run.id, enqueue_jobs: false)
    Flow.execute_step(run.id, step, enqueue_coordinator: false)
  end

  defp complete(run) do
    _ =
      Enum.reduce_while(
        ["transcribe_audio", "translate_subtitles", "publish_subtitle"],
        nil,
        fn step, _ ->
          case execute(run, step) do
            {:ok, _} -> {:cont, :ok}
            {:error, _} -> {:halt, :error}
          end
        end
      )

    {:ok, _} = Flow.reconcile_run(run.id, enqueue_jobs: false)
    Repo.get!(Run, run.id) |> Repo.preload(:step_runs)
  end
end
