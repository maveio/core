defmodule Mix.Tasks.Perf.LatencyStats do
  @moduledoc false

  def summarize(samples_ms, wall_ms, failures) when is_list(samples_ms) do
    samples_ms = Enum.sort(samples_ms)
    count = length(samples_ms)

    %{
      count: count,
      failures: failures,
      min_ms: pick(samples_ms, 0, 0),
      p50_ms: percentile(samples_ms, 50),
      p95_ms: percentile(samples_ms, 95),
      p99_ms: percentile(samples_ms, 99),
      max_ms: pick(samples_ms, count - 1, 0),
      mean_ms: mean(samples_ms),
      rps: rps(count, wall_ms)
    }
  end

  def format(%{count: count} = stats) do
    [
      "count=#{count}",
      "failures=#{stats.failures}",
      "rps=#{Float.round(stats.rps, 2)}",
      "min=#{stats.min_ms}ms",
      "p50=#{stats.p50_ms}ms",
      "p95=#{stats.p95_ms}ms",
      "p99=#{stats.p99_ms}ms",
      "max=#{stats.max_ms}ms",
      "mean=#{Float.round(stats.mean_ms, 2)}ms"
    ]
    |> Enum.join(" ")
  end

  defp mean([]), do: 0.0

  defp mean(values) do
    Enum.sum(values) / max(length(values), 1)
  end

  defp rps(_count, wall_ms) when wall_ms <= 0, do: 0.0
  defp rps(count, wall_ms), do: count / (wall_ms / 1000)

  defp percentile([], _p), do: 0

  defp percentile(sorted, p) when p in 0..100 do
    idx = round(p / 100 * (length(sorted) - 1))
    pick(sorted, idx, 0)
  end

  defp pick(list, idx, default) do
    case Enum.at(list, idx) do
      nil -> default
      v -> v
    end
  end
end
