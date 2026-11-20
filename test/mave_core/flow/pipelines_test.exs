defmodule MaveCore.Flow.PipelinesTest do
  use MaveCore.DataCase, async: false

  alias MaveCore.Accounts
  alias MaveCore.Flow
  alias MaveCore.Flow.{Definition, Pipeline, Pipelines, StepRun}
  alias MaveCore.Repo

  import Ecto.Query

  defmodule ManagedPipeline do
    @behaviour MaveCore.UsageLimits
    def can_create_video_embed?(_space), do: :ok
    def can_add_space_member?(_space, _role), do: :ok
    def can_edit_encoding_pipeline?(_space), do: {:error, :managed_pipeline}
  end

  setup do
    old_storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter)
    old_backend = Application.get_env(:mave_core, :usage_limits_backend)

    Application.put_env(
      :mave_core,
      :flow_storage_adapter,
      MaveCore.TestSupport.FlowStorageAdapterStub
    )

    on_exit(fn ->
      restore_env(:flow_storage_adapter, old_storage_adapter)
      restore_env(:usage_limits_backend, old_backend)
    end)

    {:ok, user} =
      Accounts.create_user("pipeline-#{System.unique_integer([:positive])}@example.com")

    [space] = Accounts.list_user_spaces(user)

    %{user: user, space: space}
  end

  describe "save/3" do
    test "stores each change as the next version", %{space: space, user: user} do
      assert Pipelines.current(space) == nil
      assert Pipelines.current_overrides(space) == Pipeline.empty()

      assert {:ok, first} =
               Pipelines.save(space, %{"disabled_steps" => ["video_h264_uhd"]},
                 user: user,
                 note: "  No 4K  "
               )

      assert first.version == 1
      assert first.note == "No 4K"
      assert first.created_by_id == user.id

      assert {:ok, second} =
               Pipelines.save(space, %{
                 "disabled_steps" => ["video_h264_uhd"],
                 "settings" => %{"transcribe_audio" => %{"context" => "Mave"}}
               })

      assert second.version == 2
      assert Pipelines.current(space).id == second.id
      assert Enum.map(Pipelines.list_versions(space), & &1.version) == [2, 1]
      assert Pipelines.get_version(space, 1).overrides == first.overrides
    end

    test "does not store a version without changes", %{space: space} do
      assert {:error, :unchanged} = Pipelines.save(space, Pipeline.empty())

      overrides = %{"disabled_steps" => ["video_h264_uhd"]}
      assert {:ok, _version} = Pipelines.save(space, overrides)
      assert {:error, :unchanged} = Pipelines.save(space, overrides)

      assert {:ok, %{version: 2}} = Pipelines.save(space, Pipeline.empty())
    end

    test "rejects overrides that break a dependency rule", %{space: space} do
      assert {:error, {:invalid, [%{code: :required_step}]}} =
               Pipelines.save(space, %{"disabled_steps" => ["manifest"]})

      assert Pipelines.current(space) == nil
    end

    test "respects the host's policy", %{space: space} do
      Application.put_env(:mave_core, :usage_limits_backend, ManagedPipeline)

      assert {:error, :managed_pipeline} =
               Pipelines.save(space, %{"disabled_steps" => ["video_h264_uhd"]})
    end
  end

  describe "runs" do
    test "use the space's pipeline as a version of a template derived for the space", %{
      space: space
    } do
      {:ok, _} = Pipelines.save(space, %{"disabled_steps" => ["video_h264_uhd"]})

      assert {:ok, run} = start_run(space)

      assert run.flow_template.slug =~ ~r/^publish_default\.space-[0-9a-f]{32}$/
      assert Pipelines.derived_slug?(run.flow_template.slug)

      definition = run.flow_version.definition
      assert :ok = Definition.validate(definition)
      refute Definition.step_by_id(definition, "video_h264_uhd")
      refute Definition.step_by_id(definition, "hls_h264_uhd")
      assert Definition.step_by_id(definition, "video_h264_qhd")

      assert %{"version" => 1, "base_template" => "publish_default", "space_hash" => hash} =
               definition["pipeline"]

      assert hash == space.hash

      step_ids =
        Repo.all(from step in StepRun, where: step.flow_run_id == ^run.id, select: step.step_id)

      refute "video_h264_uhd" in step_ids
      assert "manifest" in step_ids

      refute Enum.any?(Flow.list_templates(), &Pipelines.derived_slug?(&1.slug))
    end

    test "reuse the stored flow version until the pipeline changes", %{space: space} do
      {:ok, _} = Pipelines.save(space, %{"disabled_steps" => ["video_h264_uhd"]})

      assert {:ok, first} = start_run(space)
      assert {:ok, second} = start_run(space)
      assert second.flow_version_id == first.flow_version_id

      {:ok, _} =
        Pipelines.save(space, %{"disabled_steps" => ["video_h264_qhd", "video_h264_uhd"]})

      assert {:ok, third} = start_run(space)
      assert third.flow_template_id == first.flow_template_id
      assert third.flow_version_id != first.flow_version_id

      # Earlier runs keep the definition they started with.
      assert Definition.step_by_id(
               Flow.get_run!(first.id).flow_version.definition,
               "video_h264_qhd"
             )

      refute Definition.step_by_id(third.flow_version.definition, "video_h264_qhd")
    end

    test "leave the flow untouched without overrides, without the option or with a pinned version",
         %{space: space} do
      assert {:ok, run} = start_run(space)
      assert run.flow_template.slug == "publish_default"

      {:ok, _} = Pipelines.save(space, %{"disabled_steps" => ["video_h264_uhd"]})

      assert {:ok, run} = Flow.start_run("publish_default", input(space), enqueue: false)
      assert run.flow_template.slug == "publish_default"

      assert {:ok, run} =
               Flow.start_run("publish_default", input(space),
                 enqueue: false,
                 space_pipeline: space,
                 version: run.flow_version.version
               )

      assert run.flow_template.slug == "publish_default"
    end

    test "fall back to the flow when the overrides no longer fit it", %{space: space} do
      {:ok, template} =
        Flow.create_template(%{
          "slug" => "pipeline-fallback-#{System.unique_integer([:positive])}",
          "name" => "Pipeline Fallback"
        })

      {:ok, _version} =
        Flow.create_version(template.id, %{
          "definition" => %{
            "steps" => [
              %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"},
              %{
                "id" => "video_h264_uhd",
                "type" => "media.transcode_h264_ladder",
                "name" => "Required 4K",
                "depends_on" => ["source"]
              }
            ]
          }
        })

      {:ok, _} = Pipelines.save(space, %{"disabled_steps" => ["video_h264_uhd"]})

      assert {:ok, run} =
               Flow.start_run(template.slug, input(space), enqueue: false, space_pipeline: space)

      assert run.flow_template_id == template.id
    end

    test "run to completion with steps turned off and settings changed", %{space: space} do
      {:ok, _} =
        Pipelines.save(space, %{
          "disabled_steps" => ["video_h264_qhd", "video_h264_uhd", "transcribe_audio"],
          "settings" => %{"storyboard" => %{"count" => 24}}
        })

      assert {:ok, run} =
               Flow.run_inline(
                 "publish_default",
                 Map.merge(input(space), %{
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
                   }
                 }),
                 space_pipeline: space
               )

      assert run.status == "succeeded"
      assert Pipelines.derived_slug?(run.flow_template.slug)

      storyboard = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "storyboard")
      assert storyboard.input["params"]["count"] == 24
      refute Repo.get_by(StepRun, flow_run_id: run.id, step_id: "transcribe_audio")
      refute Repo.get_by(StepRun, flow_run_id: run.id, step_id: "hls_master_high")
    end
  end

  defp start_run(space) do
    Flow.start_run("publish_default", input(space), enqueue: false, space_pipeline: space)
  end

  defp input(space) do
    %{
      "space_hash" => space.hash,
      "embed_hash" => "LeDE9v86ye",
      "input_url" => "https://example.com/video.mp4"
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)
end
