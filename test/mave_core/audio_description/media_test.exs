defmodule MaveCore.AudioDescription.MediaTest do
  use ExUnit.Case, async: true

  alias MaveCore.AudioDescription.{Cues, Mix, Prompts, Wav}

  describe "Cues" do
    test "parses timestamps in several formats" do
      assert Cues.parse_timestamp("00:01:02.500") == 62.5
      assert Cues.parse_timestamp("01:02") == 62.0
      assert Cues.parse_timestamp("3,25") == 3.25
      assert Cues.parse_timestamp(4) == 4.0
      assert Cues.parse_timestamp("soon") == nil
      assert Cues.parse_timestamp(-1) == nil
    end

    test "normalizes cues: sorts, merges equal starts, repairs ends and clamps" do
      cues =
        Cues.normalize(
          [
            %{"start" => "00:00:04.000", "end" => "00:00:03.000", "text" => " A  door "},
            %{"start" => 1.0, "end" => 6.0, "text" => "Kitchen."},
            %{"start" => 1.02, "end" => 2.0, "text" => "Dishes."},
            %{"start" => 9.8, "end" => 12.0, "text" => "End."},
            %{"start" => 11.0, "end" => 12.0, "text" => "Past the end."},
            %{"start" => 2.0, "text" => ""}
          ],
          10
        )

      assert cues == [
               %{start: 1.0, end: 4.0, text: "Kitchen. Dishes."},
               %{start: 4.0, end: 5.0, text: "A door"},
               %{start: 9.8, end: 10.0, text: "End."}
             ]
    end

    test "writes a descriptions WebVTT and escapes markup" do
      vtt = Cues.to_vtt([%{start: 1.0, end: 2.5, text: "Tom & <Jerry>"}], "nl")

      assert vtt ==
               "WEBVTT\nKind: descriptions\nLanguage: nl\n\n1\n00:00:01.000 --> 00:00:02.500\nTom &amp; &lt;Jerry&gt;\n"
    end

    test "round-trips through JSON with the scene" do
      cues = [%{start: 1.0, end: 2.0, text: "a", scene: %{start: 0.0, end: 3.0}}]

      assert cues |> Cues.to_json() |> Jason.encode!() |> Jason.decode!() |> Cues.from_json() ==
               cues
    end
  end

  describe "Wav" do
    test "decodes 16-bit stereo WAV, downmixes and keeps the rate" do
      samples =
        <<1000::little-signed-16, 3000::little-signed-16, -200::little-signed-16,
          -400::little-signed-16>>

      {:ok, {mono, rate}} = Wav.decode(wav(samples, 2, 48_000, 16))

      assert rate == 48_000
      assert mono == <<2000::little-signed-16, -300::little-signed-16>>
    end

    test "decodes 32-bit float WAV" do
      {:ok, {mono, 24_000}} = Wav.decode(wav(<<0.5::little-float-32>>, 1, 24_000, 32, 3))
      assert mono == <<16_384::little-signed-16>>
    end

    test "treats bytes without a header as raw 24 kHz PCM" do
      assert Wav.decode(<<1, 0, 2, 0, 3>>) == {:ok, {<<1, 0, 2, 0>>, 24_000}}
    end

    test "resamples linearly" do
      input = for s <- [0, 100, 200, 300], into: <<>>, do: <<s::little-signed-16>>
      assert Wav.resample(input, 48_000, 24_000) == <<0::little-signed-16, 200::little-signed-16>>
    end

    test "trims near-silence and keeps padding" do
      quiet = :binary.copy(<<0, 0>>, 100)
      loud = :binary.copy(<<1000::little-signed-16>>, 10)
      trimmed = Wav.trim_silence(quiet <> loud <> quiet, 1000, 400, 0.005)

      assert byte_size(trimmed) == (10 + 5 + 5) * 2
      assert Wav.trim_silence(quiet) == <<>>
    end

    test "renders clips on a timeline with silence in between" do
      clip = <<7::little-signed-16, 7::little-signed-16>>

      rendered =
        [%{index: 0, start: 1, length: 2}, %{index: 1, start: 4, length: 2}]
        |> Wav.render(8, fn _ -> clip end)
        |> IO.iodata_to_binary()

      assert for(<<s::little-signed-16 <- rendered>>, do: s) == [0, 7, 7, 0, 7, 7, 0, 0]
    end
  end

  describe "Mix" do
    test "ducks with a trapezoid per interval" do
      assert Mix.duck_expression([]) == "1"

      assert Mix.duck_expression([%{start: 2.0, end: 4.0}, %{start: 6.0, end: 7.0}]) ==
               "1-0.800*max(clip(min((t-1.700)/0.300,(4.300-t)/0.300),0,1)," <>
                 "clip(min((t-5.700)/0.300,(7.300-t)/0.300),0,1))"
    end

    test "mixes the original audio with the description track" do
      args = Mix.ffmpeg_args("orig.mp3", "desc.pcm", "out.mp3", [%{start: 1.0, end: 2.0}], 10.0)

      assert [
               "-y",
               "-v",
               "error",
               "-i",
               "orig.mp3",
               "-f",
               "s16le",
               "-ar",
               "24000",
               "-ac",
               "1",
               "-i",
               "desc.pcm" | _
             ] =
               args

      filter = Enum.at(args, Enum.find_index(args, &(&1 == "-filter_complex")) + 1)
      assert filter =~ "volume='1-0.800*clip("
      assert filter =~ "amix=inputs=2:duration=first:normalize=0,alimiter=limit=0.97[out]"
      assert List.last(args) == "out.mp3"
    end

    test "pads the descriptions to the video length when there is no original audio" do
      args = Mix.ffmpeg_args(nil, "desc.pcm", "out.mp3", [], 12.5)
      refute "orig.mp3" in args
      assert Enum.any?(args, &(&1 =~ "apad=whole_dur=12.500"))
    end
  end

  describe "Prompts" do
    test "puts the duration and timing into the describer's instructions" do
      text = Prompts.describe_instruction(12.0, "Scenes ...")
      assert text =~ "The video is 12.000 seconds long"
      assert String.ends_with?(text, "Scenes ...")
      refute text =~ "\n\n"
    end

    test "builds the translation request with time slots" do
      {instruction, input} =
        Prompts.translation_request([%{start: 1.0, end: 2.26, text: "A door opens."}], "nl")

      assert instruction =~ "into Dutch (nl)"
      assert input == [%{"i" => 0, "seconds" => 1.3, "text" => "A door opens."}]
    end

    test "requires exactly one translation per cue" do
      assert Prompts.check_translations([" Een deur. "], 1) == {:ok, ["Een deur."]}
      assert {:error, _} = Prompts.check_translations(["a", ""], 2)
      assert {:error, _} = Prompts.check_translations(["a"], 2)
    end
  end

  defp wav(data, channels, rate, bits, tag \\ 1) do
    block = channels * div(bits, 8)

    fmt =
      <<tag::little-16, channels::little-16, rate::little-32, rate * block::little-32,
        block::little-16, bits::little-16>>

    body =
      <<"WAVE", "fmt ", byte_size(fmt)::little-32, fmt::binary, "data",
        byte_size(data)::little-32, data::binary>>

    <<"RIFF", byte_size(body)::little-32, body::binary>>
  end
end
