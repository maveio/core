defmodule MaveCore.EncodingBenchmark.Summary do
  @moduledoc """
  Derives comparisons from stored `MaveCore.EncodingBenchmark` results.

  Every comparison is made per clip against the baseline candidate and then
  aggregated, and the worst clip is reported next to the average: an average
  that improves can hide a clip that got visibly worse.
  """

  @metrics %{
    "vmaf" => %{key: "vmaf", label: "VMAF", unit: "", tolerance: 2.0},
    "ssim_db" => %{key: "ssim_db", label: "SSIM", unit: "dB", tolerance: 1.0}
  }
  # Stands in for an encode that is identical to its reference.
  @lossless_quality 100.0
  @tier_order %{"universal" => 0, "needs_fallback" => 1, "not_web_safe" => 2}

  @type metric :: %{key: String.t(), label: String.t(), unit: String.t(), tolerance: float()}

  @doc "Returns the quality metric the run compares on, with its default tolerance."
  @spec metric(map()) :: metric()
  def metric(%{"settings" => %{"quality_metric" => name}}), do: Map.fetch!(@metrics, name)

  @doc "Returns the quality score of a result on `metric`."
  @spec quality(map(), metric()) :: float()
  def quality(result, %{key: key}), do: (result[key] || @lossless_quality) / 1

  @doc """
  Summarizes every candidate against the baseline.

  Size, quality and time changes only cover clips where both the candidate and
  the baseline succeeded. `tolerance` is the quality drop, in units of the run's
  metric, below which a clip counts as regressed.
  """
  @spec candidates(map(), float() | nil) :: [map()]
  def candidates(results, tolerance \\ nil) do
    metric = metric(results)
    tolerance = tolerance || metric.tolerance
    baseline_id = results["settings"]["baseline"]
    by_candidate = Enum.group_by(results["results"], & &1["candidate"])
    baseline = ok_by_clip(Map.get(by_candidate, baseline_id, []))

    Enum.map(results["candidates"], fn candidate ->
      rows = Map.get(by_candidate, candidate["id"], [])
      ok = ok_by_clip(rows)
      shared = ok |> Map.keys() |> Enum.filter(&is_map_key(baseline, &1)) |> Enum.sort()
      deltas = Enum.map(shared, &{&1, quality(ok[&1], metric) - quality(baseline[&1], metric)})
      {worst_clip, worst_delta} = Enum.min_by(deltas, &elem(&1, 1), fn -> {nil, nil} end)

      %{
        id: candidate["id"],
        codec: candidate["codec"],
        settings: candidate["settings"],
        baseline?: candidate["id"] == baseline_id,
        clips: map_size(ok),
        failed: length(rows) - map_size(ok),
        bytes: sum(Map.values(ok), "bytes"),
        size_change: change(sum_for(ok, shared, "bytes"), sum_for(baseline, shared, "bytes")),
        quality: mean(Enum.map(Map.values(ok), &quality(&1, metric))),
        quality_delta: mean(Enum.map(deltas, &elem(&1, 1))),
        worst_delta: worst_delta,
        worst_clip: worst_clip,
        regressions: Enum.count(deltas, fn {_clip, delta} -> delta < -tolerance end),
        encode_seconds: sum(Map.values(ok), "encode_seconds"),
        time_ratio:
          ratio(
            sum_for(ok, shared, "encode_seconds"),
            sum_for(baseline, shared, "encode_seconds")
          ),
        compatibility: worst_tier(Map.values(ok)),
        max_keyframe_interval:
          ok |> Map.values() |> Enum.map(& &1["max_keyframe_interval"]) |> max_number()
      }
    end)
  end

  @doc """
  Picks, for every clip, the smallest encode that keeps the baseline's reach.

  A candidate qualifies when it has the baseline's compatibility tier on that
  clip and its quality is within `tolerance` of the baseline. The totals show
  what choosing settings per video would save over the baseline, next to the
  smallest other candidate that qualifies on every clip.
  """
  @spec per_clip_picks(map(), float() | nil) :: map()
  def per_clip_picks(results, tolerance \\ nil) do
    metric = metric(results)
    tolerance = tolerance || metric.tolerance
    baseline_id = results["settings"]["baseline"]
    ok = Enum.filter(results["results"], &(&1["status"] == "ok"))
    baseline = ok |> Enum.filter(&(&1["candidate"] == baseline_id)) |> ok_by_clip()

    picks =
      results["clips"]
      |> Enum.map(& &1["id"])
      |> Enum.filter(&is_map_key(baseline, &1))
      |> Enum.map(fn clip ->
        reference = baseline[clip]

        pick =
          ok
          |> Enum.filter(&(&1["clip"] == clip and qualifies?(&1, reference, metric, tolerance)))
          |> Enum.min_by(& &1["bytes"])

        %{
          clip: clip,
          candidate: pick["candidate"],
          bytes: pick["bytes"],
          baseline_bytes: reference["bytes"],
          size_change: change(pick["bytes"], reference["bytes"]),
          quality_delta: quality(pick, metric) - quality(reference, metric)
        }
      end)

    baseline_bytes = picks |> Enum.map(& &1.baseline_bytes) |> Enum.sum()
    picked_bytes = picks |> Enum.map(& &1.bytes) |> Enum.sum()

    %{
      picks: picks,
      baseline_bytes: baseline_bytes,
      bytes: picked_bytes,
      size_change: change(picked_bytes, baseline_bytes),
      best_single: best_single(results, baseline_id, baseline, metric, tolerance)
    }
  end

  # The baseline always qualifies against itself, so it is not a finding.
  defp best_single(results, baseline_id, baseline, metric, tolerance) do
    clips = Map.keys(baseline)

    results["results"]
    |> Enum.filter(&(&1["status"] == "ok" and &1["candidate"] != baseline_id))
    |> Enum.group_by(& &1["candidate"])
    |> Enum.filter(fn {_id, rows} ->
      by_clip = ok_by_clip(rows)

      Enum.all?(clips, fn clip ->
        is_map_key(by_clip, clip) and qualifies?(by_clip[clip], baseline[clip], metric, tolerance)
      end)
    end)
    |> Enum.map(fn {id, rows} -> %{candidate: id, bytes: sum(rows, "bytes")} end)
    |> Enum.min_by(& &1.bytes, fn -> nil end)
    |> case do
      nil -> nil
      best -> Map.put(best, :size_change, change(best.bytes, sum(Map.values(baseline), "bytes")))
    end
  end

  defp qualifies?(result, reference, metric, tolerance) do
    result["compatibility"] == reference["compatibility"] and
      quality(result, metric) >= quality(reference, metric) - tolerance
  end

  @doc """
  Compares two runs measurement by measurement.

  Only clip and candidate pairs that succeeded in both runs are returned. Size
  and quality are comparable across machines; encoding time is only meaningful
  when both runs used the same hardware, see `environment_changes/2`.
  """
  @spec compare(map(), map()) :: [map()]
  def compare(current, previous) do
    metric = metric(current)
    earlier = previous["results"] |> Enum.filter(&(&1["status"] == "ok")) |> index()

    current["results"]
    |> Enum.filter(&(&1["status"] == "ok"))
    |> Enum.flat_map(fn result ->
      case Map.get(earlier, {result["clip"], result["candidate"]}) do
        nil ->
          []

        before ->
          [
            %{
              clip: result["clip"],
              candidate: result["candidate"],
              size_change: change(result["bytes"], before["bytes"]),
              quality_delta: quality(result, metric) - quality(before, metric),
              time_change: change(result["encode_seconds"], before["encode_seconds"])
            }
          ]
      end
    end)
  end

  @doc "Lists the environment and setting differences between two runs."
  @spec environment_changes(map(), map()) :: [String.t()]
  def environment_changes(current, previous) do
    environment =
      for key <- ~w(ffmpeg_version logical_cpus architecture production_profile vmaf),
          current["environment"][key] != previous["environment"][key] do
        "#{key}: #{previous["environment"][key]} → #{current["environment"][key]}"
      end

    settings =
      for key <- ~w(size duration_seconds quality_metric),
          current["settings"][key] != previous["settings"][key] do
        "#{key}: #{previous["settings"][key]} → #{current["settings"][key]}"
      end

    environment ++ settings
  end

  defp ok_by_clip(rows) do
    rows |> Enum.filter(&(&1["status"] == "ok")) |> Map.new(&{&1["clip"], &1})
  end

  defp index(rows), do: Map.new(rows, &{{&1["clip"], &1["candidate"]}, &1})

  defp sum(rows, key), do: rows |> Enum.map(&(&1[key] || 0)) |> Enum.sum()
  defp sum_for(by_clip, clips, key), do: sum(Enum.map(clips, &by_clip[&1]), key)

  defp mean([]), do: nil
  defp mean(values), do: Enum.sum(values) / length(values)

  defp change(_value, base) when base in [0, 0.0, nil], do: nil
  defp change(value, base), do: (value - base) / base * 100

  defp ratio(_value, base) when base in [0, 0.0, nil], do: nil
  defp ratio(value, base), do: value / base

  defp max_number(values) do
    case Enum.filter(values, &is_number/1) do
      [] -> nil
      numbers -> Enum.max(numbers)
    end
  end

  defp worst_tier([]), do: nil

  defp worst_tier(rows) do
    rows |> Enum.map(& &1["compatibility"]) |> Enum.max_by(&Map.get(@tier_order, &1, 2))
  end
end
