defmodule MaveCore.EncodingBenchmark.CandidateTest do
  use ExUnit.Case, async: true

  alias MaveCore.EncodingBenchmark.Candidate

  defp args(candidate),
    do: candidate |> Candidate.ffmpeg_args("in.mp4", "out.mp4") |> Enum.join(" ")

  describe "production/1" do
    test "encodes the production renditions the way the booster does" do
      assert {:ok, [h264, hevc, av1]} = Candidate.production("fhd")

      assert h264.id == Candidate.baseline_id()

      for expected <- [
            "-c:v libx264 -preset faster",
            "-maxrate 8M -bufsize 16M",
            "-crf 20",
            "-force_key_frames expr:gte(t,n_forced*2)",
            "-g 250",
            "-pix_fmt yuv420p"
          ] do
        assert args(h264) =~ expected
      end

      for expected <- ["-c:v libx265", "-preset medium", "-tune grain", "-crf 24", "-tag:v hvc1"] do
        assert args(hevc) =~ expected
      end

      refute args(hevc) =~ "-force_key_frames"

      for expected <- [
            "-c:v libsvtav1",
            "-preset 6",
            "-crf 26",
            "-svtav1-params pin-threads=0",
            "-g 250"
          ] do
        assert args(av1) =~ expected
      end

      refute args(av1) =~ "-b:v"
      refute args(av1) =~ "-tune"
    end

    test "rejects an unknown rendition size" do
      assert {:error, {:unsupported_size, "tiny"}} = Candidate.production("tiny")
    end
  end

  test "defaults/1 adds exploration candidates that only vary the production ladder" do
    assert {:ok, candidates} = Candidate.defaults("hd")
    ids = Enum.map(candidates, & &1.id)

    assert ids == Enum.uniq(ids)
    assert "h264-crf22" in ids and "h264-slow" in ids

    slow = Enum.find(candidates, &(&1.id == "h264-slow-crf22"))
    assert args(slow) =~ "-preset slow"
    assert args(slow) =~ "-maxrate 4M -bufsize 8M -crf 22"
    assert slow.origin == :builtin
  end

  describe "from_entries/1" do
    test "expands a list of CRF values into one candidate each" do
      assert {:ok, [first, second]} =
               Candidate.from_entries([
                 %{"id" => "av1-fast", "codec" => "av1", "preset" => "fast", "crf" => [30, 34]}
               ])

      assert first.id == "av1-fast-crf30"
      assert second.id == "av1-fast-crf34"
      assert args(second) =~ "-c:v libsvtav1 -preset 8 -crf 34"
      assert second.keyframe_interval_seconds == 2
    end

    test "passes encoder-private parameters to the matching option" do
      assert {:ok, [candidate]} =
               Candidate.from_entries([
                 %{"id" => "x265-aq", "codec" => "hevc", "crf" => 26, "params" => "aq-mode=3"}
               ])

      assert args(candidate) =~ "-x265-params aq-mode=3"
    end

    test "rejects values that could not be passed to the encoder safely" do
      assert {:error, {:invalid_candidate, "preset", "-i /etc/passwd"}} =
               Candidate.from_entries([
                 %{"id" => "bad", "codec" => "h264", "crf" => 20, "preset" => "-i /etc/passwd"}
               ])

      assert {:error, {:invalid_candidate, "params", _value}} =
               Candidate.from_entries([
                 %{"id" => "bad", "codec" => "h264", "crf" => 20, "params" => "a b"}
               ])

      assert {:error, {:invalid_candidate, "id", "../escape"}} =
               Candidate.from_entries([%{"id" => "../escape", "codec" => "h264", "crf" => 20}])
    end

    test "requires an id, a known codec and a rate control setting" do
      assert {:error, {:missing_candidate_key, "id"}} =
               Candidate.from_entries([%{"codec" => "h264", "crf" => 20}])

      assert {:error, {:unsupported_codec, "vp9", "vp9"}} =
               Candidate.from_entries([%{"id" => "vp9", "codec" => "vp9", "crf" => 30}])

      assert {:error, {:missing_rate_control, "plain"}} =
               Candidate.from_entries([%{"id" => "plain", "codec" => "h264"}])

      assert {:error, {:maxrate_requires_bufsize, "capped"}} =
               Candidate.from_entries([
                 %{"id" => "capped", "codec" => "h264", "crf" => 20, "maxrate" => "4M"}
               ])
    end

    test "rejects duplicate ids and empty input" do
      entry = %{"id" => "same", "codec" => "h264", "crf" => 20}

      assert {:error, {:duplicate_candidate, "same"}} = Candidate.from_entries([entry, entry])
      assert {:error, :candidates_must_be_a_non_empty_list} = Candidate.from_entries([])
      assert {:error, :candidate_must_be_an_object} = Candidate.from_entries(["h264"])
    end
  end

  @tag :tmp_dir
  test "load_file/1 reads candidates from JSON", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "candidates.json")

    File.write!(
      path,
      ~s([{"id": "h264-veryslow", "codec": "h264", "preset": "veryslow", "crf": 21}])
    )

    assert {:ok, [%Candidate{id: "h264-veryslow", preset: "veryslow", origin: :custom}]} =
             Candidate.load_file(path)

    File.write!(path, "not json")
    assert {:error, {:invalid_json, _message}} = Candidate.load_file(path)

    assert {:error, {:unreadable_candidates_file, :enoent}} =
             Candidate.load_file(path <> ".missing")
  end
end
