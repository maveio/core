defmodule MaveCore.Media.SignatureTest do
  use ExUnit.Case, async: true

  alias MaveCore.Media.Signature

  test "custom media accepts ordinary signatures but not playlists or active documents" do
    for image <- [
          <<0xFF, 0xD8, 0xFF>>,
          <<0x89, "PNG\r\n", 0x1A, "\n">>,
          <<"RIFF", 0::32, "WEBP">>,
          <<0, 0, 0, 24, "ftypavif", 0::128>>
        ] do
      assert :ok = Signature.validate_image(image)
    end

    for audio <- [
          <<"ID3", 0::128>>,
          <<0xFF, 0xF1, 0::128>>,
          <<"OggS", 0::128>>,
          <<"RIFF", 0::32, "WAVE">>,
          <<0, 0, 0, 24, "ftypM4A ", 0::128>>
        ] do
      assert :ok = Signature.validate_audio(audio)
    end

    for bytes <- [
          "#EXTM3U\nhttps://127.0.0.1/private",
          "ffconcat version 1.0\nfile '/private'",
          "<MPD></MPD>",
          "<svg></svg>",
          "<html></html>"
        ] do
      assert {:error, :unsupported_image_signature} = Signature.validate_image(bytes)
      assert {:error, :unsupported_audio_signature} = Signature.validate_audio(bytes)
    end
  end

  test "accepts AIFF and AIFC form types and rejects truncated or unrelated forms" do
    for form <- ["AIFF", "AIFC"] do
      assert :ok = Signature.validate_audio(<<"FORM", 4::32, form::binary>>)
    end

    for form <- ["", "A", "AIF", "ILBM", "AIFX"] do
      assert {:error, :unsupported_audio_signature} =
               Signature.validate_audio(<<"FORM", 4::32, form::binary>>)
    end
  end

  test "accepts common video and audio signatures" do
    assert Signature.audio_or_video?(<<0, 0, 0, 24, "ftyp", "isom", 0::128>>)
    assert Signature.audio_or_video?(<<0x1A, 0x45, 0xDF, 0xA3, 0::128>>)
    assert Signature.audio_or_video?(<<"RIFF", 0::32, "AVI ", 0::128>>)
    assert Signature.audio_or_video?(<<"ID3", 0::128>>)
    assert Signature.audio_or_video?(<<0xFF, 0xFB, 0::128>>)
    assert Signature.audio_or_video?(<<"OggS", 0::128>>)
    assert Signature.audio_or_video?(<<"fLaC", 0::128>>)
    assert Signature.audio_or_video?(<<"RIFF", 0::32, "WAVE", 0::128>>)
  end

  test "rejects obvious non-media content" do
    refute Signature.audio_or_video?(~s({"not":"media"}))
    refute Signature.audio_or_video?("<script>alert('nope')</script>")

    assert {:error, :unsupported_media_signature} =
             Signature.validate_audio_or_video("plain text")
  end

  test "recognizes ASF for both Windows Media audio and video using the complete header GUID" do
    header =
      <<0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE,
        0x6C>>

    assert :ok = Signature.validate_audio_or_video(header <> <<0::112>>)
    assert :ok = Signature.validate_audio(header <> <<0::112>>)

    for length <- 0..15 do
      assert {:error, :unsupported_media_signature} =
               Signature.validate_audio_or_video(binary_part(header, 0, length))
    end

    assert {:error, :unsupported_media_signature} =
             Signature.validate_audio_or_video(binary_part(header, 0, 15) <> <<0>>)
  end

  test "accepts TS and timestamp-prefixed M2TS packets" do
    ts_packet = <<0x47>> <> :binary.copy(<<0>>, 187)
    m2ts_packet = <<0, 0, 0, 1>> <> ts_packet

    for packet <- [ts_packet, m2ts_packet] do
      assert :ok = Signature.validate_audio_or_video(:binary.copy(packet, 2))
      assert :ok = Signature.validate_audio_or_video(:binary.copy(packet, 3))

      prefix = binary_part(:binary.copy(packet, 6), 0, Signature.probe_bytes_limit())
      assert :ok = Signature.validate_audio_or_video(prefix)
    end
  end

  test "rejects incomplete or inconsistent transport stream signatures" do
    ts_packet = <<0x47>> <> :binary.copy(<<0>>, 187)
    m2ts_packet = <<0, 0, 0, 1>> <> ts_packet

    for packet <- [ts_packet, m2ts_packet] do
      for bytes <- [
            packet,
            packet <> :binary.copy(<<0>>, byte_size(packet)),
            packet <> packet <> :binary.copy(<<0>>, byte_size(packet))
          ] do
        assert {:error, :unsupported_media_signature} = Signature.validate_audio_or_video(bytes)
      end
    end

    assert {:error, :unsupported_media_signature} =
             Signature.validate_audio_or_video(<<0, 0, 0, 1, 0x47>>)
  end

  test "requires consecutive MPEG frames for transcoded MP3 output" do
    frame = <<0xFF, 0xFB, 0x90, 0x64>> <> :binary.copy(<<0>>, 413)
    id3_header = <<"ID3", 4, 0, 0, 0, 0, 0, 34>> <> :binary.copy(<<0>>, 34)

    assert :ok = Signature.validate_audio_output(id3_header <> frame <> frame, "mp3")

    assert {:error, :missing_audio_frames} =
             Signature.validate_audio_output(id3_header, "mp3")

    assert {:error, :missing_audio_frames} =
             Signature.validate_audio_output(id3_header <> frame, "mp3")
  end
end
