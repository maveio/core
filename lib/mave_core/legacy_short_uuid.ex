defmodule MaveCore.LegacyShortUUID do
  @moduledoc """
  Legacy-compatible short UUID codec.

  This mirrors the historical `shortuuid` v2.1.x behavior used by legacy mave.
  Keep this stable so previously exposed short IDs remain valid.
  """

  alias Ecto.UUID

  @alphabet "23456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
  @alphabet_size byte_size(@alphabet)
  @short_size 22
  @uuid_binary_size 16
  @index_by_char @alphabet |> :binary.bin_to_list() |> Enum.with_index() |> Map.new()

  @spec encode(binary()) :: {:ok, String.t()} | {:error, String.t()}
  def encode(<<_::binary-size(@short_size)>> = shortuuid) do
    case decode(shortuuid) do
      {:ok, _uuid} -> {:ok, shortuuid}
      {:error, reason} -> {:error, reason}
    end
  end

  def encode(input) do
    case to_uuid_binary(input) do
      {:ok, uuid_binary} ->
        uuid_binary
        |> :binary.decode_unsigned()
        |> encode_digits("")
        |> pad_shortuuid()
        |> then(&{:ok, &1})

      :error ->
        {:error, "Invalid UUID"}
    end
  end

  @spec encode!(binary()) :: String.t()
  def encode!(input) do
    case encode(input) do
      {:ok, encoded} -> encoded
      {:error, message} -> raise ArgumentError, message: message
    end
  end

  @spec decode(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def decode(shortuuid) when is_binary(shortuuid) and byte_size(shortuuid) < @short_size do
    shortuuid
    |> pad_shortuuid()
    |> decode()
  end

  def decode(shortuuid) when is_binary(shortuuid) and byte_size(shortuuid) == @short_size do
    with {:ok, number} <- decode_number(shortuuid),
         {:ok, uuid_binary} <- number_to_uuid_binary(number),
         {:ok, uuid} <- UUID.load(uuid_binary) do
      {:ok, uuid}
    else
      _ -> {:error, "Invalid input"}
    end
  end

  def decode(_), do: {:error, "Invalid input"}

  @spec decode!(String.t()) :: String.t()
  def decode!(input) do
    case decode(input) do
      {:ok, uuid} -> uuid
      {:error, message} -> raise ArgumentError, message: message
    end
  end

  @spec cast(term()) :: {:ok, String.t()} | :error
  def cast(<<_::binary-size(@short_size)>> = shortuuid) do
    case decode(shortuuid) do
      {:ok, _uuid} -> {:ok, shortuuid}
      {:error, _reason} -> :error
    end
  end

  def cast(uuid) when is_binary(uuid) do
    case UUID.cast(uuid) do
      {:ok, casted} ->
        case encode(casted) do
          {:ok, shortuuid} -> {:ok, shortuuid}
          {:error, _reason} -> :error
        end

      :error ->
        :error
    end
  end

  def cast(_), do: :error

  @spec load(binary()) :: {:ok, String.t()} | :error
  def load(uuid_binary) do
    case UUID.load(uuid_binary) do
      {:ok, uuid} ->
        case encode(uuid) do
          {:ok, shortuuid} -> {:ok, shortuuid}
          {:error, _reason} -> :error
        end

      :error ->
        :error
    end
  end

  @spec dump(binary()) :: {:ok, <<_::128>>} | :error
  def dump(uuid) when is_binary(uuid) and byte_size(uuid) == 36 do
    UUID.dump(uuid)
  end

  def dump(<<_::binary-size(@short_size)>> = shortuuid) do
    with {:ok, uuid} <- decode(shortuuid),
         {:ok, uuid_binary} <- UUID.dump(uuid) do
      {:ok, uuid_binary}
    else
      _ -> :error
    end
  end

  def dump(_), do: :error

  @spec dump!(binary()) :: <<_::128>>
  def dump!(input) do
    case dump(input) do
      {:ok, uuid_binary} ->
        uuid_binary

      :error ->
        raise ArgumentError, message: "cannot dump given UUID to binary: #{inspect(input)}"
    end
  end

  @spec generate() :: String.t()
  def generate do
    UUID.generate()
    |> encode!()
  end

  @spec autogenerate() :: String.t()
  def autogenerate, do: generate()

  defp to_uuid_binary(<<_::binary-size(@uuid_binary_size)>> = uuid_binary), do: {:ok, uuid_binary}

  defp to_uuid_binary(uuid) when is_binary(uuid) do
    UUID.dump(uuid)
  end

  defp to_uuid_binary(_), do: :error

  defp encode_digits(0, ""), do: ""
  defp encode_digits(0, acc), do: acc

  defp encode_digits(number, acc) when number > 0 do
    next = div(number, @alphabet_size)
    char = :binary.part(@alphabet, rem(number, @alphabet_size), 1)
    encode_digits(next, acc <> char)
  end

  defp pad_shortuuid(shortuuid) do
    if byte_size(shortuuid) >= @short_size do
      shortuuid
    else
      pad_shortuuid(shortuuid <> "2")
    end
  end

  defp decode_number(shortuuid) do
    shortuuid
    |> :binary.bin_to_list()
    |> Enum.reduce_while([], fn char, acc ->
      case Map.fetch(@index_by_char, char) do
        {:ok, index} -> {:cont, [index | acc]}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      :error ->
        {:error, :invalid_alphabet}

      reversed_digits ->
        value =
          Enum.reduce(reversed_digits, 0, fn digit, acc ->
            acc * @alphabet_size + digit
          end)

        {:ok, value}
    end
  end

  defp number_to_uuid_binary(number) when is_integer(number) and number >= 0 do
    uuid_binary =
      number
      |> :binary.encode_unsigned()
      |> left_pad_binary(@uuid_binary_size)

    if byte_size(uuid_binary) == @uuid_binary_size do
      {:ok, uuid_binary}
    else
      {:error, :invalid_binary_size}
    end
  end

  defp number_to_uuid_binary(_), do: {:error, :invalid_number}

  defp left_pad_binary(binary, size) when byte_size(binary) > size, do: binary
  defp left_pad_binary(binary, size) when byte_size(binary) == size, do: binary

  defp left_pad_binary(binary, size) do
    pad = :binary.copy(<<0>>, size - byte_size(binary))
    pad <> binary
  end
end
