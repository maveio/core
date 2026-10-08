defmodule MaveCore.Flow.Step do
  @moduledoc """
  Contract for flow step implementations.
  """

  @type step_definition :: map()
  @type execution_context :: map()
  @type artifact :: %{
          required(:name) => String.t(),
          required(:uri) => String.t(),
          optional(:media_type) => String.t() | nil,
          optional(:size_bytes) => integer() | nil,
          optional(:metadata) => map()
        }

  @callback run(step_definition(), execution_context()) ::
              {:ok, map(), [artifact()]} | {:error, term()}
end
