defmodule MaveCore.EncodingBenchmark.SummaryTest do
  use ExUnit.Case, async: true

  import MaveCore.TestSupport.EncodingBenchmarkFixtures

  alias MaveCore.EncodingBenchmark.Summary

  defp row(rows, id), do: Enum.find(rows, &(&1.id == id))

  describe "candidates/2" do
    test "compares size, quality and time with the baseline" do
      rows = Summary.candidates(results())

      baseline = row(rows, "production-h264")
      assert baseline.baseline?
      assert baseline.bytes == 4_000_000
      assert baseline.size_change == 0.0
      assert baseline.regressions == 0

      av1 = row(rows, "av1")
      assert av1.size_change == -50.0
      assert_in_delta av1.quality_delta, 1.5, 1.0e-9
      assert av1.time_ratio == 5.0
      assert av1.compatibility == "needs_fallback"
      assert av1.regressions == 0
    end

    test "reports the worst clip instead of hiding it behind the average" do
      smaller = results() |> Summary.candidates() |> row("smaller")

      assert smaller.size_change == -25.0
      assert_in_delta smaller.quality_delta, -0.95, 1.0e-9
      assert_in_delta smaller.worst_delta, -1.5, 1.0e-9
      assert smaller.worst_clip == "detail"
      assert smaller.regressions == 1
    end

    test "applies a custom tolerance" do
      assert results() |> Summary.candidates(0.2) |> row("smaller") |> Map.fetch!(:regressions) ==
               2

      assert results() |> Summary.candidates(2.0) |> row("smaller") |> Map.fetch!(:regressions) ==
               0
    end

    test "only compares clips that both the candidate and the baseline completed" do
      results =
        results()
        |> Map.update!("results", fn rows ->
          Enum.map(rows, fn
            %{"clip" => "detail", "candidate" => "smaller"} -> failure("detail", "smaller")
            row -> row
          end)
        end)

      smaller = results |> Summary.candidates() |> row("smaller")

      assert smaller.clips == 1
      assert smaller.failed == 1
      assert smaller.size_change == -25.0
      assert smaller.worst_clip == "flat"
    end

    test "compares on VMAF when the run measured it" do
      results =
        results()
        |> put_in(["settings", "quality_metric"], "vmaf")
        |> Map.update!("results", fn rows ->
          Enum.map(
            rows,
            &Map.put(&1, "vmaf", if(&1["candidate"] == "smaller", do: 90.0, else: 95.0))
          )
        end)

      assert %{label: "VMAF", tolerance: 2.0} = Summary.metric(results)

      assert results |> Summary.candidates() |> row("smaller") |> Map.fetch!(:quality_delta) ==
               -5.0
    end
  end

  describe "per_clip_picks/2" do
    test "picks the smallest encode that keeps the baseline's quality and reach" do
      picks = Summary.per_clip_picks(results())

      assert [
               %{clip: "flat", candidate: "smaller", size_change: -25.0},
               %{clip: "detail", candidate: "production-h264", size_change: unchanged}
             ] = picks.picks

      assert unchanged == 0.0

      assert picks.bytes == 3_750_000
      assert picks.size_change == -6.25
      assert picks.best_single == nil
    end

    test "names the smallest other candidate that qualifies on every clip" do
      picks = Summary.per_clip_picks(results(), 2.0)

      assert Enum.map(picks.picks, & &1.candidate) == ["smaller", "smaller"]
      assert %{candidate: "smaller", size_change: -25.0} = picks.best_single
    end

    test "skips clips without a baseline encode" do
      results =
        Map.update!(results(), "results", fn rows ->
          Enum.reject(rows, &(&1["clip"] == "flat" and &1["candidate"] == "production-h264"))
        end)

      assert [%{clip: "detail"}] = Summary.per_clip_picks(results).picks
    end
  end

  describe "compare/2" do
    test "reports the change of every measurement both runs completed" do
      previous =
        Map.update!(results(), "results", fn rows ->
          rows
          |> Enum.reject(&(&1["candidate"] == "av1"))
          |> Enum.map(fn row ->
            %{
              row
              | "bytes" => row["bytes"] * 2,
                "ssim_db" => row["ssim_db"] - 1,
                "encode_seconds" => 4.0
            }
          end)
        end)

      changes = Summary.compare(results(), previous)

      assert length(changes) == 4

      assert %{size_change: -50.0, time_change: -50.0, quality_delta: delta} =
               Enum.find(changes, &(&1.clip == "flat" and &1.candidate == "smaller"))

      assert_in_delta delta, 1.0, 1.0e-9
    end

    test "lists what changed between the two environments" do
      previous = put_in(results(), ["environment", "ffmpeg_version"], "6.1")

      assert Summary.environment_changes(results(), previous) == ["ffmpeg_version: 6.1 → 7.1"]
      assert Summary.environment_changes(results(), results()) == []
    end
  end
end
