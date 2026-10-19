defmodule MaveCoreWeb.Dashboard.Flow.RunTimingTest do
  use ExUnit.Case, async: true

  alias MaveCoreWeb.Dashboard.Flow.RunTiming

  @start ~U[2026-01-01 00:00:00Z]

  test "partitions elapsed time and counts overlapping execution once" do
    timing =
      RunTiming.breakdown(run(80, [step(10, 20, 60), step(15, 30, 80)]))

    assert timing.step_dependency_wait_ms == 10_000
    assert timing.step_queue_wait_ms == 10_000
    assert timing.step_execution_ms == 60_000
    assert timing.step_ready_total_ms == 80_000
  end

  test "keeps dependency gaps between sequential steps" do
    timing = RunTiming.breakdown(run(60, [step(10, 20, 40), step(50, 55, 60)]))

    assert timing.step_dependency_wait_ms == 20_000
    assert timing.step_queue_wait_ms == 15_000
    assert timing.step_execution_ms == 25_000
  end

  test "uses elapsed run time for an executing or queued step" do
    executing = RunTiming.breakdown(run(50, [step(10, 20, nil)]))
    assert executing.step_execution_ms == 30_000
    assert executing.step_queue_wait_ms == 10_000

    queued = RunTiming.breakdown(run(50, [step(10, nil, nil)]))
    assert queued.step_execution_ms == 0
    assert queued.step_queue_wait_ms == 40_000
    assert queued.step_dependency_wait_ms == 10_000
  end

  test "clips step intervals to the run and handles zero or missing timing" do
    clipped = RunTiming.breakdown(run(60, [step(-20, -10, 100)]))
    assert clipped.step_execution_ms == 60_000
    assert clipped.step_queue_wait_ms == 0
    assert clipped.step_dependency_wait_ms == 0

    zero = RunTiming.breakdown(run(0, [step(0, 0, 0)]))
    assert zero.step_ready_total_ms == 0
    assert zero.step_execution_ms == 0

    empty = RunTiming.breakdown(run(60, []))
    assert empty.step_dependency_wait_ms == 60_000
    assert RunTiming.breakdown(%{started_at: nil}) == nil
  end

  defp run(seconds, steps),
    do: %{started_at: @start, run_duration_ms: seconds * 1000, steps: steps}

  defp step(scheduled, started, completed) do
    %{
      scheduled_at: timestamp(scheduled),
      started_at: timestamp(started),
      completed_at: timestamp(completed)
    }
  end

  defp timestamp(nil), do: nil
  defp timestamp(seconds), do: DateTime.add(@start, seconds, :second)
end
