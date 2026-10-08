defmodule MaveCore.Media.Signature do
  @moduledoc """
  Lightweight media signature checks for uploaded originals.
  """

  @max_probe_bytes 1_024
  @audio_output_probe_bytes 65_536
  @ts_packet_size 188
  @m2ts_packet_size 192

  @safe_audio_formats "aac,aiff,amr,flac,matroska,webm,mov,mp3,ogg,wav"
  @safe_image_formats "image2,jpeg_pipe,png_pipe,webp_pipe,mov"

  def audio_formats, do: @safe_audio_formats
  def image_formats, do: @safe_image_formats

  def validate_image(<<0xFF, 0xD8, 0xFF, _rest::binary>>), do: :ok
  def validate_image(<<0x89, "PNG\r\n", 0x1A, "\n", _rest::binary>>), do: :ok
  def validate_image(<<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>), do: :ok

  def validate_image(<<_size::binary-size(4), "ftyp", brand::binary-size(4), _rest::binary>>)
      when brand in ["avif", "avis"], do: :ok

  def validate_image(_bytes), do: {:error, :unsupported_image_signature}

  def validate_audio(bytes) when is_binary(bytes) do
    if audio?(bytes), do: :ok, else: {:error, :unsupported_audio_signature}
  end

  def validate_audio(_bytes), do: {:error, :unsupported_audio_signature}

  import Bitwise

  @spec audio_or_video?(binary()) :: boolean()
  def audio_or_video?(bytes) when is_binary(bytes) do
    video?(bytes) or audio?(bytes)
  end

  def audio_or_video?(_), do: false

  @spec validate_audio_or_video(binary()) :: :ok | {:error, :unsupported_media_signature}
  def validate_audio_or_video(bytes) when is_binary(bytes) do
    if audio_or_video?(bytes), do: :ok, else: {:error, :unsupported_media_signature}
  end

  def validate_audio_or_video(_), do: {:error, :unsupported_media_signature}

  @spec probe_bytes_limit() :: pos_integer()
  def probe_bytes_limit, do: @max_probe_bytes

  @spec audio_output_probe_bytes_limit() :: pos_integer()
  def audio_output_probe_bytes_limit, do: @audio_output_probe_bytes

  @spec validate_audio_output(binary(), String.t()) ::
          :ok | {:error, :missing_audio_frames | :unsupported_media_signature}
  def validate_audio_output(bytes, "mp3") when is_binary(bytes) do
    if consecutive_mpeg_audio_frames?(bytes),
      do: :ok,
      else: {:error, :missing_audio_frames}
  end

  def validate_audio_output(bytes, _container) when is_binary(bytes) do
    if audio?(bytes), do: :ok, else: {:error, :unsupported_media_signature}
  end

  def validate_audio_output(_bytes, _container),
    do: {:error, :unsupported_media_signature}

  @spec validate_audio_or_video_file(Path.t()) ::
          :ok | {:error, :unsupported_media_signature | {:file_read_failed, term()}}
  # sobelow_skip ["Traversal.FileModule"]
  def validate_audio_or_video_file(path) when is_binary(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        result =
          case IO.binread(file, @max_probe_bytes) do
            bytes when is_binary(bytes) -> validate_audio_or_video(bytes)
            _ -> {:error, :unsupported_media_signature}
          end

        File.close(file)
        result

      {:error, reason} ->
        {:error, {:file_read_failed, reason}}
    end
  end

  def validate_audio_or_video_file(_), do: {:error, :unsupported_media_signature}

  defp video?(<<0x1A, 0x45, 0xDF, 0xA3, _rest::binary>>), do: true
  defp video?(<<"FLV", _rest::binary>>), do: true
  defp video?(<<"RIFF", _size::binary-size(4), "AVI ", _rest::binary>>), do: true
  defp video?(<<0x00, 0x00, 0x01, marker, _rest::binary>>) when marker in [0xBA, 0xB3], do: true
  defp video?(bytes) when is_binary(bytes), do: iso_base_media?(bytes) or transport_stream?(bytes)

  defp audio?(<<"ID3", _rest::binary>>), do: true
  defp audio?(<<0xFF, second, _rest::binary>>) when second in 0xE0..0xFF, do: true
  defp audio?(<<"OggS", _rest::binary>>), do: true
  defp audio?(<<"fLaC", _rest::binary>>), do: true
  defp audio?(<<"RIFF", _size::binary-size(4), "WAVE", _rest::binary>>), do: true

  defp audio?(<<"FORM", _size::binary-size(4), form, _rest::binary>>)
       when form in ["AIFF", "AIFC"], do: true

  defp audio?(<<"#!AMR", _rest::binary>>), do: true
  defp audio?(bytes) when is_binary(bytes), do: iso_base_media?(bytes)

  defp consecutive_mpeg_audio_frames?(bytes) do
    bytes
    |> strip_id3v2_tag()
    |> find_consecutive_mpeg_audio_frames(0)
  end

  defp strip_id3v2_tag(
         <<"ID3", _version_major, _version_revision, flags, size_1, size_2, size_3, size_4,
           rest::binary>>
       )
       when size_1 < 128 and size_2 < 128 and size_3 < 128 and size_4 < 128 do
    tag_size =
      (size_1 <<< 21) + (size_2 <<< 14) + (size_3 <<< 7) + size_4 +
        if((flags &&& 0x10) == 0x10, do: 10, else: 0)

    if byte_size(rest) >= tag_size do
      binary_part(rest, tag_size, byte_size(rest) - tag_size)
    else
      <<>>
    end
  end

  defp strip_id3v2_tag(bytes), do: bytes

  defp find_consecutive_mpeg_audio_frames(bytes, offset) when offset + 8 <= byte_size(bytes) do
    case mpeg_audio_frame_size(bytes, offset) do
      {:ok, frame_size} ->
        next_offset = offset + frame_size

        case mpeg_audio_frame_size(bytes, next_offset) do
          {:ok, _next_frame_size} -> true
          :error -> find_consecutive_mpeg_audio_frames(bytes, offset + 1)
        end

      :error ->
        find_consecutive_mpeg_audio_frames(bytes, offset + 1)
    end
  end

  defp find_consecutive_mpeg_audio_frames(_bytes, _offset), do: false

  defp mpeg_audio_frame_size(bytes, offset) when offset + 4 <= byte_size(bytes) do
    header = bytes |> binary_part(offset, 4) |> :binary.decode_unsigned()
    version = header >>> 19 &&& 0x3
    layer = header >>> 17 &&& 0x3
    bitrate_index = header >>> 12 &&& 0xF
    sample_rate_index = header >>> 10 &&& 0x3
    padding = header >>> 9 &&& 0x1

    with true <- (header &&& 0xFFE00000) == 0xFFE00000,
         true <- version != 0x1,
         true <- layer != 0x0,
         true <- bitrate_index not in [0x0, 0xF],
         true <- sample_rate_index != 0x3,
         bitrate when is_integer(bitrate) <- mpeg_audio_bitrate(version, layer, bitrate_index),
         sample_rate when is_integer(sample_rate) <-
           mpeg_audio_sample_rate(version, sample_rate_index) do
      {:ok, mpeg_audio_frame_size(version, layer, bitrate, sample_rate, padding)}
    else
      _other -> :error
    end
  end

  defp mpeg_audio_frame_size(_bytes, _offset), do: :error

  defp mpeg_audio_frame_size(_version, 0x3, bitrate, sample_rate, padding),
    do: div(12 * bitrate, sample_rate) * 4 + padding * 4

  defp mpeg_audio_frame_size(0x3, _layer, bitrate, sample_rate, padding),
    do: div(144 * bitrate, sample_rate) + padding

  defp mpeg_audio_frame_size(_version, 0x1, bitrate, sample_rate, padding),
    do: div(72 * bitrate, sample_rate) + padding

  defp mpeg_audio_frame_size(_version, _layer, bitrate, sample_rate, padding),
    do: div(144 * bitrate, sample_rate) + padding

  defp mpeg_audio_bitrate(0x3, 0x3, index),
    do: bitrate_at({32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448}, index)

  defp mpeg_audio_bitrate(0x3, 0x2, index),
    do: bitrate_at({32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384}, index)

  defp mpeg_audio_bitrate(0x3, 0x1, index),
    do: bitrate_at({32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320}, index)

  defp mpeg_audio_bitrate(_version, 0x3, index),
    do: bitrate_at({32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256}, index)

  defp mpeg_audio_bitrate(_version, _layer, index),
    do: bitrate_at({8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160}, index)

  defp bitrate_at(values, index), do: elem(values, index - 1) * 1_000

  defp mpeg_audio_sample_rate(0x3, index), do: elem({44_100, 48_000, 32_000}, index)
  defp mpeg_audio_sample_rate(0x2, index), do: elem({22_050, 24_000, 16_000}, index)
  defp mpeg_audio_sample_rate(0x0, index), do: elem({11_025, 12_000, 8_000}, index)

  defp iso_base_media?(bytes) when byte_size(bytes) >= 12 do
    binary_part(bytes, 4, 4) == "ftyp"
  end

  defp iso_base_media?(_), do: false

  defp transport_stream?(bytes) do
    transport_packets?(bytes, 0, @ts_packet_size) or
      transport_packets?(bytes, 4, @m2ts_packet_size)
  end

  # M2TS prefixes each TS packet with a four-byte arrival timestamp.
  defp transport_packets?(bytes, offset, packet_size) do
    cond do
      byte_size(bytes) > offset + packet_size * 2 ->
        packet_byte?(bytes, offset) and packet_byte?(bytes, offset + packet_size) and
          packet_byte?(bytes, offset + packet_size * 2)

      byte_size(bytes) > offset + packet_size ->
        packet_byte?(bytes, offset) and packet_byte?(bytes, offset + packet_size)

      true ->
        false
    end
  end

  defp packet_byte?(bytes, offset) do
    offset < byte_size(bytes) and :binary.at(bytes, offset) == 0x47
  end
end
