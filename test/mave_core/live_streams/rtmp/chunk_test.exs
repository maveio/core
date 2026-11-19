defmodule MaveCore.LiveStreams.RTMP.ChunkTest do
  use ExUnit.Case, async: true

  alias MaveCore.LiveStreams.RTMP.Chunk

  defp message(payload, overrides \\ %{}) do
    Map.merge(%{type: 9, timestamp: 40, stream_id: 1, payload: payload}, overrides)
  end

  defp encode(message, chunk_size \\ 128),
    do: IO.iodata_to_binary(Chunk.encode(4, message, chunk_size))

  test "reassembles a message that spans several chunks" do
    message = message(:binary.copy(<<7>>, 300))

    assert {:ok, [^message], _state, <<>>} = Chunk.parse(Chunk.new(), encode(message))
  end

  test "waits for the rest of a chunk and keeps the unread bytes" do
    message = message(:binary.copy(<<7>>, 300))
    <<head::binary-size(200), tail::binary>> = encode(message)

    assert {:ok, [], state, rest} = Chunk.parse(Chunk.new(), head)
    assert {:ok, [^message], _state, <<>>} = Chunk.parse(state, rest <> tail)
  end

  test "applies header compression from earlier chunks on the same chunk stream" do
    first = encode(message("one"))
    # Type 1: new length and type, timestamp delta. Type 2: delta only. Type 3: all implied.
    second = <<1::2, 4::6, 20::24, 3::24, 9, "two">>
    third = <<2::2, 4::6, 10::24, "thr">>
    fourth = <<3::2, 4::6, "fou">>

    assert {:ok, messages, _state, <<>>} =
             Chunk.parse(Chunk.new(), first <> second <> third <> fourth)

    assert Enum.map(messages, &{&1.timestamp, &1.payload}) ==
             [{40, "one"}, {60, "two"}, {70, "thr"}, {80, "fou"}]

    assert Enum.all?(messages, &(&1.stream_id == 1 and &1.type == 9))
  end

  test "reads extended timestamps, also on continuation chunks" do
    message = message(:binary.copy(<<1>>, 200), %{timestamp: 0x1000000})

    assert {:ok, [^message], _state, <<>>} = Chunk.parse(Chunk.new(), encode(message))
  end

  test "stops after a Set Chunk Size message so the caller can apply it" do
    set_chunk_size = encode(message(<<4096::32>>, %{type: 1, timestamp: 0, stream_id: 0}))
    media = message(:binary.copy(<<7>>, 1000))

    assert {:ok, [%{type: 1}], state, rest} =
             Chunk.parse(Chunk.new(), set_chunk_size <> encode(media, 4096))

    {:ok, state} = Chunk.put_chunk_size(state, 4096)
    assert {:ok, [^media], _state, <<>>} = Chunk.parse(state, rest)
  end

  test "an abort drops the partial message of a chunk stream" do
    <<head::binary-size(150), _tail::binary>> = encode(message(:binary.copy(<<7>>, 300)))
    {:ok, [], state, _rest} = Chunk.parse(Chunk.new(), head)

    next = message("next")
    assert {:ok, [^next], _state, <<>>} = Chunk.parse(Chunk.abort(state, 4), encode(next))
  end

  test "rejects input that no encoder sends" do
    assert Chunk.parse(Chunk.new(), <<3::2, 5::6, 0>>) == {:error, :unknown_chunk_stream}

    oversized = <<0::2, 4::6, 0::24, 0xFFFFFF::24, 9, 1::little-32>>
    assert Chunk.parse(Chunk.new(), oversized) == {:error, :message_too_large}

    assert Chunk.put_chunk_size(Chunk.new(), 0) == {:error, :invalid_chunk_size}

    flood =
      for id <- 2..66, into: <<>> do
        <<0::2, 0::6, id, 0::24, 1::24, 9, 1::little-32, 0>>
      end

    assert Chunk.parse(Chunk.new(), flood) == {:error, :too_many_chunk_streams}
  end
end
