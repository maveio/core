defmodule MaveCore.Flow.PipelineAssistantTest do
  use MaveCore.DataCase, async: false

  alias MaveCore.Flow.{Pipeline, PipelineAssistant, Presets}
  alias MaveCore.Spaces.Space
  alias MaveCore.TestSupport.{PipelineAssistantStub, StepPluginStub}

  defmodule NoAssistant do
    @behaviour MaveCore.UsageLimits
    def can_create_video_embed?(_space), do: :ok
    def can_add_space_member?(_space, _role), do: :ok
    def can_use_pipeline_assistant?(_space), do: {:error, :plan}
  end

  setup do
    previous =
      for key <- [
            :pipeline_assistant_provider,
            :pipeline_assistant_stub,
            :flow_step_plugins,
            :step_plugin_stub_availability,
            :usage_limits_backend
          ],
          do: {key, Application.get_env(:mave_core, key)}

    Application.put_env(:mave_core, :pipeline_assistant_provider, PipelineAssistantStub)
    Application.put_env(:mave_core, :flow_step_plugins, [StepPluginStub])

    on_exit(fn ->
      for {key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(:mave_core, key),
          else: Application.put_env(:mave_core, key, value)
      end
    end)

    {:ok, preset} = Presets.fetch("publish_default")
    %{definition: preset["definition"]}
  end

  defp suggest(operations, reply \\ "Here is my proposal.") do
    test = self()

    Application.put_env(:mave_core, :pipeline_assistant_stub, fn request ->
      send(test, {:request, request})
      {:ok, %{reply: reply, operations: operations}}
    end)
  end

  defp turn_off(step_id), do: %{"action" => "turn_off", "step_id" => step_id}
  defp turn_on(step_id), do: %{"action" => "turn_on", "step_id" => step_id}

  defp set(step_id, key, value),
    do: %{"action" => "set_setting", "step_id" => step_id, "setting" => key, "value" => value}

  describe "propose/4" do
    test "turns a step off with the steps that need it, like the editor", %{
      definition: definition
    } do
      suggest([turn_off("video_h264_uhd")], "No more 4K.")

      assert {:ok, proposal} =
               PipelineAssistant.propose(definition, %{}, "Do not generate 4K for this space")

      assert proposal.reply == "No more 4K."
      assert proposal.rejected == []
      assert proposal.overrides == Pipeline.put_step_enabled(%{}, "video_h264_uhd", false)

      assert [%{kind: :off, step_id: "video_h264_uhd", text: "Turn off " <> _} | follows] =
               proposal.changes

      assert Enum.all?(follows, &(&1.kind == :follows))

      assert Enum.sort(Enum.map(follows, & &1.step_id)) ==
               Pipeline.also_disabled(definition, %{}, "video_h264_uhd")

      assert Enum.find(follows, &(&1.step_id == "clip_hevc_uhd")).text =~
               "turns off too, because it needs Transcode Video H264 UHD"

      assert {:ok, _definition} = Pipeline.apply(definition, proposal.overrides)
    end

    test "sets an editable setting", %{definition: definition} do
      suggest([set("transcribe_audio", "context", "Northwind Studio")])

      assert {:ok, proposal} =
               PipelineAssistant.propose(definition, %{}, "Use our company name as context")

      assert proposal.overrides["settings"] ==
               %{"transcribe_audio" => %{"context" => "Northwind Studio"}}

      assert [%{kind: :setting, step_id: "transcribe_audio", text: text}] = proposal.changes
      assert text =~ "of Transcribe Audio to \"Northwind Studio\""
    end

    test "starts from the current draft and can undo it", %{definition: definition} do
      draft =
        %{}
        |> Pipeline.put_step_enabled("video_h264_uhd", false)
        |> Pipeline.put_setting("storyboard", "count", 40)

      suggest([turn_on("video_h264_uhd"), set("storyboard", "count", nil)])

      assert {:ok, proposal} = PipelineAssistant.propose(definition, draft, "Back to standard")
      assert proposal.overrides == Pipeline.empty()
      kinds = Enum.map(proposal.changes, &{&1.kind, &1.step_id})
      assert {:on, "video_h264_uhd"} in kinds
      assert {:follows, "clip_hevc_uhd"} in kinds
      assert {:setting, "storyboard"} in kinds
      assert Enum.find(proposal.changes, &(&1.kind == :setting)).text =~ "to its default"
    end

    test "leaves out what the editor would refuse", %{definition: definition} do
      suggest([
        turn_off("manifest"),
        turn_off("does_not_exist"),
        set("storyboard", "count", "many"),
        set("storyboard", "quality", "high"),
        set("transcribe_audio", "context", %{"nested" => true}),
        %{"action" => "delete_everything", "step_id" => "source"},
        turn_off("purge_cdn")
      ])

      assert {:ok, proposal} = PipelineAssistant.propose(definition, %{}, "Break things")

      assert [
               "Build Manifest is required and stays on.",
               "There is no step \"does_not_exist\" in this pipeline.",
               "Generate Storyboard: " <> _,
               "Generate Storyboard has no setting \"quality\" to change.",
               "Transcribe Audio: " <> _,
               "This is not a change the pipeline supports."
             ] = Enum.map(proposal.rejected, & &1.reason)

      assert proposal.overrides == Pipeline.put_step_enabled(%{}, "purge_cdn", false)
      assert [%{kind: :off, step_id: "purge_cdn"}] = proposal.changes
    end

    test "adds add-on steps unless they are unavailable", %{definition: definition} do
      suggest([turn_on("count_source")])

      assert {:ok, %{changes: [%{kind: :added, text: "Add Count Bytes Source"}]} = proposal} =
               PipelineAssistant.propose(definition, %{}, "Count the bytes")

      assert proposal.overrides["added_steps"] == ["count_source"]

      assert {:ok, %{changes: [], rejected: [%{reason: reason}], overrides: overrides}} =
               PipelineAssistant.propose(definition, %{}, "Count the bytes",
                 unavailable: %{"test.count_bytes" => "Included from the Pro plan."}
               )

      assert reason == "Count Bytes Source is not available: Included from the Pro plan."
      assert overrides == Pipeline.empty()

      suggest([turn_off("count_source")])

      assert {:ok, %{changes: [%{kind: :removed}], overrides: overrides}} =
               PipelineAssistant.propose(definition, proposal.overrides, "Stop counting")

      assert overrides == Pipeline.empty()
    end

    test "tells the model about the steps and earlier turns", %{definition: definition} do
      suggest([])
      draft = Pipeline.put_step_enabled(%{}, "video_h264_uhd", false)
      history = [%{role: :user, text: "Hi"}, %{role: :assistant, text: "Hello"}]

      assert {:ok, %{changes: [], overrides: ^draft}} =
               PipelineAssistant.propose(definition, draft, "  What can you do?  ",
                 history: history
               )

      assert_received {:request, request}
      assert request.message == "What can you do?"
      assert request.history == history

      steps = Map.new(request.steps, &{&1["id"], &1})
      assert steps["manifest"]["required"] == true
      assert steps["video_h264_uhd"]["state"] == "off"
      assert steps["clip_hevc_uhd"]["state"] == "off, because a step it needs is off"
      assert steps["clip_hevc_uhd"]["needs"] == ["inspect_media", "video_h264_uhd"]
      assert steps["count_source"]["add_on"] == true
      refute Map.has_key?(steps["video_h264_sd"], "add_on")

      assert [%{"key" => "context", "type" => "text", "label" => _}] =
               steps["transcribe_audio"]["settings"]
    end

    test "does not reach the model for an empty or oversized request", %{definition: definition} do
      suggest([])

      assert PipelineAssistant.propose(definition, %{}, "   ") == {:error, :empty_request}

      assert PipelineAssistant.propose(definition, %{}, String.duplicate("a", 1_001)) ==
               {:error, :request_too_long}

      refute_received {:request, _request}
    end

    test "passes a provider error on", %{definition: definition} do
      Application.put_env(:mave_core, :pipeline_assistant_stub, fn _request ->
        {:error, {:http_error, 503}}
      end)

      assert PipelineAssistant.propose(definition, %{}, "No 4K") == {:error, {:http_error, 503}}
    end
  end

  describe "access/1" do
    test "needs a configured model and the host's permission" do
      space = %Space{id: Ecto.UUID.generate(), hash: "space1"}

      assert PipelineAssistant.access(space) == {:error, :not_configured}

      suggest([])
      assert PipelineAssistant.access(space) == :ok

      Application.put_env(:mave_core, :usage_limits_backend, NoAssistant)
      assert PipelineAssistant.access(space) == {:error, :plan}
    end
  end
end
