defmodule MaveCore.GpuEncodingBoosterScaler do
  @moduledoc """
  Optional host adapter for prewarming GPU encoding capacity.

  Core deliberately performs no provisioning by default. A host application
  may configure `:gpu_encoding_booster_scaler_adapter` with a module that
  implements this behaviour.
  """

  @callback prewarm() :: :ok | {:error, term()}

  @spec prewarm() :: :ok
  def prewarm, do: :ok
end
