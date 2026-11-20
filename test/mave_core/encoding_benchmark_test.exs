defmodule MaveCore.EncodingBenchmarkTest do
  use ExUnit.Case, async: true

  alias MaveCore.EncodingBenchmark
  alias MaveCore.EncodingBenchmark.{Candidate, Corpus, Report, Summary}
  alias MaveCore.Flow.Steps.Support, as: StepSupport

  @moduletag :integration
  @moduletag :tmp_dir

  setup do
    {:ok, [clip | _]} = Corpus.synthetic("sd")

    {:ok, candidates} =
      Candidate.from_entries([
        %{"id" => "fine", "codec" => "h264", "preset" => "ultrafast", "crf" => 18},
        %{"id" => "coarse", "codec" => "h264", "preset" => "ultrafast", "crf" => 40}
      ])

    %{clip: clip, candidates: candidates}
  end

  test "measures size, quality, time and playback reach of every candidate", context do
    parent = self()

    assert {:ok, results} =
             EncodingBenchmark.run(
               clips: [context.clip],
               candidates: context.candidates,
               work_dir: context.tmp_dir,
               size: "sd",
               duration: 1,
               tag: "integration",
               on_progress: &send(parent, &1)
             )

    assert results["settings"]["baseline"] == "fine"

    assert [%{"id" => "motion-graphics", "width" => 640, "height" => 360, "frames" => 30}] =
             results["clips"]

    assert [fine, coarse] = results["results"]

    for result <- [fine, coarse] do
      assert result["status"] == "ok"
      assert result["compatibility"] == "universal"
      assert result["pixel_format"] == "yuv420p"
      assert result["max_keyframe_interval"] == 1.0
      assert result["encode_seconds"] > 0
      assert result["cpu_seconds"] > 0
    end

    assert fine["bytes"] > coarse["bytes"]
    assert fine["ssim_db"] > coarse["ssim_db"]
    assert fine["psnr"] > coarse["psnr"]

    assert_received {:reference, "motion-graphics"}
    assert_received {:result, %{"candidate" => "fine"}, 1, 2}
    assert_received {:result, %{"candidate" => "coarse"}, 2, 2}

    refute File.exists?(Path.join(context.tmp_dir, "media"))

    # Stored results survive a JSON round trip and can be summarized again.
    stored = results |> Jason.encode!() |> Jason.decode!()

    assert [%{id: "fine", baseline?: true}, %{id: "coarse", regressions: 1}] =
             Summary.candidates(stored)

    assert Report.html(stored) =~ "motion-graphics"
  end

  test "keeps the media when asked and records failed encodes", context do
    broken = %{hd(context.candidates) | id: "broken", tune: "no-such-tune"}

    assert {:ok, results} =
             EncodingBenchmark.run(
               clips: [context.clip],
               candidates: [broken | context.candidates],
               work_dir: context.tmp_dir,
               size: "sd",
               duration: 1,
               baseline: "fine",
               keep_media: true
             )

    assert [
             %{"status" => "error", "error" => "exit " <> _},
             %{"status" => "ok"},
             %{"status" => "ok"}
           ] =
             results["results"]

    assert File.exists?(Path.join([context.tmp_dir, "media", "motion-graphics", "fine.mp4"]))
  end

  test "generates identical synthetic references on every run", context do
    {:ok, clips} = Corpus.synthetic("sd")
    {:ok, ffmpeg} = StepSupport.find_ffmpeg()

    for clip <- clips do
      [first, second] =
        for name <- ["first.mp4", "second.mp4"] do
          path = Path.join(context.tmp_dir, "#{clip.id}-#{name}")
          {:ok, args} = Corpus.reference_args(clip, "sd", 1, path)
          assert {_output, 0} = StepSupport.run_media_cmd(ffmpeg, args)
          :crypto.hash(:sha256, File.read!(path))
        end

      assert first == second, "#{clip.id} differs between runs"
    end
  end

  test "rejects an unknown baseline", context do
    assert {:error, {:unknown_baseline, "missing"}} =
             EncodingBenchmark.run(
               clips: [context.clip],
               candidates: context.candidates,
               work_dir: context.tmp_dir,
               baseline: "missing"
             )
  end
end
