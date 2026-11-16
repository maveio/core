defmodule MaveCore.LiveStreams.RTMP.ConnectionTest do
  use ExUnit.Case, async: false

  alias MaveCore.LiveStreams.RTMP.{AMF0, Chunk, Connection}

  defmodule Sink do
    @moduledoc false
    # Reports what the connection hands over to the running test.

    def start("valid-key", _publisher) do
      send(:live_connection_test, {:sink, :started})
      {:ok, Process.whereis(:live_connection_test)}
    end

    def start(_stream_key, _publisher), do: {:error, :unauthorized}

    def write(session, kind, timestamp, payload) do
      send(session, {:sink, :write, kind, timestamp, payload})
      :ok
    end

    def metadata(session, metadata), do: send(session, {:sink, :metadata, metadata})
    def stop(session), do: send(session, {:sink, :stopped})
  end

  setup do
    Process.register(self(), :live_connection_test)

    listener =
      start_supervised!(
        {ThousandIsland, port: 0, handler_module: Connection, handler_options: [sink: Sink]}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(listener)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    {:ok, socket: socket, port: port}
  end

  test "an encoder publishes with a valid stream key", %{socket: socket} do
    handshake(socket)

    command(socket, 0, ["connect", 1, %{"app" => "live", "type" => "nonprivate"}])
    {messages, state} = read_commands(socket, Chunk.new(), 1)

    # Window size, peer bandwidth and chunk size precede the result.
    assert Enum.map(messages, & &1.type) == [5, 6, 1, 20]

    assert ["_result", 1.0, %{"fmsVer" => _}, %{"code" => "NetConnection.Connect.Success"}] =
             decode(List.last(messages))

    command(socket, 0, ["releaseStream", 2, nil, "valid-key"])
    command(socket, 0, ["FCPublish", 3, nil, "valid-key"])
    command(socket, 0, ["createStream", 4, nil])
    {messages, state} = read_commands(socket, state, 3)
    assert ["_result", 4.0, nil, 1.0] = decode(List.last(messages))

    # OBS appends nothing, but some encoders add a query string to the key.
    command(socket, 1, ["publish", 5, nil, "valid-key?session=1", "live"])
    {messages, _state} = read_commands(socket, state, 1)

    assert ["onStatus", +0.0, nil, %{"code" => "NetStream.Publish.Start", "level" => "status"}] =
             decode(List.last(messages))

    assert_receive {:sink, :started}

    send_message(socket, %{
      type: 18,
      timestamp: 0,
      stream_id: 1,
      payload: AMF0.encode(["@setDataFrame", "onMetaData", %{"width" => 1280}])
    })

    video = :binary.copy(<<0x17>>, 9000)
    send_message(socket, %{type: 9, timestamp: 33, stream_id: 1, payload: video})
    send_message(socket, %{type: 8, timestamp: 40, stream_id: 1, payload: <<0xAF, 1, 2>>})

    assert_receive {:sink, :metadata, %{"width" => 1280.0}}
    assert_receive {:sink, :write, :video, 33, ^video}
    assert_receive {:sink, :write, :audio, 40, <<0xAF, 1, 2>>}

    :gen_tcp.close(socket)
    assert_receive {:sink, :stopped}
  end

  test "an unpublish command ends the session", %{socket: socket} do
    handshake(socket)
    command(socket, 1, ["publish", 1, nil, "valid-key", "live"])
    assert_receive {:sink, :started}

    command(socket, 0, ["FCUnpublish", 2, nil, "valid-key"])
    assert_receive {:sink, :stopped}
    assert closed?(socket)
  end

  test "a wrong stream key is refused and the connection closes", %{socket: socket} do
    handshake(socket)
    command(socket, 1, ["publish", 1, nil, "wrong-key", "live"])

    {messages, _state} = read_commands(socket, Chunk.new(), 1)

    assert ["onStatus", +0.0, nil, %{"code" => "NetStream.Publish.BadName", "level" => "error"}] =
             decode(List.last(messages))

    assert closed?(socket)
    refute_received {:sink, :started}
  end

  test "media before publishing is ignored and capped", %{socket: socket} do
    handshake(socket)

    video = %{type: 9, timestamp: 0, stream_id: 1, payload: :binary.copy(<<0x17>>, 40_000)}
    send_message(socket, video)
    send_message(socket, video)

    assert closed?(socket)
    refute_received {:sink, :write, _kind, _timestamp, _payload}
  end

  test "playback over RTMP and other protocol versions are not served", %{
    socket: socket,
    port: port
  } do
    handshake(socket)
    command(socket, 1, ["play", 1, nil, "valid-key"])
    assert closed?(socket)

    {:ok, other} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    :ok = :gen_tcp.send(other, <<6, 0::size(1536)-unit(8)>>)
    assert closed?(other)
  end

  defp handshake(socket) do
    c1 = :crypto.strong_rand_bytes(1536)
    :ok = :gen_tcp.send(socket, [3, c1])
    {:ok, <<3, s1::binary-size(1536), s2::binary-size(1536)>>} = :gen_tcp.recv(socket, 3073, 2000)
    assert s2 == c1
    :ok = :gen_tcp.send(socket, s1)
  end

  defp command(socket, stream_id, values) do
    send_message(socket, %{
      type: 20,
      timestamp: 0,
      stream_id: stream_id,
      payload: AMF0.encode(values)
    })
  end

  defp send_message(socket, message), do: :gen_tcp.send(socket, Chunk.encode(3, message))

  # Reads until `count` command messages arrived, applying chunk size changes.
  defp read_commands(socket, state, count, buffer \\ <<>>, acc \\ []) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 2000)
    {messages, state, rest} = parse(state, buffer <> data, [])
    acc = acc ++ messages

    if Enum.count(acc, &(&1.type == 20)) >= count,
      do: {acc, state},
      else: read_commands(socket, state, count, rest, acc)
  end

  defp parse(state, buffer, acc) do
    case Chunk.parse(state, buffer) do
      {:ok, [], state, rest} ->
        {acc, state, rest}

      {:ok, messages, state, rest} ->
        state =
          case List.last(messages) do
            %{type: 1, payload: <<size::32>>} -> state |> Chunk.put_chunk_size(size) |> elem(1)
            _ -> state
          end

        parse(state, rest, acc ++ messages)
    end
  end

  defp decode(%{type: 20, payload: payload}) do
    {:ok, values} = AMF0.decode(payload)
    values
  end

  defp closed?(socket) do
    case :gen_tcp.recv(socket, 0, 2000) do
      {:error, :closed} -> true
      {:ok, _data} -> closed?(socket)
      {:error, _reason} -> false
    end
  end
end
