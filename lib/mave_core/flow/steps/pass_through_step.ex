defmodule MaveCore.Flow.Steps.PassThroughStep do
  @moduledoc """
  Default no-op step used while migrating legacy behavior incrementally.
  """
  @behaviour MaveCore.Flow.Step

  @impl true
  def run(step_definition, context) do
    output = %{
      "type" => step_definition["type"],
      "params" => Map.get(step_definition, "params", %{}),
      "input" => Map.get(context, :resolved_input, %{}),
      "status" => "ok"
    }

    {:ok, output, []}
  end
end
