defmodule MaveCore.TestSupport.PipelineAssistantStub do
  @moduledoc false
  @behaviour MaveCore.Flow.PipelineAssistant.Provider

  # A test sets `:pipeline_assistant_stub` to a function that answers a request.

  @impl true
  def available?, do: is_function(answer(), 1)

  @impl true
  def suggest(request, _opts), do: answer().(request)

  defp answer, do: Application.get_env(:mave_core, :pipeline_assistant_stub)
end
