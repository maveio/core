defmodule MaveCore.Flow.Steps.MediaTranscodeWaveformStepTest do
  use ExUnit.Case, async: true
  @moduletag :audio_pipeline

  alias MaveCore.Flow.{Definition, Presets, StepRegistry}
  alias MaveCore.Flow.Steps.MediaTranscodeWaveformStep

  test "retired generation skips old immutable flow steps without requiring a source" do
    assert StepRegistry.executor_for("media.transcode_waveform") == :inline

    assert {:ok, %{"status" => "skipped", "step_id" => "old_waveform"}, []} =
             MediaTranscodeWaveformStep.run(
               %{"id" => "old_waveform", "params" => %{"strict" => true}},
               %{run_input: %{"media_transcode_waveform_mode" => "ffmpeg"}}
             )
  end

  test "all publishing presets contain real peaks and no waveform-video branches" do
    for slug <- ~w(publish_default publish_local publish_remote publish_remote_local) do
      assert {:ok, preset} = Presets.fetch(slug)
      definition = preset["definition"]
      assert :ok = Definition.validate(definition)
      steps = definition["steps"]
      assert Enum.any?(steps, &(&1["type"] == "media.generate_audio_peaks"))
      assert Enum.any?(steps, &(&1["type"] == "media.transcode_audio"))
      refute Enum.any?(steps, &(&1["type"] == "media.transcode_waveform"))
      refute Enum.any?(steps, &String.starts_with?(&1["id"], "hls_waveform"))

      refute Enum.any?(
               steps,
               &(&1["type"] == "media.extract_frame" and get_in(&1, ["params", "audio_only"]))
             )
    end
  end
end
