defmodule MaveCore.TestSupport.EncodingBenchmarkFixtures do
  @moduledoc false

  @doc """
  Stored benchmark results for two clips and three candidates.

  `smaller` saves a quarter on both clips but loses too much quality on
  `detail`; `av1` is smaller and better but cannot replace the baseline.
  """
  def results(overrides \\ %{}) do
    Map.merge(
      %{
        "schema" => 1,
        "tag" => "fixture",
        "started_at" => "2026-01-01T00:00:00Z",
        "environment" => %{
          "ffmpeg_version" => "7.1",
          "vmaf" => false,
          "logical_cpus" => 4,
          "os" => "unix/linux",
          "architecture" => "x86_64",
          "production_profile" => "mave-production-v3"
        },
        "settings" => %{
          "size" => "hd",
          "duration_seconds" => 6,
          "baseline" => "production-h264",
          "quality_metric" => "ssim_db"
        },
        "clips" => [
          %{"id" => "flat", "description" => "Flat <content>", "kind" => "synthetic"},
          %{"id" => "detail", "description" => "Detailed content", "kind" => "synthetic"}
        ],
        "candidates" => [
          candidate("production-h264", "h264"),
          candidate("smaller", "h264"),
          candidate("av1", "av1")
        ],
        "results" => [
          result("flat", "production-h264", 1_000_000, 20.0, 2.0, "universal"),
          result("flat", "smaller", 750_000, 19.6, 2.0, "universal"),
          result("flat", "av1", 500_000, 22.0, 10.0, "needs_fallback"),
          result("detail", "production-h264", 3_000_000, 18.0, 4.0, "universal"),
          result("detail", "smaller", 2_250_000, 16.5, 5.0, "universal"),
          result("detail", "av1", 1_500_000, 19.0, 20.0, "needs_fallback")
        ],
        "warnings" => []
      },
      overrides
    )
  end

  def result(clip, candidate, bytes, ssim_db, encode_seconds, compatibility) do
    %{
      "clip" => clip,
      "candidate" => candidate,
      "status" => "ok",
      "bytes" => bytes,
      "bitrate_kbps" => bytes * 8 / 6 / 1000,
      "ssim" => 0.98,
      "ssim_db" => ssim_db,
      "psnr" => 40.0,
      "encode_seconds" => encode_seconds,
      "cpu_seconds" => encode_seconds * 3,
      "speed" => 6 / encode_seconds,
      "profile" => "High",
      "level" => 31,
      "pixel_format" => "yuv420p",
      "max_keyframe_interval" => 2.0,
      "compatibility" => compatibility,
      "compatibility_note" => "note"
    }
  end

  def failure(clip, candidate) do
    %{"clip" => clip, "candidate" => candidate, "status" => "error", "error" => "exit 1: <boom>"}
  end

  defp candidate(id, codec) do
    %{
      "id" => id,
      "codec" => codec,
      "settings" => "settings of #{id}",
      "description" => "Description of #{id}",
      "origin" => "builtin",
      "ffmpeg_args" => ["-i", "INPUT", "OUTPUT"]
    }
  end
end
