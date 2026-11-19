defmodule MaveCore.LiveStreams.Playlist do
  @moduledoc """
  Renders the HLS media playlist of a broadcast from its stored segments.

  `:url` turns a segment into the address players fetch it from. Object keys
  carry the broadcast number, so an address never refers to different media
  after the stream goes live again.
  """

  alias MaveCore.LiveStreams.{LiveStream, Segment}

  @spec render(LiveStream.t(), [Segment.t(), ...], keyword()) :: String.t()
  def render(%LiveStream{} = stream, [%Segment{} = first | _] = segments, opts \\ []) do
    ended? = Keyword.get(opts, :ended?, false)
    url = Keyword.get(opts, :url, & &1.key)

    target =
      segments
      |> Enum.map(&ceil(&1.duration))
      |> Enum.max()
      |> max(stream.target_duration || 1)

    discontinuity_sequence =
      first.discontinuity_sequence - if(first.discontinuity, do: 1, else: 0)

    header = [
      "#EXTM3U",
      "#EXT-X-VERSION:3",
      "#EXT-X-TARGETDURATION:#{target}",
      "#EXT-X-MEDIA-SEQUENCE:#{first.sequence}",
      "#EXT-X-DISCONTINUITY-SEQUENCE:#{max(discontinuity_sequence, 0)}"
    ]

    type = if ended?, do: ["#EXT-X-PLAYLIST-TYPE:VOD"], else: []
    footer = if ended?, do: ["#EXT-X-ENDLIST"], else: []

    [header, type, Enum.map(segments, &segment(&1, url)), footer]
    |> List.flatten()
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp segment(%Segment{} = segment, url) do
    [
      if(segment.discontinuity, do: "#EXT-X-DISCONTINUITY"),
      if(segment.program_date_time,
        do:
          "#EXT-X-PROGRAM-DATE-TIME:" <>
            (segment.program_date_time
             |> DateTime.truncate(:millisecond)
             |> DateTime.to_iso8601())
      ),
      "#EXTINF:#{:erlang.float_to_binary(segment.duration * 1.0, decimals: 3)},",
      url.(segment)
    ]
    |> Enum.reject(&is_nil/1)
  end
end
