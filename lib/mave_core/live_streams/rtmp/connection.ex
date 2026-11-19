defmodule MaveCore.LiveStreams.RTMP.Connection do
  @moduledoc """
  One RTMP connection from an encoder: handshake, the commands that lead to
  `publish`, and the audio and video messages that follow.

  Only publishing is supported. The stream key is the publish name, which is
  where OBS and FFmpeg put it. Media is handed to a sink, by default
  `MaveCore.LiveStreams.Session`.
  """

  use ThousandIsland.Handler

  require Logger

  alias MaveCore.LiveStreams.RTMP.{AMF0, Chunk}
  alias MaveCore.LiveStreams.Session

  @handshake_bytes 1536
  @window 2_500_000
  @out_chunk_size 4096
  # Bytes an encoder may send before it has published with a valid key.
  @max_unauthenticated_bytes 64 * 1024
  @control_chunk_stream 2
  @command_chunk_stream 3
  @publish_stream_id 1

  @impl ThousandIsland.Handler
  def handle_connection(_socket, opts) do
    {:continue,
     %{
       sink: Keyword.get(opts, :sink, Session),
       phase: :version,
       buffer: <<>>,
       chunks: Chunk.new(),
       received: 0,
       acknowledged: 0,
       session: nil
     }}
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    state = %{state | buffer: state.buffer <> data, received: state.received + byte_size(data)}

    if state.session == nil and state.received > @max_unauthenticated_bytes do
      {:close, state}
    else
      case process(state, socket) do
        {:ok, state} -> {:continue, acknowledge(state, socket)}
        {:close, state} -> {:close, state}
      end
    end
  end

  @impl ThousandIsland.Handler
  def handle_close(_socket, state), do: stop_session(state)

  @impl ThousandIsland.Handler
  def handle_error(_reason, _socket, state), do: stop_session(state)

  @impl ThousandIsland.Handler
  def handle_timeout(_socket, state), do: stop_session(state)

  @impl ThousandIsland.Handler
  def handle_shutdown(_socket, state), do: stop_session(state)

  defp stop_session(%{session: nil}), do: :ok
  defp stop_session(%{sink: sink, session: session}), do: sink.stop(session)

  # ---------------------------------------------------------------------------
  # Handshake
  # ---------------------------------------------------------------------------

  # C0 and C1 arrive together; S0, S1 and S2 answer them in one write. S2
  # echoes C1, which is what publishing encoders verify, if anything.
  defp process(
         %{phase: :version, buffer: <<3, c1::binary-size(@handshake_bytes), rest::binary>>} =
           state,
         socket
       ) do
    s1 = <<0::32, 0::32, :crypto.strong_rand_bytes(@handshake_bytes - 8)::binary>>
    send_data(socket, [3, s1, c1])
    process(%{state | phase: :acknowledge, buffer: rest}, socket)
  end

  defp process(%{phase: :version, buffer: <<version, _::binary>>} = state, _socket)
       when version != 3,
       do: {:close, state}

  defp process(
         %{phase: :acknowledge, buffer: <<_c2::binary-size(@handshake_bytes), rest::binary>>} =
           state,
         socket
       ),
       do: process(%{state | phase: :connected, buffer: rest}, socket)

  defp process(%{phase: phase} = state, _socket) when phase in [:version, :acknowledge],
    do: {:ok, state}

  # ---------------------------------------------------------------------------
  # Messages
  # ---------------------------------------------------------------------------

  defp process(%{buffer: <<>>} = state, _socket), do: {:ok, state}

  defp process(state, socket) do
    case Chunk.parse(state.chunks, state.buffer) do
      {:ok, [], chunks, rest} ->
        {:ok, %{state | chunks: chunks, buffer: rest}}

      {:ok, messages, chunks, rest} ->
        state = %{state | chunks: chunks, buffer: rest}

        case handle_messages(messages, state, socket) do
          # A Set Chunk Size message ends a parse round early.
          {:ok, state} -> process(state, socket)
          {:close, state} -> {:close, state}
        end

      {:error, reason} ->
        Logger.debug("RTMP connection closed: #{reason}")
        {:close, state}
    end
  end

  defp handle_messages([], state, _socket), do: {:ok, state}

  defp handle_messages([message | rest], state, socket) do
    case handle_message(message, state, socket) do
      {:ok, state} -> handle_messages(rest, state, socket)
      {:close, state} -> {:close, state}
    end
  end

  defp handle_message(%{type: 1, payload: <<0::1, size::31>>}, state, _socket) do
    case Chunk.put_chunk_size(state.chunks, size) do
      {:ok, chunks} -> {:ok, %{state | chunks: chunks}}
      {:error, _reason} -> {:close, state}
    end
  end

  defp handle_message(%{type: 2, payload: <<chunk_stream_id::32>>}, state, _socket),
    do: {:ok, %{state | chunks: Chunk.abort(state.chunks, chunk_stream_id)}}

  defp handle_message(%{type: type, timestamp: timestamp, payload: payload}, state, _socket)
       when type in [8, 9] and state.session != nil and byte_size(payload) > 0 do
    kind = if type == 8, do: :audio, else: :video

    case state.sink.write(state.session, kind, timestamp, payload) do
      :ok -> {:ok, state}
      {:error, _reason} -> {:close, %{state | session: nil}}
    end
  end

  defp handle_message(%{type: 18, payload: payload}, %{session: session} = state, _socket)
       when session != nil do
    with {:ok, values} <- AMF0.decode(payload),
         %{} = metadata <- metadata(values) do
      state.sink.metadata(session, metadata)
    end

    {:ok, state}
  end

  defp handle_message(%{type: 20, payload: payload} = message, state, socket),
    do: handle_command(AMF0.decode(payload), message, state, socket)

  # AMF3 commands from Flash-era encoders wrap AMF0 behind one format byte.
  defp handle_message(%{type: 17, payload: <<0, payload::binary>>} = message, state, socket),
    do: handle_command(AMF0.decode(payload), message, state, socket)

  defp handle_message(_message, state, _socket), do: {:ok, state}

  defp metadata(["@setDataFrame", "onMetaData", %{} = metadata | _]), do: metadata
  defp metadata(["onMetaData", %{} = metadata | _]), do: metadata
  defp metadata(_values), do: nil

  # ---------------------------------------------------------------------------
  # Commands
  # ---------------------------------------------------------------------------

  defp handle_command({:ok, ["connect", transaction | _]}, _message, state, socket) do
    send_data(socket, [
      control(5, <<@window::32>>),
      control(6, <<@window::32, 2>>),
      control(1, <<@out_chunk_size::32>>),
      command(0, [
        "_result",
        transaction,
        {:object, [{"fmsVer", "FMS/3,0,1,123"}, {"capabilities", 31}]},
        {:object,
         [
           {"level", "status"},
           {"code", "NetConnection.Connect.Success"},
           {"description", "Connection succeeded."},
           {"objectEncoding", 0}
         ]}
      ])
    ])

    {:ok, state}
  end

  defp handle_command({:ok, ["createStream", transaction | _]}, _message, state, socket) do
    send_data(socket, command(0, ["_result", transaction, nil, @publish_stream_id]))
    {:ok, state}
  end

  defp handle_command({:ok, [name, transaction | _]}, _message, state, socket)
       when name in ["releaseStream", "FCPublish"] and is_number(transaction) do
    send_data(socket, command(0, ["_result", transaction, nil, nil]))
    {:ok, state}
  end

  defp handle_command(
         {:ok, ["publish", _transaction, _object, name | _]},
         %{stream_id: stream_id},
         %{session: nil} = state,
         socket
       )
       when is_binary(name) do
    # Encoders may append a query string to the stream key.
    stream_key = name |> String.split("?", parts: 2) |> hd()

    case state.sink.start(stream_key, self()) do
      {:ok, session} ->
        send_data(socket, [
          control(4, <<0::16, stream_id::32>>),
          status(stream_id, "status", "NetStream.Publish.Start", "Publishing started.")
        ])

        {:ok, %{state | session: session}}

      {:error, reason} ->
        send_data(
          socket,
          status(stream_id, "error", "NetStream.Publish.BadName", refusal(reason))
        )

        {:close, state}
    end
  end

  defp handle_command({:ok, [name | _]}, _message, state, _socket)
       when name in ["FCUnpublish", "deleteStream", "closeStream"] do
    stop_session(state)
    {:close, %{state | session: nil}}
  end

  defp handle_command({:ok, [name | _]}, _message, state, _socket) when name in ["play", "play2"],
    do: {:close, state}

  defp handle_command(_command, _message, state, _socket), do: {:ok, state}

  defp refusal(:unavailable), do: "Live streaming is not available for this stream."
  defp refusal(:already_publishing), do: "This stream is already being published."
  defp refusal(_reason), do: "The stream key is not valid."

  # ---------------------------------------------------------------------------
  # Output
  # ---------------------------------------------------------------------------

  # Tells the encoder how much arrived, as its flow control expects.
  defp acknowledge(%{received: received, acknowledged: acknowledged} = state, socket)
       when received - acknowledged >= div(@window, 2) do
    send_data(socket, control(3, <<rem(received, 0x1_0000_0000)::32>>))
    %{state | acknowledged: received}
  end

  defp acknowledge(state, _socket), do: state

  defp control(type, payload) do
    Chunk.encode(
      @control_chunk_stream,
      %{type: type, timestamp: 0, stream_id: 0, payload: payload},
      @out_chunk_size
    )
  end

  defp command(stream_id, values) do
    Chunk.encode(
      @command_chunk_stream,
      %{type: 20, timestamp: 0, stream_id: stream_id, payload: AMF0.encode(values)},
      @out_chunk_size
    )
  end

  defp status(stream_id, level, code, description) do
    command(stream_id, [
      "onStatus",
      0,
      nil,
      {:object, [{"level", level}, {"code", code}, {"description", description}]}
    ])
  end

  defp send_data(socket, data), do: ThousandIsland.Socket.send(socket, data)
end
