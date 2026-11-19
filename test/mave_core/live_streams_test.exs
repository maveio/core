defmodule MaveCore.LiveStreamsTest do
  use MaveCore.DataCase, async: false

  import MaveCore.LiveStreamsFixtures

  alias MaveCore.Embeds.SettingsSerializer
  alias MaveCore.LiveStreams
  alias MaveCore.LiveStreams.{LiveStream, Segment}

  defmodule DeniedUsageLimits do
    @moduledoc false
    def can_use_live_streaming?(_space), do: {:error, :live_streaming_unavailable}
  end

  setup do
    enable_live_streams(reconnect_seconds: 60, playlist_segments: 6)
    {:ok, space: space_fixture()}
  end

  describe "availability" do
    test "needs the installation to enable live streaming", %{space: space} do
      assert LiveStreams.available?(space)

      Application.put_env(:mave_core, :live_streams, enabled: false)
      refute LiveStreams.available?(space)
      assert LiveStreams.create(space) == {:error, :live_streaming_unavailable}
    end

    test "follows the host's policy for the space", %{space: space} do
      stream = live_stream_fixture(space)

      Application.put_env(:mave_core, :usage_limits_backend, DeniedUsageLimits)

      refute LiveStreams.available?(space)
      assert LiveStreams.create(space) == {:error, :live_streaming_unavailable}
      assert LiveStreams.authenticate(stream.stream_key) == {:error, :unavailable}
    end
  end

  describe "management" do
    test "creates a stream with its own key and playback address", %{space: space} do
      LiveStreams.subscribe(space.id)

      assert {:ok, %LiveStream{status: :idle, broadcast: 0} = stream} =
               LiveStreams.create(space, %{name: "  Town hall  "})

      assert stream.name == "Town hall"
      assert stream.stream_key =~ ~r/\Alive_[A-Za-z0-9_-]{32}\z/
      assert stream.hash =~ ~r/\A[a-z0-9]{10}\z/
      assert_receive {:live_stream_updated, id} when id == stream.id

      assert LiveStreams.playback_url(space, stream) =~
               "/live/#{space.hash}#{stream.hash}/index.m3u8"

      refute inspect(stream) =~ stream.stream_key
    end

    test "finds a stream by id, hash and public id, only in its space", %{space: space} do
      stream = live_stream_fixture(space)

      assert LiveStreams.get(space, stream.id).id == stream.id
      assert LiveStreams.get(space, stream.hash).id == stream.id
      assert LiveStreams.get(space, space.hash <> stream.hash).id == stream.id
      assert LiveStreams.get_by_public_id(space.hash <> stream.hash).id == stream.id

      assert LiveStreams.get(space_fixture(), stream.id) == nil
      assert LiveStreams.get(space, "missing") == nil
      assert LiveStreams.get_by_public_id("nope") == nil
      assert [%LiveStream{}] = LiveStreams.list(space)
    end

    test "renames a stream and rejects names that are too long", %{space: space} do
      stream = live_stream_fixture(space, %{name: "Before"})

      assert {:ok, %{name: "After"}} = LiveStreams.update(stream, %{name: "After"})
      assert {:ok, %{name: nil}} = LiveStreams.update(stream, %{name: "  "})

      assert {:error, %Ecto.Changeset{}} =
               LiveStreams.update(stream, %{name: String.duplicate("a", 161)})
    end

    test "a replaced stream key no longer authenticates", %{space: space} do
      stream = live_stream_fixture(space)
      assert {:ok, %{id: id}} = LiveStreams.authenticate(stream.stream_key)
      assert id == stream.id

      {:ok, replaced} = LiveStreams.reset_stream_key(stream)

      assert replaced.stream_key != stream.stream_key
      assert LiveStreams.authenticate(stream.stream_key) == {:error, :unauthorized}
      assert {:ok, _stream} = LiveStreams.authenticate(replaced.stream_key)
      assert LiveStreams.authenticate("short") == {:error, :unauthorized}
      assert LiveStreams.authenticate(nil) == {:error, :unauthorized}
    end

    test "deleting removes the segments, the media and the running session", %{space: space} do
      stream = live_stream_fixture(space) |> broadcast_fixture(2)
      LiveStreams.subscribe_control(stream.id)

      assert {:ok, _deleted} = LiveStreams.delete(stream)

      assert_receive :live_stream_deleted
      assert_receive {:deleted_prefix, bucket, prefix}
      assert bucket == LiveStreams.bucket(space)
      assert prefix == "live/#{stream.hash}/"
      assert LiveStreams.get(space, stream.id) == nil
      assert Repo.aggregate(Segment, :count) == 0
    end
  end

  describe "a broadcast" do
    test "starts with the first connection and lists a sliding window", %{space: space} do
      stream = live_stream_fixture(space)
      assert LiveStreams.playlist(stream) == {:error, :not_started}

      {:ok, live, position} = LiveStreams.begin_session(stream)

      assert %{status: :live, broadcast: 1, started_at: %DateTime{}} = live
      assert position == %{next_sequence: 0, discontinuity?: false, discontinuity_sequence: 0}
      assert LiveStreams.playlist(live) == {:error, :not_started}
      refute LiveStreams.public_status(live).playable

      live = record(live, 0..7)
      assert live.target_duration == 2
      assert LiveStreams.public_status(live).playable

      {:ok, playlist} = LiveStreams.playlist(live)

      assert playlist =~ "#EXT-X-TARGETDURATION:2\n"
      assert playlist =~ "#EXT-X-MEDIA-SEQUENCE:2\n"
      assert playlist =~ "#EXTINF:2.000,\n#{segment_url(space, live, 1, 7)}\n"
      refute playlist =~ segment_url(space, live, 1, 1)
      refute playlist =~ "#EXT-X-ENDLIST"
    end

    test "resumes after a reconnect and becomes a recording when it ends", %{space: space} do
      stream = live_stream_fixture(space) |> broadcast_fixture(3)

      LiveStreams.end_session(stream, nil)
      assert %{status: :disconnected} = stream = LiveStreams.get(space, stream.id)

      {:ok, resumed, position} = LiveStreams.begin_session(stream)

      assert %{status: :live, broadcast: 1, disconnected_at: nil} = resumed
      assert resumed.started_at == stream.started_at
      assert position == %{next_sequence: 3, discontinuity?: true, discontinuity_sequence: 0}

      resumed = broadcast_segments(resumed, position, 2)
      LiveStreams.end_session(resumed)
      LiveStreams.end_broadcast(resumed)

      assert %{status: :ended, ended_at: %DateTime{}} = ended = LiveStreams.get(space, stream.id)
      assert LiveStreams.recorded_seconds(ended) == 10.0

      {:ok, recording} = LiveStreams.playlist(ended)

      assert recording =~ "#EXT-X-PLAYLIST-TYPE:VOD\n"
      assert recording =~ "#EXT-X-MEDIA-SEQUENCE:0\n"
      assert recording =~ "#EXT-X-DISCONTINUITY-SEQUENCE:0\n"

      assert recording =~
               "#{segment_url(space, ended, 1, 2)}\n#EXT-X-DISCONTINUITY\n#EXTINF:2.000,\n" <>
                 "#{segment_url(space, ended, 1, 3)}\n"

      assert String.ends_with?(recording, "#{segment_url(space, ended, 1, 4)}\n#EXT-X-ENDLIST\n")
    end

    test "a live window that starts after a discontinuity counts it", %{space: space} do
      Application.put_env(:mave_core, :live_streams, enabled: true, playlist_segments: 2)
      stream = live_stream_fixture(space) |> broadcast_fixture(2)
      LiveStreams.end_session(stream)

      {:ok, resumed, position} = LiveStreams.begin_session(LiveStreams.get(space, stream.id))
      resumed = broadcast_segments(resumed, position, 3)

      {:ok, playlist} = LiveStreams.playlist(resumed)

      assert playlist =~ "#EXT-X-MEDIA-SEQUENCE:3\n"
      assert playlist =~ "#EXT-X-DISCONTINUITY-SEQUENCE:1\n"
      refute playlist =~ "#EXT-X-DISCONTINUITY\n"
    end

    test "the next broadcast replaces the recording", %{space: space} do
      stream = live_stream_fixture(space) |> broadcast_fixture(3)
      LiveStreams.end_session(stream)
      LiveStreams.end_broadcast(stream)

      {:ok, next, position} = LiveStreams.begin_session(LiveStreams.get(space, stream.id))

      assert %{status: :live, broadcast: 2, ended_at: nil, target_duration: nil} = next
      assert position == %{next_sequence: 0, discontinuity?: false, discontinuity_sequence: 0}
      assert Repo.aggregate(Segment, :count) == 0
      assert_receive {:deleted_prefix, _bucket, prefix}
      assert prefix == "live/#{stream.hash}/1/"

      # The new broadcast has addresses of its own.
      next = record(next, 0..1)
      {:ok, playlist} = LiveStreams.playlist(next)

      assert playlist =~ segment_url(space, next, 2, 0)
      refute playlist =~ "live/#{stream.hash}/1/"
    end

    test "ends when the encoder stays away longer than the reconnect window", %{space: space} do
      stream = live_stream_fixture(space) |> broadcast_fixture(2)
      LiveStreams.end_session(stream, "The encoder sent HEVC video")
      disconnect_at(stream, -61)

      # Readers see the end without waiting for the sweeper.
      assert %{status: :ended, last_error: "The encoder sent HEVC video"} =
               LiveStreams.get(space, stream.id)

      assert {:ok, playlist} = LiveStreams.playlist(LiveStreams.get(space, stream.id))
      assert playlist =~ "#EXT-X-ENDLIST"
      assert Repo.get!(LiveStream, stream.id).status == :disconnected

      LiveStreams.subscribe(space.id)
      LiveStreams.sweep()

      assert %{status: :ended, ended_at: %DateTime{}} = Repo.get!(LiveStream, stream.id)
      assert_receive {:live_stream_updated, _id}

      {:ok, next, _position} = LiveStreams.begin_session(stream)
      assert next.broadcast == 2
    end

    test "the sweeper releases streams whose ingest session stopped reporting", %{space: space} do
      lost = live_stream_fixture(space) |> broadcast_fixture(1)
      running = live_stream_fixture(space) |> broadcast_fixture(1)
      fresh = live_stream_fixture(space) |> broadcast_fixture(1)

      stale = DateTime.add(DateTime.utc_now(), -120, :second)

      Repo.update_all(from(s in LiveStream, where: s.id in ^[lost.id, running.id]),
        set: [heartbeat_at: stale]
      )

      LiveStreams.sweep(&(&1 == running.id))

      assert Repo.get!(LiveStream, lost.id).status == :disconnected
      assert Repo.get!(LiveStream, running.id).status == :live
      assert Repo.get!(LiveStream, fresh.id).status == :live
    end

    test "keeps what the encoder reports about itself", %{space: space} do
      stream = live_stream_fixture(space)

      {:ok, stream} =
        LiveStreams.put_ingest(stream, %{"width" => 1280, "encoder" => nil, "other" => "x"})

      assert stream.ingest == %{"width" => 1280}
      assert LiveStreams.response(space, stream).encoder == %{"width" => 1280}
    end
  end

  # Segments are listed at the address public media of the space is served from.
  defp segment_url(space, stream, broadcast, sequence) do
    SettingsSerializer.storage_object_url(
      LiveStreams.bucket(space),
      "live/#{stream.hash}/#{broadcast}/#{sequence}.ts"
    )
  end

  defp record(stream, sequences) do
    Enum.reduce(sequences, stream, fn sequence, stream ->
      {:ok, stream, _segment} =
        LiveStreams.record_segment(stream, %{
          sequence: sequence,
          duration: 2.0,
          key: "#{LiveStreams.broadcast_prefix(stream, stream.broadcast)}#{sequence}.ts",
          size_bytes: 1_000,
          discontinuity: false,
          discontinuity_sequence: 0
        })

      stream
    end)
  end

  defp broadcast_segments(stream, position, count) do
    Enum.reduce(0..(count - 1), stream, fn offset, stream ->
      {:ok, stream, _segment} =
        LiveStreams.record_segment(stream, %{
          sequence: position.next_sequence + offset,
          duration: 2.0,
          key: "live/#{stream.hash}/#{stream.broadcast}/#{position.next_sequence + offset}.ts",
          size_bytes: 1_000,
          discontinuity: position.discontinuity? and offset == 0,
          discontinuity_sequence: position.discontinuity_sequence + 1
        })

      stream
    end)
  end

  defp disconnect_at(stream, seconds) do
    at = DateTime.add(DateTime.utc_now(), seconds, :second)
    Repo.update_all(from(s in LiveStream, where: s.id == ^stream.id), set: [disconnected_at: at])
  end
end
