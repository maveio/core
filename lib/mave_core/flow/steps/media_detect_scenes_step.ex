defmodule MaveCore.Flow.Steps.MediaDetectScenesStep do
  @moduledoc """
  Detects camera cuts with FFmpeg (`scdet`), groups them into scenes of at least
  3 s and extracts labelled 360p stills (one per ~3 s per shot) for the
  description model. One decode of the canonical source does both.

  Stores the private `audio_description/scenes.json` and `audio_description/stills/*`.
  """
  @behaviour MaveCore.Flow.Step

  alias MaveCore.AudioDescription
  alias MaveCore.AudioDescription.Timeline
  alias MaveCore.Flow.Steps.AudioDescriptionSupport, as: AD
  alias MaveCore.Flow.Steps.Support, as: StepSupport

  @step_type "media.detect_scenes"
  # Cuts closer together than this (or to the start) are detection noise.
  @min_shot_seconds 0.5
  @scdet_threshold 10

  @impl true
  def run(step, context) do
    ctx = AD.run_context(step, context)
    duration_ms = StepSupport.inspect_duration_ms(ctx.outputs)

    cond do
      AD.check_requested(ctx) != :ok ->
        {:skip, reason} = AD.check_requested(ctx)
        {:ok, AD.skipped(@step_type, ctx, reason), []}

      StepSupport.inspect_reports_no_video?(ctx.outputs) ->
        {:ok, AD.skipped(@step_type, ctx, "no_video"), []}

      not (is_number(duration_ms) and duration_ms > 0) ->
        {:ok, AD.skipped(@step_type, ctx, "unknown_duration"), []}

      duration_ms / 1000 > AudioDescription.max_seconds() ->
        {:ok,
         AD.skipped(@step_type, ctx, "video_too_long", %{
           "video_duration_seconds" => Float.round(duration_ms / 1000, 3),
           "max_duration_seconds" => AudioDescription.max_seconds()
         }), []}

      true ->
        detect(ctx, context, duration_ms / 1000)
    end
  end

  defp detect(ctx, context, duration) do
    source = Map.get(ctx.outputs, "source", %{})
    source_url = source["source_url"] || ctx.run_input["input_url"] || ctx.run_input["source_url"]
    fps = if duration > 180, do: 1, else: 2

    progress =
      StepSupport.ffmpeg_progress(context[:progress_reporter], %{
        stage: "detect_scenes",
        step_id: ctx.step_id,
        total_ms: round(duration * 1000)
      })

    result =
      StepSupport.with_temp_dir("detect_scenes", fn dir ->
        with {:ok, scd_path} <- StepSupport.tmp_file_path(dir, "scd", "txt"),
             {:ok, null_path} <- StepSupport.tmp_file_path(dir, "cuts", "null"),
             {:ok, frames_dir} <- StepSupport.tmp_file_path(dir, "frames"),
             :ok <- StepSupport.mkdir_tmp_dir(frames_dir),
             {:ok, _, _} <-
               StepSupport.run_ffmpeg_with_storage_fallback(
                 dir,
                 ctx.run_input,
                 source_url,
                 ctx.outputs,
                 &{:ok, ffmpeg_args(&1, scd_path, null_path, frames_dir, fps)},
                 progress: progress
               ),
             {:ok, scd} <- StepSupport.read_tmp_file(scd_path) do
          cuts = parse_cuts(scd)
          shots = Timeline.shots_from_cuts(cuts, duration)
          scenes = Timeline.scenes_from_shots(shots)
          stills = Timeline.plan_stills(scenes, duration, 3, shots)
          store(ctx, frames_dir, fps, duration, cuts, shots, scenes, stills)
        end
      end)

    case result do
      {:ok, output, artifacts} -> {:ok, output, artifacts}
      {:error, reason} -> AD.failure(@step_type, ctx, reason)
    end
  end

  defp store(ctx, frames_dir, fps, duration, cuts, shots, scenes, stills) do
    stills
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {still, index}, {:ok, acc} ->
      key = AD.work_key(ctx, "stills/#{pad(index)}.jpg")

      with {:ok, image} <- read_frame(frames_dir, round(still.time * fps) + 1),
           {:ok, _} <- AD.put_private(ctx, key, image, "image/jpeg") do
        {:cont, {:ok, [Map.put(still, :key, key) | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, stored} ->
        scenes_key = AD.work_key(ctx, "scenes.json")

        document = %{
          "duration" => duration,
          "cuts" => cuts,
          "shots" => Enum.map(shots, &interval_json/1),
          "scenes" => Enum.map(scenes, &interval_json/1),
          "stills" =>
            stored
            |> Enum.reverse()
            |> Enum.map(&%{"scene" => &1.scene, "time" => &1.time, "key" => &1.key})
        }

        with {:ok, _} <- AD.put_json(ctx, scenes_key, document) do
          {:ok,
           %{
             "status" => "ok",
             "step_type" => @step_type,
             "step_id" => ctx.step_id,
             "scenes_key" => scenes_key,
             "duration" => duration,
             "cut_count" => length(cuts),
             "scene_count" => length(scenes),
             "still_count" => length(stored)
           }, []}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The fps filter emits frame n (1-based) at (n - 1) / fps; a still near the very end
  # may round past the last frame.
  defp read_frame(frames_dir, number) when number >= 1 do
    with {:ok, path} <- StepSupport.tmp_file_path(frames_dir, pad(number), "jpg") do
      case StepSupport.read_tmp_file(path) do
        {:ok, image} -> {:ok, image}
        {:error, _reason} when number > 1 -> read_frame(frames_dir, number - 1)
        {:error, reason} -> {:error, {:missing_still, reason}}
      end
    end
  end

  defp ffmpeg_args(source, scd_path, null_path, frames_dir, fps) do
    filter =
      "[0:v]split=2[a][b];" <>
        "[a]scale=320:-2,scdet=threshold=#{@scdet_threshold}," <>
        "metadata=print:key=lavfi.scd.time:file='#{escape_filter_path(scd_path)}'[cuts];" <>
        "[b]fps=#{fps},scale=-2:360[stills]"

    [
      "-y",
      "-v",
      "error",
      "-i",
      source,
      "-an",
      "-sn",
      "-filter_complex",
      filter,
      "-map",
      "[cuts]",
      "-f",
      "null",
      # Keep an explicit output path so the sandbox grants this job's directory.
      null_path,
      "-map",
      "[stills]",
      "-q:v",
      "5",
      Path.join(frames_dir, "%05d.jpg")
    ]
  end

  @doc false
  def parse_cuts(body) do
    ~r/lavfi\.scd\.time=([0-9.]+)/
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.flat_map(fn [value] ->
      case Float.parse(value) do
        {time, _} -> [time]
        :error -> []
      end
    end)
    |> Enum.sort()
    |> Enum.reduce([], fn time, kept ->
      previous = List.first(kept) || 0.0
      if time - previous >= @min_shot_seconds, do: [time | kept], else: kept
    end)
    |> Enum.reverse()
    |> Enum.map(&Timeline.round3/1)
  end

  defp interval_json(%{start: start, end: stop}), do: %{"start" => start, "end" => stop}

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(5, "0")

  defp escape_filter_path(path),
    do: path |> String.replace("\\", "\\\\") |> String.replace("'", "'\\''")
end
