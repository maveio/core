defmodule MaveCore.Flow.PipelineAssistant.Provider do
  @moduledoc """
  A language model for `MaveCore.Flow.PipelineAssistant`.

  `c:suggest/2` receives the request:

  - `:message`: what the person asked for.
  - `:steps`: the steps of the pipeline with their state and editable settings
    (`MaveCore.Flow.PipelineAssistant.catalog/1`).
  - `:history`: earlier turns as `%{role: :user | :assistant, text: text}`.

  It returns a short `:reply` for the person and the `:operations` to propose.
  An operation is a map with a `"step_id"` and an `"action"`: `"turn_off"`,
  `"turn_on"`, or `"set_setting"` with a `"setting"` key and a `"value"`. The
  assistant checks every operation, so a provider does not validate them.
  """

  @type request :: %{message: String.t(), steps: [map()], history: [map()]}
  @type suggestion :: %{reply: String.t(), operations: [map()]}

  @doc "Whether the provider is set up, for example whether its API key is present."
  @callback available?() :: boolean()

  @callback suggest(request(), opts :: keyword()) :: {:ok, suggestion()} | {:error, term()}
end
