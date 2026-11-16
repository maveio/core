defmodule MaveCore.EncodingBenchmark.ReportTest do
  use ExUnit.Case, async: true

  import MaveCore.TestSupport.EncodingBenchmarkFixtures

  alias MaveCore.EncodingBenchmark.Report

  describe "text/2" do
    test "summarizes candidates and the per-video selection" do
      text = Report.text(results())

      assert text =~ "Encoding benchmark fixture: 2 clips × 3 candidates at hd"
      assert text =~ "VMAF not measured"
      assert text =~ ~r/production-h264 \*\s+H\.264\s+4\.00 MB/
      assert text =~ ~r/smaller\s+H\.264\s+3\.00 MB\s+−25\.0%/
      assert text =~ "−1.50 detail !"
      assert text =~ ~r/av1\s+AV1\s+2\.00 MB\s+−50\.0%.*needs fallback/

      assert text =~
               "Total 3.75 MB (−6.3% vs baseline); no other candidate qualifies on every clip"
    end

    test "lists warnings from the run" do
      text = Report.text(results(%{"warnings" => ["Skipped av1: no libsvtav1 encoder"]}))

      assert text =~ "Warning: Skipped av1: no libsvtav1 encoder"
    end
  end

  test "comparison_text/2 shows the change against an earlier run" do
    previous =
      results(%{"tag" => "earlier"})
      |> put_in(["environment", "ffmpeg_version"], "6.1")
      |> Map.update!("results", fn rows -> Enum.map(rows, &%{&1 | "bytes" => &1["bytes"] * 2}) end)

    text = Report.comparison_text(results(), previous)

    assert text =~ "Compared with earlier"
    assert text =~ "ffmpeg_version: 6.1 → 7.1"
    assert text =~ ~r/flat\s+smaller\s+−50\.0%\s+0\.00\s+0\.0%/
  end

  describe "html/2" do
    test "renders a self-contained report with a chart per clip" do
      html = Report.html(results())

      assert html =~ "<title>Encoding benchmark fixture</title>"
      assert html =~ "Candidates against the baseline"
      assert html =~ "⚠ 1 clip regresses"
      assert html =~ "✓ within tolerance"
      assert length(String.split(html, "<svg ")) == 3
      assert html =~ ~s(aria-label="SSIM dB against bitrate for detail")
      refute html =~ ~r/(src|href)=/
      refute html =~ "<script"
    end

    test "escapes text that comes from file names and FFmpeg output" do
      results =
        Map.update!(results(), "results", fn rows -> rows ++ [failure("flat", "smaller")] end)

      html = Report.html(results)

      assert html =~ "Flat &lt;content&gt;"
      assert html =~ "exit 1: &lt;boom&gt;"
      refute html =~ "<content>"
      refute html =~ "<boom>"
    end

    test "adds the comparison with an earlier run when given one" do
      refute Report.html(results()) =~ "Changes since"

      html = Report.html(results(), previous: results(%{"tag" => "earlier"}))

      assert html =~ "Changes since earlier"
      assert html =~ "Same FFmpeg version, CPU count and settings."
    end

    test "renders VMAF columns when the run measured VMAF" do
      results =
        results()
        |> put_in(["settings", "quality_metric"], "vmaf")
        |> put_in(["environment", "vmaf"], true)
        |> Map.update!("results", fn rows -> Enum.map(rows, &Map.put(&1, "vmaf", 93.5)) end)

      html = Report.html(results)

      assert html =~ ~s(<th scope="col" class="num">VMAF</th>)
      assert html =~ ~s(aria-label="VMAF against bitrate for flat")
      refute html =~ "VMAF not measured"
    end
  end
end
