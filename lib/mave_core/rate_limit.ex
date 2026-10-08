defmodule MaveCore.RateLimit do
  @moduledoc false

  # ETS-backed rate limiter (single-node).
  use Hammer, backend: :ets
end
