defmodule MaveCore.Flow.StepPluginTest do
  use MaveCore.DataCase, async: false

  import ExUnit.CaptureLog

  alias MaveCore.Accounts
  alias MaveCore.Flow
  alias MaveCore.Flow.{Pipelines, StepPlugin, StepRegistry, StepRun}
  alias MaveCore.Repo
  alias MaveCore.TestSupport.StepPluginStub

  defmodule NoContract do
    def run(_step, _context), do: {:ok, %{}, []}
  end

  defmodule BadContract do
    def contract do
      %{
        type: "Not A Type",
        name: "",
        stage: "two words",
        executor: :somewhere,
        options: [%{"key" => "size", "type" => "matrix"}],
        results: [%{"key" => "score"}]
      }
    end

    def run(_step, _context), do: {:ok, %{}, []}
  end

  defmodule ReplacesBuiltIn do
    def contract do
      %{
        type: "manifest.build",
        name: "Mine",
        description: "Replaces the manifest.",
        stage: "publish"
      }
    end

    def run(_step, _context), do: {:ok, %{}, []}
  end

  @definition %{
    "steps" => [
      %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"},
      %{
        "id" => "count",
        "type" => "test.count_bytes",
        "name" => "Count Bytes",
        "depends_on" => ["source"],
        "required" => false,
        "params" => %{"limit" => 4}
      }
    ]
  }

  setup do
    old_plugins = Application.get_env(:mave_core, :flow_step_plugins)
    old_storage = Application.get_env(:mave_core, :flow_storage_adapter)
    Application.put_env(:mave_core, :flow_step_plugins, [StepPluginStub])

    Application.put_env(
      :mave_core,
      :flow_storage_adapter,
      MaveCore.TestSupport.FlowStorageAdapterStub
    )

    on_exit(fn ->
      Application.put_env(:mave_core, :flow_step_plugins, old_plugins)
      Application.delete_env(:mave_core, :step_plugin_stub_availability)

      if old_storage,
        do: Application.put_env(:mave_core, :flow_storage_adapter, old_storage),
        else: Application.delete_env(:mave_core, :flow_storage_adapter)
    end)

    :ok
  end

  describe "validate/1" do
    test "returns the contract with defaults" do
      assert {:ok, contract} = StepPlugin.validate(StepPluginStub)
      assert contract.type == "test.count_bytes"
      assert contract.category == "test"
      assert contract.executor == :inline
      assert contract.dependencies == :all
    end

    test "explains what is wrong with a plugin" do
      assert {:error, ["module is not available"]} = StepPlugin.validate(Missing.Plugin)
      assert {:error, ["contract/0 is not defined"]} = StepPlugin.validate(NoContract)

      assert {:error, reasons} = StepPlugin.validate(BadContract)
      assert "type must look like \"category.name\"" in reasons
      assert "name is required" in reasons
      assert "description is required" in reasons
      assert "stage must be lowercase letters and underscores" in reasons
      assert "executor must be one of :inline, :flame" in reasons
      assert "options has an invalid entry" in reasons
      assert "results has an invalid entry" in reasons
    end
  end

  describe "registered plugins" do
    test "are step types like the built-in ones" do
      assert StepRegistry.known_type?("test.count_bytes")
      assert StepRegistry.plugin?("test.count_bytes")
      refute StepRegistry.plugin?("manifest.build")
      assert StepRegistry.handler_for("test.count_bytes") == StepPluginStub
      assert StepRegistry.executor_for("test.count_bytes") == :inline
      assert "checks" == List.last(StepRegistry.stages())
      assert [%{"key" => "limit"}] = StepRegistry.editable_options("test.count_bytes")
      assert StepRegistry.progress_label("test.count_bytes") == "counting"
      assert StepRegistry.progress_label("manifest.build") == nil

      listed = Enum.find(Flow.list_step_types(), &(&1["type"] == "test.count_bytes"))

      assert %{
               "plugin" => true,
               "name" => "Count Bytes",
               "stage" => "checks",
               "inputs" => [%{"key" => "source"}],
               "outputs" => [%{"key" => "count"}],
               "progress" => %{"label" => "counting"},
               "results" => [%{"key" => "count.bytes"}, %{"key" => "within_limit"}]
             } = listed

      built_in = Enum.find(Flow.list_step_types(), &(&1["type"] == "manifest.build"))
      refute Map.has_key?(built_in, "plugin")
    end

    test "invalid plugins and plugins that replace a built-in type are ignored" do
      Application.put_env(:mave_core, :flow_step_plugins, [
        BadContract,
        ReplacesBuiltIn,
        StepPluginStub
      ])

      log =
        capture_log(fn ->
          assert StepRegistry.known_type?("test.count_bytes")
          assert StepRegistry.handler_for("manifest.build") != ReplacesBuiltIn
        end)

      assert log =~ "Ignoring step plugin"
      assert log =~ "step type manifest.build already exists"
    end

    test "format the results a step type asks to show" do
      output = %{"count" => %{"bytes" => 1536}, "within_limit" => false}

      assert [
               %{label: "Size", text: "1536 B", value: 1536, primary: true},
               %{label: "Within limit", text: "No", primary: false}
             ] = StepRegistry.results("test.count_bytes", output)

      assert StepRegistry.results("test.count_bytes", %{"status" => "skipped"}) == []
      assert StepRegistry.results("manifest.build", output) == []
    end

    test "offer steps that fit a definition" do
      assert [
               %{
                 "id" => "count_source",
                 "type" => "test.count_bytes",
                 "name" => "Count Bytes Source",
                 "depends_on" => ["source"],
                 "required" => false,
                 "lane" => "background"
               }
             ] = StepRegistry.offered_steps(@definition)

      assert StepRegistry.offered_steps(%{"steps" => []}) == []

      taken = update_in(@definition, ["steps"], &(&1 ++ [%{"id" => "count_source"}]))
      assert StepRegistry.offered_steps(taken) == []
    end

    test "report whether the installation can run them" do
      assert StepRegistry.availability("test.count_bytes") == :ok
      assert StepRegistry.availability("manifest.build") == :ok

      Application.put_env(
        :mave_core,
        :step_plugin_stub_availability,
        {:unavailable, "No counter."}
      )

      assert StepRegistry.availability("test.count_bytes") == {:unavailable, "No counter."}
    end

    test "run in a flow and expose their results" do
      {:ok, _template} = Flow.create_template(%{"slug" => "plugin_test", "name" => "Plugin Test"})
      assert {:ok, _version} = Flow.create_version("plugin_test", %{"definition" => @definition})

      {:ok, user} =
        Accounts.create_user("plugin-#{System.unique_integer([:positive])}@example.com")

      [space] = Accounts.list_user_spaces(user)

      assert {:ok, run} =
               Flow.run_inline("plugin_test", %{
                 "space_hash" => space.hash,
                 "embed_hash" => "LeDE9v86ye",
                 "input_url" => "https://example.com/video.mp4",
                 "source_body" => "12345678"
               })

      assert run.status == "succeeded"

      step_run = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "count")
      assert step_run.status == "succeeded"
      assert step_run.output["count"] == %{"bytes" => 8}
      assert step_run.output["within_limit"] == false

      assert %{"count" => %{status: "succeeded", results: [%{text: "8 B"}, %{text: "No"}]}} =
               Pipelines.step_activity(space)
    end

    test "a definition with an unregistered plugin type is rejected" do
      Application.put_env(:mave_core, :flow_step_plugins, [])
      {:ok, _template} = Flow.create_template(%{"slug" => "plugin_gone", "name" => "Plugin Gone"})

      assert {:error, _reason} =
               Flow.create_version("plugin_gone", %{"definition" => @definition})
    end
  end
end
