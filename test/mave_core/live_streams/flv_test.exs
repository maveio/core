defmodule MaveCore.LiveStreams.FLVTest do
  use ExUnit.Case, async: true

  alias MaveCore.LiveStreams.FLV

  test "the header announces the tracks that follow" do
    assert FLV.header(audio: true, video: true) == <<"FLV", 1, 5, 9::32, 0::32>>
    assert FLV.header(audio: false, video: true) == <<"FLV", 1, 1, 9::32, 0::32>>
  end

  test "a tag frames its payload with type, size and timestamp" do
    assert IO.iodata_to_binary(FLV.tag(:video, 0x01020304, "abc")) ==
             <<9, 3::24, 0x020304::24, 0x01, 0::24, "abc", 14::32>>

    assert <<8, _::binary>> = IO.iodata_to_binary(FLV.tag(:audio, 0, "a"))
  end

  test "tells H.264 from codecs that cannot be repackaged" do
    assert FLV.video_codec(<<0x17, 0, 0, 0, 0>>) == :h264
    assert FLV.video_codec(<<0x12, 0>>) == {:legacy, 2}
    assert FLV.video_codec(<<1::1, 1::3, 0::4, "hvc1", 0>>) == {:enhanced, "hvc1"}
    assert FLV.video_codec(<<>>) == :unknown
  end

  test "recognises keyframes" do
    assert FLV.keyframe?(<<0x17, 1>>)
    refute FLV.keyframe?(<<0x27, 1>>)
  end
end
