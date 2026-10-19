defmodule MaveCoreWeb.Dashboard.Flow.RunTiming do
  @moduledoc false

  # A run can execute several steps at once. Attribute each interval once,
  # preferring execution over queueing, then dependency/orchestration waiting.
  def breakdown(%{started_at: %DateTime{} = start, run_duration_ms: duration, steps: steps})
      when is_integer(duration) and duration >= 0 do
    intervals =
      Enum.flat_map(steps, fn step ->
        [
          interval(
            step.started_at,
            step.completed_at,
            start,
            duration,
            :execution,
            Map.get(step, :step_id)
          ),
          interval(
            step.scheduled_at,
            step.started_at || step.completed_at,
            start,
            duration,
            :queue,
            Map.get(step, :step_id)
          )
        ]
        |> Enum.reject(&is_nil/1)
      end)

    boundaries =
      [0, duration | Enum.flat_map(intervals, fn {from, to, _kind, _step_id} -> [from, to] end)]
      |> Enum.uniq()
      |> Enum.sort()

    segments =
      boundaries
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [from, to] -> segment(intervals, from, to) end)
      |> merge_adjacent_segments()

    totals =
      Enum.reduce(segments, %{execution: 0, queue: 0, dependency: 0}, fn segment, totals ->
        Map.update!(totals, segment.kind, &(&1 + segment.to_ms - segment.from_ms))
      end)

    %{
      step_dependency_wait_ms: totals.dependency,
      step_queue_wait_ms: totals.queue,
      step_execution_ms: totals.execution,
      step_ready_total_ms: duration,
      segments: segments
    }
  end

  def breakdown(_run), do: nil

  defp interval(%DateTime{} = from, to, start, duration, kind, step_id) do
    from = from |> DateTime.diff(start, :millisecond) |> max(0) |> min(duration)
    to = if match?(%DateTime{}, to), do: DateTime.diff(to, start, :millisecond), else: duration
    to = to |> max(0) |> min(duration)
    if to > from, do: {from, to, kind, step_id}
  end

  defp interval(_from, _to, _start, _duration, _kind, _step_id), do: nil

  defp segment(intervals, from, to) do
    active =
      for {start, finish, kind, id} <- intervals, start <= from and from < finish, do: {kind, id}

    kind =
      cond do
        Enum.any?(active, fn {kind, _id} -> kind == :execution end) -> :execution
        Enum.any?(active, fn {kind, _id} -> kind == :queue end) -> :queue
        true -> :dependency
      end

    step_ids =
      for {active_kind, id} <- active, active_kind == kind and is_binary(id), do: id

    %{kind: kind, from_ms: from, to_ms: to, step_ids: Enum.sort(Enum.uniq(step_ids))}
  end

  defp merge_adjacent_segments(segments) do
    segments
    |> Enum.reduce([], fn
      segment, [previous | rest]
      when segment.kind == previous.kind and segment.step_ids == previous.step_ids ->
        [%{previous | to_ms: segment.to_ms} | rest]

      segment, result ->
        [segment | result]
    end)
    |> Enum.reverse()
  end
end
