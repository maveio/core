defmodule MaveCore.LiveStreams.RTMP.AMF0 do
  @moduledoc """
  AMF0 values as used by RTMP command and data messages.

  Decoding is bounded and total: malformed or oversized input returns `:error`
  instead of raising, because the bytes come straight from an encoder.
  Objects decode to maps with string keys; `null` and `undefined` decode to `nil`.
  """

  @max_depth 8
  @max_values 256

  @type value ::
          number() | boolean() | String.t() | nil | %{optional(String.t()) => value()} | [value()]

  @doc "Decodes all AMF0 values in a message body."
  @spec decode(binary()) :: {:ok, [value()]} | :error
  def decode(binary) when is_binary(binary), do: decode_all(binary, [], 0)

  defp decode_all(<<>>, acc, _count), do: {:ok, Enum.reverse(acc)}
  defp decode_all(_rest, _acc, count) when count >= @max_values, do: :error

  defp decode_all(binary, acc, count) do
    case decode_value(binary, 0) do
      {:ok, value, rest} -> decode_all(rest, [value | acc], count + 1)
      :error -> :error
    end
  end

  defp decode_value(_binary, depth) when depth > @max_depth, do: :error
  defp decode_value(<<0x00, number::float-64, rest::binary>>, _depth), do: {:ok, number, rest}
  # NaN and infinities are not representable as Erlang floats.
  defp decode_value(<<0x00, _::binary-size(8), rest::binary>>, _depth), do: {:ok, nil, rest}
  defp decode_value(<<0x01, flag, rest::binary>>, _depth), do: {:ok, flag != 0, rest}

  defp decode_value(<<0x02, size::16, string::binary-size(size), rest::binary>>, _depth),
    do: {:ok, string, rest}

  defp decode_value(<<0x03, rest::binary>>, depth), do: decode_properties(rest, %{}, depth + 1)
  defp decode_value(<<0x05, rest::binary>>, _depth), do: {:ok, nil, rest}
  defp decode_value(<<0x06, rest::binary>>, _depth), do: {:ok, nil, rest}

  defp decode_value(<<0x08, _count::32, rest::binary>>, depth),
    do: decode_properties(rest, %{}, depth + 1)

  defp decode_value(<<0x0A, count::32, rest::binary>>, depth) when count <= @max_values,
    do: decode_array(rest, count, [], depth + 1)

  defp decode_value(<<0x0B, _milliseconds::binary-size(8), _zone::16, rest::binary>>, _depth),
    do: {:ok, nil, rest}

  defp decode_value(<<0x0C, size::32, string::binary-size(size), rest::binary>>, _depth),
    do: {:ok, string, rest}

  defp decode_value(_binary, _depth), do: :error

  defp decode_properties(<<0, 0, 0x09, rest::binary>>, acc, _depth), do: {:ok, acc, rest}

  defp decode_properties(<<size::16, key::binary-size(size), rest::binary>>, acc, depth)
       when map_size(acc) < @max_values do
    case decode_value(rest, depth) do
      {:ok, value, rest} -> decode_properties(rest, Map.put(acc, key, value), depth)
      :error -> :error
    end
  end

  defp decode_properties(_binary, _acc, _depth), do: :error

  defp decode_array(rest, 0, acc, _depth), do: {:ok, Enum.reverse(acc), rest}

  defp decode_array(binary, count, acc, depth) do
    case decode_value(binary, depth) do
      {:ok, value, rest} -> decode_array(rest, count - 1, [value | acc], depth)
      :error -> :error
    end
  end

  @doc """
  Encodes values. Objects are given as maps or as keyword-style lists of
  `{key, value}` tuples when property order matters.
  """
  @spec encode([term()]) :: binary()
  def encode(values) when is_list(values),
    do: IO.iodata_to_binary(Enum.map(values, &encode_value/1))

  defp encode_value(nil), do: <<0x05>>
  defp encode_value(true), do: <<0x01, 1>>
  defp encode_value(false), do: <<0x01, 0>>
  defp encode_value(number) when is_number(number), do: <<0x00, number * 1.0::float-64>>

  defp encode_value(string) when is_binary(string) and byte_size(string) <= 0xFFFF,
    do: <<0x02, byte_size(string)::16, string::binary>>

  defp encode_value(string) when is_binary(string),
    do: <<0x0C, byte_size(string)::32, string::binary>>

  defp encode_value(%{} = object), do: encode_value({:object, Enum.sort(Map.to_list(object))})

  defp encode_value({:object, properties}) when is_list(properties) do
    [
      0x03,
      Enum.map(properties, fn {key, value} ->
        key = to_string(key)
        [<<byte_size(key)::16>>, key, encode_value(value)]
      end),
      <<0, 0, 0x09>>
    ]
  end
end
