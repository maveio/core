defmodule MaveCore.LiveStreams.RTMP.Chunk do
  @moduledoc """
  RTMP chunk stream: reassembles incoming chunks into messages and splits
  outgoing messages into chunks.

  The parser is a pure function over a byte buffer. It consumes a chunk only
  when the chunk is complete, so callers can append socket data and call
  `parse/2` again.
  """

  @default_chunk_size 128
  # A single message is one audio frame, video frame or command. Even a
  # keyframe of a high-bitrate stream stays far below this bound.
  @max_message_bytes 8 * 1024 * 1024
  @max_chunk_streams 64
  @extended 0xFFFFFF

  defstruct chunk_size: @default_chunk_size, streams: %{}

  @type message :: %{
          type: 0..255,
          timestamp: non_neg_integer(),
          stream_id: non_neg_integer(),
          payload: binary()
        }

  @type t :: %__MODULE__{}

  def new, do: %__MODULE__{}

  @doc "Applies a Set Chunk Size message from the peer."
  def put_chunk_size(%__MODULE__{} = state, size) when size in 1..@max_message_bytes,
    do: {:ok, %{state | chunk_size: size}}

  def put_chunk_size(_state, _size), do: {:error, :invalid_chunk_size}

  @doc "Drops a partially received message (Abort Message)."
  def abort(%__MODULE__{streams: streams} = state, chunk_stream_id) do
    case streams do
      %{^chunk_stream_id => stream} ->
        %{state | streams: Map.put(streams, chunk_stream_id, %{stream | acc: [], received: 0})}

      _ ->
        state
    end
  end

  @doc """
  Parses as many complete chunks as `buffer` holds.

  Returns the completed messages in order, the new state and the unconsumed
  rest. Stops after a Set Chunk Size message so the caller can apply it before
  the following chunks are read.
  """
  @spec parse(t(), binary()) ::
          {:ok, [message()], t(), binary()} | {:error, atom()}
  def parse(%__MODULE__{} = state, buffer) when is_binary(buffer),
    do: parse(state, buffer, [])

  defp parse(state, buffer, messages) do
    case parse_chunk(state, buffer) do
      {:ok, nil, state, rest} ->
        parse(state, rest, messages)

      {:ok, %{type: 1} = message, state, rest} ->
        {:ok, Enum.reverse([message | messages]), state, rest}

      {:ok, message, state, rest} ->
        parse(state, rest, [message | messages])

      :more ->
        {:ok, Enum.reverse(messages), state, buffer}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_chunk(state, buffer) do
    with {:ok, format, chunk_stream_id, rest} <- basic_header(buffer),
         {:ok, stream, rest} <- message_header(format, state.streams[chunk_stream_id], rest),
         :ok <- validate(state, chunk_stream_id, stream) do
      read_payload(state, chunk_stream_id, stream, rest)
    end
  end

  defp basic_header(<<format::2, 0::6, id, rest::binary>>), do: {:ok, format, id + 64, rest}

  defp basic_header(<<format::2, 1::6, id::little-16, rest::binary>>),
    do: {:ok, format, id + 64, rest}

  defp basic_header(<<format::2, id::6, rest::binary>>) when id > 1, do: {:ok, format, id, rest}
  defp basic_header(_buffer), do: :more

  defp message_header(
         0,
         _previous,
         <<timestamp::24, length::24, type, stream_id::little-32, rest::binary>>
       ) do
    with {:ok, timestamp, extended?, rest} <- extended_timestamp(timestamp, rest) do
      {:ok,
       %{
         timestamp: timestamp,
         # A following type-3 chunk that starts a new message repeats this value.
         delta: timestamp,
         length: length,
         type: type,
         stream_id: stream_id,
         extended?: extended?,
         acc: [],
         received: 0
       }, rest}
    end
  end

  defp message_header(1, %{} = previous, <<delta::24, length::24, type, rest::binary>>) do
    with {:ok, delta, extended?, rest} <- extended_timestamp(delta, rest) do
      {:ok,
       %{
         previous
         | timestamp: wrap(previous.timestamp + delta),
           delta: delta,
           length: length,
           type: type,
           extended?: extended?
       }, rest}
    end
  end

  defp message_header(2, %{} = previous, <<delta::24, rest::binary>>) do
    with {:ok, delta, extended?, rest} <- extended_timestamp(delta, rest) do
      {:ok,
       %{
         previous
         | timestamp: wrap(previous.timestamp + delta),
           delta: delta,
           extended?: extended?
       }, rest}
    end
  end

  # Continuation of a message in progress: the header is fully implied.
  defp message_header(3, %{received: received} = previous, rest) when received > 0,
    do: skip_extended_timestamp(previous, rest)

  defp message_header(3, %{} = previous, rest) do
    with {:ok, previous, rest} <- skip_extended_timestamp(previous, rest) do
      {:ok, %{previous | timestamp: wrap(previous.timestamp + previous.delta)}, rest}
    end
  end

  defp message_header(format, nil, _rest) when format in [1, 2, 3],
    do: {:error, :unknown_chunk_stream}

  defp message_header(_format, _previous, _rest), do: :more

  defp extended_timestamp(@extended, <<timestamp::32, rest::binary>>),
    do: {:ok, timestamp, true, rest}

  defp extended_timestamp(@extended, _rest), do: :more
  defp extended_timestamp(timestamp, rest), do: {:ok, timestamp, false, rest}

  defp skip_extended_timestamp(%{extended?: true} = stream, <<_timestamp::32, rest::binary>>),
    do: {:ok, stream, rest}

  defp skip_extended_timestamp(%{extended?: true}, _rest), do: :more
  defp skip_extended_timestamp(stream, rest), do: {:ok, stream, rest}

  defp wrap(timestamp), do: rem(timestamp, 0x1_0000_0000)

  defp validate(state, chunk_stream_id, stream) do
    cond do
      stream.length > @max_message_bytes ->
        {:error, :message_too_large}

      not is_map_key(state.streams, chunk_stream_id) and
          map_size(state.streams) >= @max_chunk_streams ->
        {:error, :too_many_chunk_streams}

      true ->
        :ok
    end
  end

  defp read_payload(state, chunk_stream_id, stream, rest) do
    size = min(state.chunk_size, stream.length - stream.received)

    case rest do
      <<payload::binary-size(^size), rest::binary>> ->
        stream = %{stream | acc: [stream.acc, payload], received: stream.received + size}

        if stream.received == stream.length do
          message = %{
            type: stream.type,
            timestamp: stream.timestamp,
            stream_id: stream.stream_id,
            payload: IO.iodata_to_binary(stream.acc)
          }

          stream = %{stream | acc: [], received: 0}
          {:ok, message, put_stream(state, chunk_stream_id, stream), rest}
        else
          {:ok, nil, put_stream(state, chunk_stream_id, stream), rest}
        end

      _ ->
        :more
    end
  end

  defp put_stream(state, chunk_stream_id, stream),
    do: %{state | streams: Map.put(state.streams, chunk_stream_id, stream)}

  @doc """
  Encodes one message as type-0 chunk followed by type-3 continuation chunks.
  """
  @spec encode(2..63, message(), pos_integer()) :: iodata()
  def encode(chunk_stream_id, message, chunk_size \\ @default_chunk_size)
      when chunk_stream_id in 2..63 do
    %{type: type, timestamp: timestamp, stream_id: stream_id, payload: payload} = message

    {timestamp_field, extended} =
      if timestamp >= @extended, do: {@extended, <<timestamp::32>>}, else: {timestamp, <<>>}

    header = [
      <<0::2, chunk_stream_id::6, timestamp_field::24, byte_size(payload)::24, type,
        stream_id::little-32>>,
      extended
    ]

    [first | rest] = split(payload, chunk_size)
    [header, first | Enum.map(rest, &[<<3::2, chunk_stream_id::6>>, extended, &1])]
  end

  defp split(payload, chunk_size) when byte_size(payload) <= chunk_size, do: [payload]

  defp split(payload, chunk_size) do
    <<chunk::binary-size(^chunk_size), rest::binary>> = payload
    [chunk | split(rest, chunk_size)]
  end
end
