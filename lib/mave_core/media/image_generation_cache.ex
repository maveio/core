defmodule MaveCore.Media.ImageGenerationCache do
  @moduledoc false

  use Nebulex.Cache,
    otp_app: :mave_core,
    adapter: Nebulex.Adapters.Partitioned
end
