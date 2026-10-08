defmodule MaveCore.Analytics.VideoTest do
  use ExUnit.Case, async: false

  alias MaveCore.Analytics.Video

  test "per-second durations retain ordinary rounding and reject unbounded observations" do
    assert Video.bounded_duration_seconds(10) == 10
    assert Video.bounded_duration_seconds(8.083333) == 9
    assert Video.bounded_duration_seconds(14_400) == 14_400

    for duration <- [nil, 0, -1, -0.1, 14_400.01, 1_000_000_000, "NaN", "Inf"] do
      assert Video.bounded_duration_seconds(duration) == 0
    end
  end

  setup do
    previous_hosts = Application.get_env(:mave_core, :analytics_internal_source_hosts)

    on_exit(fn ->
      if is_nil(previous_hosts),
        do: Application.delete_env(:mave_core, :analytics_internal_source_hosts),
        else: Application.put_env(:mave_core, :analytics_internal_source_hosts, previous_hosts)
    end)
  end

  test "does not hide hosted-service analytics sources by default" do
    Application.delete_env(:mave_core, :analytics_internal_source_hosts)

    refute Video.internal_source_host?("app.mave.io")
  end

  test "matches only configured dashboard hosts and their subdomains" do
    Application.put_env(:mave_core, :analytics_internal_source_hosts, ["app.mave.io"])

    assert Video.internal_source_host?("app.mave.io")
    assert Video.internal_source_host?("preview.app.mave.io")
    refute Video.internal_source_host?("customer-app.mave.io")
    refute Video.internal_source_host?("app.mave.io.example.com")
  end
end
