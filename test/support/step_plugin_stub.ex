defmodule MaveCore.TestSupport.StepPluginStub do
  @moduledoc false
  @behaviour MaveCore.Flow.Step
  @behaviour MaveCore.Flow.StepPlugin

  @impl MaveCore.Flow.StepPlugin
  def contract do
    %{
      type: "test.count_bytes",
      name: "Count Bytes",
      description: "Counts the bytes of the source.",
      stage: "checks",
      inputs: [%{"key" => "source", "label" => "Source file", "accepts" => ["source.resolve"]}],
      outputs: [%{"key" => "count", "label" => "Byte count"}],
      options: [
        %{
          "key" => "limit",
          "type" => "integer",
          "label" => "Limit",
          "default" => 100,
          "min" => 1,
          "max" => 1000,
          "editable" => true
        }
      ],
      progress: %{"label" => "counting"},
      results: [
        %{
          "key" => "count.bytes",
          "label" => "Size",
          "format" => "integer",
          "unit" => "B",
          "primary" => true
        },
        %{"key" => "within_limit", "label" => "Within limit", "format" => "boolean"}
      ]
    }
  end

  @impl MaveCore.Flow.StepPlugin
  def placements(definition) do
    for %{"id" => "source"} <- Map.get(definition, "steps", []) do
      %{"id" => "count_source", "name" => "Count Bytes Source", "depends_on" => ["source"]}
    end
  end

  @impl MaveCore.Flow.StepPlugin
  def availability, do: Application.get_env(:mave_core, :step_plugin_stub_availability, :ok)

  @impl MaveCore.Flow.Step
  def run(step, context) do
    bytes = context |> Map.get(:run_input, %{}) |> Map.get("source_body", "") |> byte_size()
    limit = get_in(step, ["params", "limit"]) || 100

    {:ok, %{"status" => "ok", "count" => %{"bytes" => bytes}, "within_limit" => bytes <= limit},
     []}
  end
end
