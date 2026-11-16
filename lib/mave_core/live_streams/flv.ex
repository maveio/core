defmodule MaveCore.LiveStreams.FLV do
  @moduledoc """
  Writes RTMP audio and video messages as an FLV byte stream.

  RTMP media messages carry FLV tag bodies, so repackaging only adds the file
  header and tag framing that FFmpeg's FLV demuxer expects.
  """

  @audio 8
  @video 9

  @doc "File header announcing which tracks follow."
  def header(opts) do
    flags = if(opts[:audio], do: 0x04, else: 0) + if(opts[:video], do: 0x01, else: 0)
    <<"FLV", 1, flags, 9::32, 0::32>>
  end

  @doc "One tag followed by its size, as the format requires."
  def tag(type, timestamp, payload) when type in [:audio, :video] and is_binary(payload) do
    size = byte_size(payload)
    <<extended, timestamp::24>> = <<rem(timestamp, 0x1_0000_0000)::32>>

    [
      <<tag_type(type), size::24, timestamp::24, extended, 0::24>>,
      payload,
      <<size + 11::32>>
    ]
  end

  defp tag_type(:audio), do: @audio
  defp tag_type(:video), do: @video

  @doc """
  The codec of a video tag body. Enhanced RTMP signals newer codecs with a
  FourCC instead of the legacy codec id.
  """
  def video_codec(<<1::1, _frame::3, _packet::4, fourcc::binary-size(4), _::binary>>),
    do: {:enhanced, fourcc}

  def video_codec(<<_frame::4, 7::4, _::binary>>), do: :h264
  def video_codec(<<_frame::4, codec::4, _::binary>>), do: {:legacy, codec}
  def video_codec(_payload), do: :unknown

  @doc "Whether a video tag body starts with a keyframe."
  def keyframe?(<<_::1, 1::3, _::4, _::binary>>), do: true
  def keyframe?(_payload), do: false
end
