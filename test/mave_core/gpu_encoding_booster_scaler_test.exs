defmodule MaveCore.GpuEncodingBoosterScalerTest do
  use ExUnit.Case, async: true

  test "Core provisioning adapter is a no-op by default" do
    assert :ok = MaveCore.GpuEncodingBoosterScaler.prewarm()
  end
end
