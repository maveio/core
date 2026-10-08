defmodule MaveCore.Flow.Steps.MediaGenerateAudioPeaksStepTest do
  use ExUnit.Case, async: false

  alias MaveCore.Flow.{ManifestBuilder, Presets, StepRegistry}
  alias MaveCore.Flow.Steps.MediaGenerateAudioPeaksStep, as: Peaks
  alias MaveCore.TestSupport.FlowStorageAdapterStub, as: Storage

  defmodule BoosterStub do
    def encode_to_file(url, path, options) do
      if !String.ends_with?(URI.parse(url).path, "/audio.wav"), do: raise("wrong audio source")
      if options[:operation] != "audio_peaks", do: raise("wrong operation")

      File.write!(
        path,
        "lavfi.astats.Overall.Peak_level=-inf\nlavfi.astats.Overall.Peak_level=-20.0\n"
      )

      {:ok, %{elapsed_ms: 1}}
    end
  end

  test "keeps silence, quiet passages, and full-scale peaks distinct" do
    assert {:ok, parsed} =
             Peaks.parse_peaks("""
             lavfi.astats.Overall.Peak_level=-inf
             lavfi.astats.Overall.Peak_level=-20.000000
             lavfi.astats.Overall.Peak_level=0.000000
             """)

    assert parsed == [0.0, 0.1, 1.0]
    assert {:error, :invalid_audio_peaks} = Peaks.parse_peaks("invalid")
  end

  test "keeps FLAME as default and remains optional background work" do
    assert StepRegistry.executor_for("media.generate_audio_peaks") == :flame

    for slug <- ["publish_default", "publish_local", "publish_remote", "publish_remote_local"] do
      {:ok, preset} = Presets.fetch(slug)
      steps = preset["definition"]["steps"]

      assert %{"required" => false, "lane" => "background"} =
               Enum.find(steps, &(&1["id"] == "audio_peaks"))

      refute "audio_peaks" in Enum.find(steps, &(&1["id"] == "manifest"))["depends_on"]
    end
  end

  test "skips audio and video sources without audio" do
    for probe <- [
          %{"has_video" => true, "has_audio" => false},
          %{"has_video" => false, "has_audio" => false}
        ] do
      assert {:ok, %{"status" => "skipped"}, []} =
               Peaks.run(%{}, %{dependency_outputs: %{"inspect_media" => probe}})
    end
  end

  test "does not analyze unvalidated audio from compatibility copy mode" do
    assert {:ok, %{"status" => "unavailable"}, []} =
             Peaks.run(%{}, %{
               dependency_outputs: %{
                 "inspect_media" => %{"has_audio" => true},
                 "transcode_audio" => %{"mode" => "copy"}
               }
             })
  end

  test "extracts and stores a real stereo waveform and exposes it in the manifest" do
    old_booster = Application.get_env(:mave_core, :encoding_booster_adapter)
    Application.put_env(:mave_core, :encoding_booster_adapter, BoosterStub)
    old = Application.get_env(:mave_core, :flow_storage_adapter)
    old_direct = Application.get_env(:mave_core, :flow_direct_storage_ffmpeg_input)
    Application.put_env(:mave_core, :flow_storage_adapter, Storage)
    Application.put_env(:mave_core, :flow_direct_storage_ffmpeg_input, false)

    on_exit(fn ->
      if old_booster,
        do: Application.put_env(:mave_core, :encoding_booster_adapter, old_booster),
        else: Application.delete_env(:mave_core, :encoding_booster_adapter)

      Application.put_env(:mave_core, :flow_storage_adapter, old)
      Application.put_env(:mave_core, :flow_direct_storage_ffmpeg_input, old_direct)
    end)

    Storage.reset!()

    # Two seconds: silence followed by opposite-phase stereo at half scale.
    pcm =
      for i <- 0..95_999, into: <<>> do
        sample =
          if i < 48_000, do: 0, else: round(16_000 * :math.sin(i * 2 * :math.pi() * 440 / 48_000))

        <<sample::little-signed-16, -sample::little-signed-16>>
      end

    size = byte_size(pcm)

    wav =
      <<"RIFF", size + 36::little-32, "WAVEfmt ", 16::little-32, 1::little-16, 2::little-16,
        48_000::little-32, 192_000::little-32, 4::little-16, 16::little-16, "data",
        size::little-32, pcm::binary>>

    input = %{
      "space_hash" => "ubg50",
      "embed_hash" => "LeDE9v86ye",
      "version" => 2,
      "input_url" => "https://example.com/audio.wav",
      "filetype" => "wav"
    }

    key = "LeDE9v86ye/v2/audio.wav"
    Storage.put_public("space-ubg50", key, wav, "audio/wav", nil)

    outputs = %{
      "transcode_audio" => %{
        "status" => "ok",
        "bucket" => "space-ubg50",
        "key" => key,
        "uri" => "s3://space-ubg50/#{key}",
        "audio_track" => %{"filename" => "audio.wav"}
      },
      "inspect_media" => %{
        "step_type" => "media.inspect",
        "has_audio" => true,
        "has_video" => false,
        "duration" => 2.0
      }
    }

    # A video upload uses the extracted audio track, never the original video input.
    for has_video <- [false, true] do
      outputs = put_in(outputs, ["inspect_media", "has_video"], has_video)

      assert {:ok, output, [artifact]} =
               Peaks.run(%{"id" => "audio_peaks"}, %{
                 run_input: input,
                 dependency_outputs: outputs
               })

      waveform = output["waveform"]
      assert waveform["audio_track"] == "audio.wav"
      assert length(waveform["peaks"]) in 510..512
      assert Enum.all?(Enum.take(waveform["peaks"], 250), &(&1 == 0.0))
      assert Enum.all?(Enum.drop(waveform["peaks"], 260), &(&1 > 0.45 and &1 < 0.51))
      assert artifact.uri == "s3://space-ubg50/LeDE9v86ye/v2/audio_peaks.json"
      assert {:ok, json} = Storage.get("space-ubg50", "LeDE9v86ye/v2/audio_peaks.json", nil)
      assert Jason.decode!(json) == waveform

      assert {:ok, build} =
               ManifestBuilder.build(%{
                 run_input: Map.delete(input, "source_body"),
                 dependency_outputs: Map.put(outputs, "audio_peaks", output)
               })

      assert build["manifest"]["waveform"] == waveform

      assert {:ok, %{"mode" => "encoding_booster", "waveform" => boosted}, [_]} =
               Peaks.run(%{"id" => "audio_peaks"}, %{
                 run_input: input,
                 dependency_outputs: outputs,
                 encoding_booster_dispatch: :direct
               })

      assert boosted["peaks"] == [0.0, 0.1]
      assert boosted["audio_track"] == "audio.wav"
    end
  end
end
