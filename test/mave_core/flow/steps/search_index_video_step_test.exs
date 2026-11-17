defmodule MaveCore.Flow.Steps.SearchIndexVideoStepTest do
  use MaveCore.DataCase, async: false

  alias MaveCore.Accounts
  alias MaveCore.Assets.{Asset, Video}
  alias MaveCore.Embeds.Embed
  alias MaveCore.Flow
  alias MaveCore.Flow.{Definition, Presets, StepRegistry}
  alias MaveCore.Flow.Steps.{MediaDetectScenesStep, SearchIndexVideoStep}
  alias MaveCore.Search
  alias MaveCore.TestSupport.FlowStorageAdapterStub, as: Storage

  @space "ubg50"
  @embed "LeDE9v86ye"
  @bucket "space-ubg50"
  @observations_key "#{@embed}/audio_description/observations.json"
  @search %{"sources" => ["visual", "transcript"]}

  defmodule VisionStub do
    @moduledoc false

    # One observation per still, describing the frame number it was shown.
    def chat_json(system, content, opts) do
      send(self(), {:vision, system, opts[:usage_operation]})

      rows =
        for %{"type" => "text", "text" => label} <- content do
          [_, index] = Regex.run(~r/Frame (\d+);/, label)

          %{
            "frame" => String.to_integer(index),
            "setting" => "A workshop",
            "people_and_objects" => ["A carpenter"],
            "actions" => ["The carpenter saws plank #{index}"],
            "visible_text" => ["SAFETY FIRST"],
            "text_elements" => [],
            "changes" => [],
            "uncertainties" => []
          }
        end

      {:ok, %{"observations" => rows}}
    end
  end

  defmodule FailingVision do
    def chat_json(_system, _content, _opts), do: {:error, {:http_error, 401}}
  end

  defmodule BusyVision do
    def chat_json(_system, _content, _opts), do: {:error, {:http_error, 503}}
  end

  defmodule NoVision do
    def chat_json(_system, _content, _opts), do: raise("vision must not be called")
  end

  setup do
    old = %{
      storage: Application.get_env(:mave_core, :flow_storage_adapter),
      ad: Application.get_env(:mave_core, :audio_description)
    }

    Application.put_env(:mave_core, :flow_storage_adapter, Storage)
    Application.put_env(:mave_core, :audio_description, chat_provider: VisionStub)
    Storage.reset!()

    on_exit(fn ->
      restore(:flow_storage_adapter, old.storage)
      restore(:audio_description, old.ad)
    end)

    :ok
  end

  test "the publishing presets index after the steps whose output they read" do
    for slug <- ["publish_default", "publish_local", "publish_remote", "publish_remote_local"] do
      {:ok, %{"definition" => definition}} = Presets.fetch(slug)
      assert :ok = Definition.validate(definition)

      assert %{
               "type" => "search.index_video",
               "required" => false,
               "lane" => "background",
               "depends_on" => ["detect_scenes", "describe_video", "transcribe_audio"]
             } = Enum.find(definition["steps"], &(&1["id"] == "index_search"))

      refute Enum.any?(definition["steps"], &("index_search" in Map.get(&1, "depends_on", [])))
    end

    assert StepRegistry.executor_for("search.index_video") == :inline
  end

  test "skips itself unless the run asks for search" do
    assert {:ok, %{"status" => "skipped", "reason" => "not_requested"}, []} =
             SearchIndexVideoStep.run(%{"id" => "index_search"}, %{
               run_input: base_input(),
               dependency_outputs: %{}
             })
  end

  test "scene detection also runs for visual search, without audio description" do
    outputs = %{"inspect_media" => %{"duration" => 601.0, "has_video" => true}}

    assert {:ok, %{"status" => "skipped", "reason" => "not_requested"}, []} =
             MediaDetectScenesStep.run(%{"id" => "detect_scenes"}, %{
               run_input: Map.put(base_input(), "search", %{"sources" => ["transcript"]}),
               dependency_outputs: outputs
             })

    # Requested, so it gets as far as the same length limit audio description has.
    assert {:ok, %{"status" => "skipped", "reason" => "video_too_long"}, []} =
             MediaDetectScenesStep.run(%{"id" => "detect_scenes"}, %{
               run_input: Map.put(base_input(), "search", @search),
               dependency_outputs: outputs
             })
  end

  test "describes the stills and stores visual and transcript moments" do
    put_scenes()
    put_transcript()

    assert {:ok, output, []} = SearchIndexVideoStep.run(%{"id" => "index_search"}, context())

    assert %{
             "status" => "ok",
             "language" => "nl",
             "moment_count" => 3,
             "visual_moment_count" => 2,
             "transcript_moment_count" => 1,
             "visual" => %{"status" => "ok", "observations_reused" => false},
             "transcript" => %{"status" => "ok"},
             "document_key" => "#{@embed}/search/moments.json"
           } = output

    assert_received {:vision, instruction, "vision"}
    assert instruction =~ "Dutch"

    {:ok, json} = Storage.get(@bucket, output["document_key"], nil)

    assert {:ok, moments, "nl"} = json |> Jason.decode!() |> Search.Document.from_json()

    assert [
             %{
               source: "visual",
               start: 1.0,
               end: 6.0,
               text:
                 "A workshop. A carpenter. The carpenter saws plank 0. On screen: SAFETY FIRST"
             },
             %{source: "visual", start: 6.0, end: 12.0},
             %{source: "transcript", start: 2.0, end: 5.0, text: "Meet het hout twee keer."}
           ] = moments

    # Saved where audio description looks, so a later run does not pay again.
    {:ok, cache} = Storage.get(@bucket, @observations_key, nil)
    assert %{"schema_version" => 1, "language" => "nl", "frames" => [_, _]} = Jason.decode!(cache)
  end

  test "reuses the observations audio description already paid for" do
    put_scenes()
    Application.put_env(:mave_core, :audio_description, chat_provider: NoVision)

    frames =
      for {time, id} <- [{1.0, 0}, {6.0, 1}] do
        %{
          "id" => id,
          "time" => time,
          "scene" => 0,
          "setting" => "A beach at sunset",
          "people_and_objects" => [],
          "actions" => ["Wave #{id} rolls in"],
          "visible_text" => [],
          "changes" => [],
          "uncertainties" => []
        }
      end

    Storage.put(
      @bucket,
      @observations_key,
      Jason.encode!(%{"schema_version" => 1, "language" => "en", "frames" => frames}),
      "application/json",
      nil
    )

    assert {:ok, output, []} = SearchIndexVideoStep.run(%{"id" => "index_search"}, context())

    assert %{
             "visual_moment_count" => 2,
             "visual" => %{"observations_reused" => true},
             "transcript" => %{"status" => "skipped", "reason" => "no_transcript"}
           } = output
  end

  test "falls back to the transcript when the picture cannot be analysed" do
    put_scenes()
    put_transcript()
    Application.put_env(:mave_core, :audio_description, chat_provider: FailingVision)

    assert {:ok, output, []} = SearchIndexVideoStep.run(%{"id" => "index_search"}, context())

    assert %{
             "status" => "ok",
             "visual_moment_count" => 0,
             "transcript_moment_count" => 1,
             "visual" => %{"status" => "unavailable"}
           } = output

    # Skipped scene detection (no picture, too long) is reported, not an error.
    skipped =
      put_in(context(), [:dependency_outputs, "detect_scenes"], %{
        "status" => "skipped",
        "reason" => "video_too_long"
      })

    assert {:ok, %{"visual" => %{"status" => "skipped", "reason" => "video_too_long"}}, []} =
             SearchIndexVideoStep.run(%{"id" => "index_search"}, skipped)
  end

  test "a busy provider fails the step so the engine retries it" do
    put_scenes()
    Application.put_env(:mave_core, :audio_description, chat_provider: BusyVision)

    assert {:error, {:search_index_video_failed, _reason}} =
             SearchIndexVideoStep.run(%{"id" => "index_search"}, context())
  end

  test "a finished run makes the video findable" do
    {space, embed, video} = video_fixture("Workbench build")

    definition = %{
      "steps" => [
        %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"},
        %{
          "id" => "transcribe_audio",
          "type" => "ai.transcribe_audio",
          "name" => "Transcribe Audio",
          "depends_on" => ["source"],
          "required" => false
        },
        %{
          "id" => "index_search",
          "type" => "search.index_video",
          "name" => "Index Video For Search",
          "depends_on" => ["transcribe_audio"],
          "required" => false
        }
      ]
    }

    {:ok, template} = Flow.create_template(%{"slug" => "index_only", "name" => "Index Only"})
    {:ok, _version} = Flow.create_version(template.id, %{"definition" => definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => space.hash,
          "embed_hash" => embed.hash,
          "input_url" => "https://example.com/video.mp4",
          "search" => %{"sources" => ["transcript"]},
          "transcription_segments" => [
            %{"start" => 4.0, "end" => 7.5, "text" => "Clamp the workbench legs first."}
          ]
        },
        enqueue: false
      )

    for step <- ["source", "transcribe_audio", "index_search"] do
      {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)
      assert {:ok, _output} = Flow.execute_step(run.id, step, enqueue_coordinator: false)
    end

    assert Search.moment_count(video) == 1

    assert [%{embed: found, matched_on: ["transcript"], moments: [%{start: 4.0, end: 7.5}]}] =
             Search.search(space, "clamp legs")

    assert found.id == embed.id
  end

  defp context do
    %{
      run_input: base_input() |> Map.put("search", @search) |> Map.put("language", "nl"),
      dependency_outputs: %{
        "detect_scenes" => %{"status" => "ok", "scenes_key" => "scenes.json"},
        "transcribe_audio" =>
          case Storage.get(@bucket, "transcript.json", nil) do
            {:ok, _} -> %{"status" => "ok", "subtitle_json_key" => "transcript.json"}
            _ -> %{"status" => "unavailable"}
          end
      }
    }
  end

  defp put_scenes do
    document = %{
      "duration" => 12,
      "scenes" => [%{"start" => 0, "end" => 12}],
      "stills" => [
        %{"scene" => 0, "time" => 1.0, "key" => "still-0.jpg"},
        %{"scene" => 0, "time" => 6.0, "key" => "still-1.jpg"}
      ]
    }

    Storage.put(@bucket, "scenes.json", Jason.encode!(document), "application/json", nil)
    Storage.put(@bucket, "still-0.jpg", "image", "image/jpeg", nil)
    Storage.put(@bucket, "still-1.jpg", "image", "image/jpeg", nil)
  end

  defp put_transcript do
    Storage.put(
      @bucket,
      "transcript.json",
      Jason.encode!(%{
        "segments" => [%{"start" => 2.0, "end" => 5.0, "text" => "Meet het hout twee keer."}]
      }),
      "application/json",
      nil
    )
  end

  defp video_fixture(name) do
    email = "search-step-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(email)
    space = user.current_space_membership.space

    asset = Repo.insert!(%Asset{space_id: space.id, name: name})
    video = Repo.insert!(%Video{asset_id: asset.id, status: "ready", file_name: "#{name}.mp4"})
    asset |> Ecto.Changeset.change(current_video_id: video.id) |> Repo.update!()

    hash =
      System.unique_integer([:positive])
      |> Integer.to_string(36)
      |> String.pad_leading(10, "0")
      |> String.slice(-10, 10)

    embed =
      Repo.insert!(%Embed{space_id: space.id, asset_id: asset.id, hash: hash, type: :video})

    {space, embed, video}
  end

  defp base_input do
    %{"space_hash" => @space, "embed_hash" => @embed, "version" => 0, "region" => nil}
  end

  defp restore(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore(key, value), do: Application.put_env(:mave_core, key, value)
end
