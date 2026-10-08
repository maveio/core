defmodule MaveCore.Media.ProductionEncodingProfileTest do
  use ExUnit.Case, async: true

  alias MaveCore.Media.ProductionEncodingProfile

  test "uses the long edge for portrait-safe H264 ladder requests" do
    assert {:ok, profile} = ProductionEncodingProfile.h264_ladder("fhd", true, 250)

    assert profile.name == "mave-production-v2"
    assert profile.request_options[:encoding_profile] == "mave-production-v2"
    assert profile.request_options[:width] == 1920
    assert profile.request_options[:video_bitrate] == "8M"
    assert profile.request_options[:preset] == "veryfast"
    assert profile.request_options[:include_audio] == true
    assert profile.request_options[:keyframe_interval_seconds] == 2
    assert profile.request_options[:gop_frames] == 250
  end

  test "caps a production profile at the inspected source long edge" do
    assert {:ok, profile} = ProductionEncodingProfile.h264_ladder("uhd", true, 250, 3396)

    assert profile.request_options[:width] == 3396
    assert profile.request_options[:video_bitrate] == "16M"
  end

  test "restores the production H264 keyframe clip profile" do
    assert {:ok, profile} = ProductionEncodingProfile.video_rendition("h264", "hd", 2)

    assert profile.request_options[:width] == 1280
    assert profile.request_options[:video_bitrate] == "4M"
    assert profile.request_options[:video_crf] == 23
    assert profile.request_options[:preset] == "medium"
    assert profile.request_options[:gop_frames] == 2
    assert profile.request_options[:max_duration_seconds] == 10
    assert profile.request_options[:include_audio] == false
    refute Keyword.has_key?(profile.request_options, :keyframe_interval_seconds)
    refute Keyword.has_key?(profile.request_options, :tune)
  end

  test "uses the quality-tuned production AV1 CRF profile" do
    assert {:ok, profile} = ProductionEncodingProfile.video_rendition("av1", "qhd", 250)

    assert profile.request_options[:width] == 2560
    assert profile.request_options[:video_crf] == 26
    assert profile.request_options[:preset] == "slow"
    assert profile.request_options[:gop_frames] == 250
    assert profile.request_options[:max_duration_seconds] == 60
    assert profile.request_options[:include_audio] == false
    assert profile.request_options[:svt_av1_params] =~ "hierarchical-levels=4"
    assert profile.request_options[:svt_av1_params] =~ "tune=0"
    refute Keyword.has_key?(profile.request_options, :video_bitrate)
    refute Keyword.has_key?(profile.request_options, :keyframe_interval_seconds)
  end

  test "uses constant-quality HEVC without adding a forced-keyframe cadence" do
    assert {:ok, profile} = ProductionEncodingProfile.video_rendition("hevc", "fhd", 250)

    assert profile.request_options[:video_crf] == 24
    assert profile.request_options[:preset] == "medium"
    assert profile.request_options[:tune] == "grain"
    assert profile.request_options[:max_duration_seconds] == 60
    refute Keyword.has_key?(profile.request_options, :video_bitrate)
    refute Keyword.has_key?(profile.request_options, :gop_frames)
    refute Keyword.has_key?(profile.request_options, :keyframe_interval_seconds)
  end
end
