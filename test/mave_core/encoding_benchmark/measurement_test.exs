defmodule MaveCore.EncodingBenchmark.MeasurementTest do
  use ExUnit.Case, async: true

  alias MaveCore.EncodingBenchmark.Measurement

  test "capabilities/3 finds the version, video encoders and libvmaf" do
    encoders = """
     V....D libx264              libx264 H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10 (codec h264)
     V..... libsvtav1            SVT-AV1(Scalable Video Technology for AV1) encoder (codec av1)
     A....D aac                  AAC (Advanced Audio Coding)
    """

    filters = """
     TS. psnr              VV->V      Calculate the PSNR between two video streams.
     ... libvmaf           VV->V      Calculate the VMAF between two video streams.
    """

    capabilities = Measurement.capabilities("ffmpeg version 7.1.1 Copyright", encoders, filters)

    assert capabilities.ffmpeg_version == "7.1.1"
    assert capabilities.encoders == MapSet.new(["libx264", "libsvtav1"])
    assert capabilities.vmaf?

    refute Measurement.capabilities("", encoders, " ... vmafmotion        V->V  Motion score.").vmaf?
  end

  test "quality_args/3 compares the encode with the reference in one pass" do
    assert ["-hide_banner", "-nostats", "-i", "out.mp4", "-i", "ref.mp4", "-lavfi", graph | _] =
             Measurement.quality_args("out.mp4", "ref.mp4")

    assert graph =~ "split=2[r1][r2]"
    assert graph =~ "[d0][r1]ssim[d1];[d1][r2]psnr"
    refute graph =~ "libvmaf"

    vmaf_graph =
      "out.mp4" |> Measurement.quality_args("ref.mp4", "/tmp/run/vmaf.json") |> Enum.at(7)

    assert vmaf_graph =~ "split=3[r1][r2][r3]"
    assert vmaf_graph =~ "[d2][r3]libvmaf=log_fmt=json:log_path=/tmp/run/vmaf.json"
  end

  test "parse_quality/1 reads SSIM and PSNR from the filter summaries" do
    output = """
    [Parsed_psnr_6 @ 0x56] PSNR y:31.359672 u:29.823684 v:26.864758 average:29.982241 min:24.570031 max:50.187392
    [Parsed_ssim_5 @ 0x56] SSIM Y:0.973399 (15.751048) U:0.971762 (15.491662) V:0.972176 (15.555843) All:0.972922 (15.673912)
    """

    assert {:ok, %{ssim: 0.972922, ssim_db: 15.673912, psnr: 29.982241}} =
             Measurement.parse_quality(output)

    assert {:error, :quality_metrics_not_found} = Measurement.parse_quality("Conversion failed!")
  end

  test "parse_quality/1 reports an encode identical to its reference without a finite score" do
    output = """
    [Parsed_psnr_6 @ 0x56] PSNR y:inf u:inf v:inf average:inf min:inf max:inf
    [Parsed_ssim_5 @ 0x56] SSIM Y:1.000000 (inf) U:1.000000 (inf) V:1.000000 (inf) All:1.000000 (inf)
    """

    assert {:ok, %{ssim: 1.0, ssim_db: nil, psnr: nil}} = Measurement.parse_quality(output)
  end

  test "parse_vmaf_log/1 reads the pooled VMAF scores" do
    log = ~s({"frames": [], "pooled_metrics": {"vmaf": {"min": 81.5, "max": 99, "mean": 93.25}}})

    assert {:ok, %{vmaf: 93.25, vmaf_min: 81.5}} = Measurement.parse_vmaf_log(log)
    assert {:error, :vmaf_scores_not_found} = Measurement.parse_vmaf_log(~s({"frames": []}))
    assert {:error, :vmaf_scores_not_found} = Measurement.parse_vmaf_log("")
  end

  test "parse_cpu_seconds/1 adds user and system time from -benchmark" do
    assert Measurement.parse_cpu_seconds("bench: utime=1.250s stime=0.101s rtime=0.626s") == 1.351
    assert Measurement.parse_cpu_seconds("no benchmark line") == nil
  end

  test "parse_probe/1 extracts the stream properties used for compatibility" do
    output = """
    {"streams": [{"codec_name": "hevc", "profile": "Main", "codec_tag_string": "hvc1",
      "width": 640, "height": 360, "pix_fmt": "yuv420p", "level": 63, "nb_frames": "60"}],
     "format": {"duration": "2.000000"}}
    """

    assert {:ok,
            %{
              codec: "hevc",
              profile: "Main",
              codec_tag: "hvc1",
              pixel_format: "yuv420p",
              width: 640,
              frames: 60,
              duration_seconds: 2.0
            }} = Measurement.parse_probe(output)

    assert {:error, :invalid_probe_output} = Measurement.parse_probe(~s({"streams": []}))
    assert {:error, :invalid_probe_output} = Measurement.parse_probe("moov atom not found")
  end

  test "max_keyframe_interval/2 measures the longest stretch without a keyframe" do
    packets = """
    0.000000,K__
    0.066667,___
    0.033333,___
    2.000000,K__
    5.000000,K__
    5.500000,___
    """

    assert Measurement.max_keyframe_interval(packets, 6.0) == 3.0
    assert Measurement.max_keyframe_interval("0.000000,K__\n0.033333,___\n", 6.0) == 6.0
    assert Measurement.max_keyframe_interval("", 6.0) == nil
  end
end
