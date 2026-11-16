defmodule MaveCore.LiveStreams.IngestIntegrationTest do
  use MaveCore.DataCase, async: false

  alias MaveCore.LiveStreams
  alias MaveCore.LiveStreams.RTMP.Connection
  alias MaveCore.LiveStreams.Segment
  alias MaveCore.Media.Storage
  alias MaveCore.Spaces.Space

  @moduletag :integration
  @moduletag timeout: 120_000

  setup do
    previous = Application.get_env(:mave_core, :live_streams, [])

    Application.put_env(
      :mave_core,
      :live_streams,
      Keyword.merge(previous, enabled: true, segment_seconds: 1, reconnect_seconds: 60)
    )

    on_exit(fn -> Application.put_env(:mave_core, :live_streams, previous) end)

    start_supervised!({Registry, keys: :unique, name: MaveCore.LiveStreams.Registry})

    start_supervised!(
      {DynamicSupervisor, name: MaveCore.LiveStreams.SessionSupervisor, strategy: :one_for_one}
    )

    listener = start_supervised!({ThousandIsland, port: 0, handler_module: Connection})
    {:ok, {_address, port}} = ThousandIsland.listener_info(listener)

    hash = for _ <- 1..5, into: "", do: <<Enum.random(?a..?z)>>
    space = Repo.insert!(%Space{hash: hash, region: "eu"})
    {:ok, stream} = LiveStreams.create(space, %{name: "Launch event"})

    on_exit(fn -> Storage.delete_prefix(LiveStreams.bucket(space), "live/", space.region) end)

    {:ok, port: port, space: space, stream: stream}
  end

  test "an RTMP publish becomes a playable HLS broadcast", %{
    port: port,
    space: space,
    stream: stream
  } do
    LiveStreams.subscribe(space.id)

    assert {_output, 0} = publish(port, stream.stream_key, 4)
    assert_receive {:live_stream_updated, _id}

    # The session ends with the encoder's connection.
    stream =
      await(
        fn -> match?(%{status: :disconnected}, LiveStreams.get(space, stream.id)) end,
        space,
        stream
      )

    assert stream.broadcast == 1
    assert stream.ingest["width"] == 320
    assert stream.ingest["video_codec"] == "h264"

    segments =
      Repo.all(from(s in Segment, where: s.live_stream_id == ^stream.id, order_by: s.sequence))

    assert length(segments) >= 3
    assert Enum.map(segments, & &1.sequence) == Enum.to_list(0..(length(segments) - 1))
    assert_in_delta Enum.sum(Enum.map(segments, & &1.duration)), 4.0, 0.5

    {:ok, playlist} = LiveStreams.playlist(stream)
    assert playlist =~ "#EXT-X-TARGETDURATION:"
    refute playlist =~ "#EXT-X-ENDLIST"
    assert playlist =~ "/#{List.last(segments).key}\n"

    # Stored segments are real MPEG-TS with the encoder's H.264 video.
    assert {:ok, <<0x47, _::binary>>} =
             Storage.get(LiveStreams.bucket(space), hd(segments).key, space.region)

    # A reconnect within the window resumes the broadcast after a discontinuity.
    assert {_output, 0} = publish(port, stream.stream_key, 2)

    stream =
      await(
        fn -> match?(%{status: :disconnected}, LiveStreams.get(space, stream.id)) end,
        space,
        stream
      )

    resumed =
      Repo.all(from(s in Segment, where: s.live_stream_id == ^stream.id, order_by: s.sequence))

    assert length(resumed) > length(segments)
    assert stream.broadcast == 1
    assert Enum.at(resumed, length(segments)).discontinuity

    # Ending the broadcast turns the playlist into the full recording.
    LiveStreams.end_broadcast(stream)
    stream = LiveStreams.get(space, stream.id)
    assert stream.status == :ended

    {:ok, recording} = LiveStreams.playlist(stream)
    assert recording =~ "#EXT-X-PLAYLIST-TYPE:VOD"
    assert recording =~ "#EXT-X-DISCONTINUITY\n"
    assert recording =~ "#EXT-X-ENDLIST"
    assert length(Regex.scan(~r/^https?:.+\.ts$/m, recording)) == length(resumed)
  end

  test "a wrong stream key is refused", %{port: port, stream: stream} do
    assert {_output, status} = publish(port, "live_" <> String.duplicate("x", 32), 1)
    assert status != 0
    assert Repo.get!(LiveStreams.LiveStream, stream.id).status == :idle
  end

  defp publish(port, stream_key, seconds) do
    System.cmd(
      "ffmpeg",
      ~w(-hide_banner -loglevel error -re -f lavfi -i testsrc=size=320x180:rate=30 -f lavfi -i sine=frequency=440:sample_rate=44100
         -t #{seconds} -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p -g 30 -keyint_min 30 -sc_threshold 0
         -c:a aac -b:a 64k -f flv rtmp://127.0.0.1:#{port}/live/#{stream_key}),
      stderr_to_stdout: true
    )
  end

  defp await(fun, space, stream, attempts \\ 100) do
    cond do
      fun.() ->
        LiveStreams.get(space, stream.id)

      attempts == 0 ->
        flunk("live stream did not reach the expected state")

      true ->
        Process.sleep(100)
        await(fun, space, stream, attempts - 1)
    end
  end
end
