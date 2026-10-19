defmodule MaveCoreWeb.Dashboard.Flow.RunTiming do
  @moduledoc false

  # A run can execute several steps at once. Attribute each interval once,
  # preferring execution over queueing, then dependency/orchestration waiting.
  def breakdown(%{started_at: %DateTime{} = start, run_duration_ms: duration, steps: steps})
      when is_integer(duration) and duration >= 0 do
    intervals =
      Enum.flat_map(steps, fn step ->
        [
          interval(step.started_at, step.completed_at, start, duration, :execution),
          interval(
            step.scheduled_at,
            step.started_at || step.completed_at,
            start,
            duration,
            :queue
          )
        ]
        |> Enum.reject(&is_nil/1)
      end)

    boundaries =
      [0, duration | Enum.flat_map(intervals, fn {from, to, _kind} -> [from, to] end)]
      |> Enum.uniq()
      |> Enum.sort()

    totals =
      boundaries
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.reduce(%{execution: 0, queue: 0, dependency: 0}, fn [from, to], totals ->
        kind = interval_kind(intervals, from)
        Map.update!(totals, kind, &(&1 + to - from))
      end)

    %{
      step_dependency_wait_ms: totals.dependency,
      step_queue_wait_ms: totals.queue,
      step_execution_ms: totals.execution,
      step_ready_total_ms: duration
    }
  end

  def breakdown(_run), do: nil

  defp interval(%DateTime{} = from, to, start, duration, kind) do
    from = from |> DateTime.diff(start, :millisecond) |> max(0) |> min(duration)
    to = if match?(%DateTime{}, to), do: DateTime.diff(to, start, :millisecond), else: duration
    to = to |> max(0) |> min(duration)
    if to > from, do: {from, to, kind}
  end

  defp interval(_from, _to, _start, _duration, _kind), do: nil

  defp interval_kind(intervals, at) do
    active = for {from, to, kind} <- intervals, from <= at and at < to, do: kind

    cond do
      :execution in active -> :execution
      :queue in active -> :queue
      true -> :dependency
    end
  end
end
