defmodule MaveCore.AudioDescription.Mix do
  @moduledoc """
  FFmpeg arguments that mix the video's own audio with the description track.

  The original audio fades to `duck_volume` (20%) under every description that
  plays over speech, with `fade` (0.3 s) ramps; descriptions in pauses leave it
  untouched. The result is a 48 kHz stereo MP3 as long as the original audio.
  """

  alias MaveCore.AudioDescription.Wav

  @duck_volume 0.2
  @fade_seconds 0.3
  @kbps 128
  @normalize "aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo"

  def duck_volume, do: @duck_volume
  def fade_seconds, do: @fade_seconds

  @doc "Gain expression for ffmpeg's `volume` filter: 1, fading to `duck_volume` in each interval."
  def duck_expression(ducks, duck_volume \\ @duck_volume, fade \\ @fade_seconds)
  def duck_expression([], _duck_volume, _fade), do: "1"

  def duck_expression(ducks, duck_volume, fade) do
    f = fixed(max(fade, 0.01))

    # Trapezoid per interval: 0 before start-fade, 1 from start to end, 0 after end+fade.
    ramps =
      Enum.map(ducks, fn %{start: start, end: stop} ->
        "clip(min((t-#{fixed(start - max(fade, 0.01))})/#{f},(#{fixed(stop + max(fade, 0.01))}-t)/#{f}),0,1)"
      end)

    max = Enum.reduce(tl(ramps), hd(ramps), fn ramp, acc -> "max(#{acc},#{ramp})" end)
    "1-#{fixed(1 - duck_volume)}*#{max}"
  end

  @doc """
  Arguments for the mix. `original` is the video's audio (`nil` when the video
  has none), `description` the raw s16le mono description track.
  """
  def ffmpeg_args(original, description, output, ducks, duration) do
    description_input = [
      "-f",
      "s16le",
      "-ar",
      Integer.to_string(Wav.sample_rate()),
      "-ac",
      "1",
      "-i",
      description
    ]

    {inputs, filter} =
      if original do
        {["-i", original | description_input],
         "[0:a]#{@normalize},volume='#{duck_expression(ducks)}':eval=frame[orig];" <>
           "[1:a]#{@normalize}[desc];" <>
           "[orig][desc]amix=inputs=2:duration=first:normalize=0,alimiter=limit=0.97[out]"}
      else
        # No original audio: the descriptions alone, padded to the video length.
        {description_input, "[0:a]#{@normalize}#{pad(duration)}[out]"}
      end

    ["-y", "-v", "error"] ++
      inputs ++
      [
        "-filter_complex",
        filter,
        "-map",
        "[out]",
        "-c:a",
        "libmp3lame",
        "-b:a",
        "#{@kbps}k",
        output
      ]
  end

  defp pad(duration) when is_number(duration) and duration > 0,
    do: ",apad=whole_dur=#{fixed(duration)}"

  defp pad(_duration), do: ""

  defp fixed(value), do: :erlang.float_to_binary(value * 1.0, decimals: 3)
end
