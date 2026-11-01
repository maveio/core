defmodule MaveCore.AudioDescription.Wav do
  @moduledoc """
  Speech clips from text-to-speech, normalized to mono signed 16-bit
  little-endian PCM at `sample_rate/0` with leading and trailing silence trimmed.
  """

  import Bitwise

  @sample_rate 24_000

  def sample_rate, do: @sample_rate

  @doc """
  Decode RIFF/WAVE bytes (PCM 8/16/24/32-bit or 32-bit float, any channel count)
  to `{samples, sample_rate}`, where `samples` is mono s16le. Bytes without a RIFF
  header are taken as raw s16le mono at 24 kHz.
  """
  def decode(<<"RIFF", _size::little-32, "WAVE", chunks::binary>>) do
    with {:ok, format, data} <- read_chunks(chunks, nil) do
      {:ok, {downmix(data, format), format.sample_rate}}
    end
  end

  def decode(bytes) when is_binary(bytes) do
    even = byte_size(bytes) - rem(byte_size(bytes), 2)
    {:ok, {binary_part(bytes, 0, even), @sample_rate}}
  end

  defp read_chunks(<<"fmt ", size::little-32, body::binary-size(size), rest::binary>>, _format) do
    <<tag::little-16, channels::little-16, rate::little-32, _byte_rate::little-32,
      _align::little-16, bits::little-16, extra::binary>> = body

    tag =
      case {tag, extra} do
        {0xFFFE,
         <<_cb::little-16, _valid::little-16, _mask::little-32, sub::little-16, _::binary>>} ->
          sub

        {tag, _} ->
          tag
      end

    read_chunks(skip_pad(rest, size), %{
      tag: tag,
      channels: channels,
      sample_rate: rate,
      bits: bits
    })
  end

  defp read_chunks(<<"data", size::little-32, rest::binary>>, %{} = format) do
    # Streamed WAVs may carry 0 or 0xFFFFFFFF as size; use what is there.
    size = if size in [0, 0xFFFFFFFF] or size > byte_size(rest), do: byte_size(rest), else: size
    {:ok, format, binary_part(rest, 0, size)}
  end

  defp read_chunks(<<_id::binary-size(4), size::little-32, rest::binary>>, format)
       when byte_size(rest) >= size do
    read_chunks(skip_pad(binary_part(rest, size, byte_size(rest) - size), size), format)
  end

  defp read_chunks(_rest, _format), do: {:error, :invalid_wav}

  defp skip_pad(<<_pad, rest::binary>>, size) when rem(size, 2) == 1, do: rest
  defp skip_pad(rest, _size), do: rest

  defp downmix(data, %{tag: tag, channels: channels, bits: bits}) do
    bytes = div(bits, 8)
    frame = bytes * channels

    for <<frame_bytes::binary-size(^frame) <- data>>, into: <<>> do
      sum =
        for <<sample::binary-size(^bytes) <- frame_bytes>>, reduce: 0 do
          acc -> acc + read_sample(sample, tag, bits)
        end

      <<clamp(round(sum / channels))::little-signed-16>>
    end
  end

  defp read_sample(<<value::little-float-32>>, 3, 32), do: max(-1.0, min(1.0, value)) * 32_767
  defp read_sample(<<value>>, _tag, 8), do: (value - 128) <<< 8
  defp read_sample(<<value::little-signed-16>>, _tag, 16), do: value
  defp read_sample(<<value::little-signed-24>>, _tag, 24), do: value >>> 8
  defp read_sample(<<value::little-signed-32>>, _tag, 32), do: value >>> 16

  @doc "Linear-interpolation resample of s16le mono samples."
  def resample(samples, from_rate, to_rate \\ @sample_rate)
  def resample(samples, rate, rate), do: samples

  def resample(samples, from_rate, to_rate) do
    input = for <<s::little-signed-16 <- samples>>, do: s
    tuple = List.to_tuple(input)
    count = tuple_size(tuple)
    ratio = from_rate / to_rate
    length = floor(count / ratio)

    if length == 0 do
      <<>>
    else
      for i <- 0..(length - 1), into: <<>> do
        pos = i * ratio
        i0 = floor(pos)
        i1 = min(i0 + 1, count - 1)
        t = pos - i0
        <<round(elem(tuple, i0) * (1 - t) + elem(tuple, i1) * t)::little-signed-16>>
      end
    end
  end

  @doc "Trim leading and trailing near-silence, keeping a little padding."
  def trim_silence(samples, sample_rate \\ @sample_rate, threshold \\ 400, pad_seconds \\ 0.05) do
    count = div(byte_size(samples), 2)

    case first_loud(samples, threshold) do
      nil ->
        <<>>

      first ->
        last = last_loud(samples, count, threshold)
        pad = round(pad_seconds * sample_rate)
        from = max(0, first - pad)
        to = min(count, last + 1 + pad)
        binary_part(samples, from * 2, (to - from) * 2)
    end
  end

  defp first_loud(samples, threshold) do
    Enum.find_value(0..(div(byte_size(samples), 2) - 1)//1, fn i ->
      offset = i * 2
      <<_::binary-size(^offset), s::little-signed-16, _::binary>> = samples
      if abs(s) >= threshold, do: i
    end)
  end

  defp last_loud(samples, count, threshold) do
    Enum.find_value((count - 1)..0//-1, fn i ->
      offset = i * 2
      <<_::binary-size(^offset), s::little-signed-16, _::binary>> = samples
      if abs(s) >= threshold, do: i
    end)
  end

  @doc "Decode TTS output into a trimmed mono s16le clip at `sample_rate/0`."
  def clip(bytes) do
    with {:ok, {samples, rate}} <- decode(bytes) do
      {:ok, samples |> resample(rate, @sample_rate) |> trim_silence(@sample_rate)}
    end
  end

  @doc "Silence and clips laid out on one timeline, as s16le iodata."
  def render(placements, total_samples, load_clip) do
    {parts, position} =
      Enum.reduce(placements, {[], 0}, fn %{index: index, start: start, length: length},
                                          {parts, position} ->
        clip = load_clip.(index)
        clip = binary_part(clip, 0, min(byte_size(clip), length * 2))
        silence = silence(max(0, start - position))
        {[clip, silence | parts], max(position, start) + div(byte_size(clip), 2)}
      end)

    Enum.reverse([silence(max(0, total_samples - position)) | parts])
  end

  defp silence(0), do: <<>>
  defp silence(samples), do: :binary.copy(<<0, 0>>, samples)

  defp clamp(value), do: value |> max(-32_768) |> min(32_767)
end
