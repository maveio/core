defmodule MaveCore.Flow.Steps.MediaTranscodeWaveformStep do
  @moduledoc """
  Compatibility handler for immutable flows containing the retired waveform-video step.

  Audio playback uses published audio tracks and `media.generate_audio_peaks`.
  This handler produces no media and performs no encoder or storage work.
  """
  @behaviour MaveCore.Flow.Step

  @impl true
  def run(step, _context) do
    {:ok,
     %{
       "status" => "skipped",
       "step_type" => "media.transcode_waveform",
       "step_id" => Map.get(step, "id", "transcode_waveform"),
       "reason" => "waveform video generation retired"
     }, []}
  end
end
