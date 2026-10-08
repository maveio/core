defmodule MaveCore.Flow.StepRegistryTest do
  use ExUnit.Case, async: true

  alias MaveCore.Flow.StepRegistry

  test "routes heavyweight media and transfer steps to flame executor" do
    assert StepRegistry.executor_for("asset.upload_original") == :flame
    assert StepRegistry.executor_for("media.transcode_video") == :flame
    assert StepRegistry.executor_for("media.package_hls_variant") == :inline
    assert StepRegistry.executor_for("media.package_hls_audio") == :inline
    assert StepRegistry.executor_for("media.transcode_audio") == :flame
    assert StepRegistry.executor_for("media.transcode_waveform") == :inline
    assert StepRegistry.executor_for("media.extract_frame") == :flame
    assert StepRegistry.executor_for("media.generate_segments") == :flame
    assert StepRegistry.executor_for("media.generate_storyboard") == :flame
  end

  test "keeps lightweight steps inline" do
    assert StepRegistry.executor_for("manifest.build") == :inline
    assert StepRegistry.executor_for("media.build_hls_master") == :inline
    assert StepRegistry.executor_for("source.resolve") == :inline
    assert StepRegistry.executor_for("ai.translate_subtitles") == :inline
    assert StepRegistry.executor_for("event.notify_webhook") == :inline
  end

  test "exposes options metadata for strict-capable steps" do
    step_types = StepRegistry.all()

    build_hls_master =
      Enum.find(step_types, fn step -> step["type"] == "media.build_hls_master" end)

    assert is_list(build_hls_master["options"])
    assert Enum.any?(build_hls_master["options"], fn option -> option["key"] == "strict" end)
  end
end
