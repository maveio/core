defmodule MaveCore.Flow.Plugins.VmafQualityCheck do
  @moduledoc """
  Measures how close an H.264 rendition looks to the original with VMAF.

  This is the reference step plugin: everything Core knows about the step comes
  from `contract/0`, `placements/1` and `availability/0`. It offers one check
  per H.264 rendition of a flow. A check runs in the background after its
  rendition exists, scores it against the original and records the result on
  the step, without ever failing the run.

  VMAF needs an FFmpeg build with the `libvmaf` filter. Without it the step is
  shown as unavailable.
  """
  @behaviour MaveCore.Flow.Step
  @behaviour MaveCore.Flow.StepPlugin

  alias MaveCore.Flow.Steps.Support, as: StepSupport

  @type_name "quality.vmaf"
  @ladder_type "media.transcode_h264_ladder"
  @model "vmaf_v0.6.1"
  @default_threshold 80
  @default_sample_every 5
  @default_max_duration 300
  # The default VMAF model is trained for viewing at 1080p.
  @max_width 1920
  @max_height 1080

  @impl MaveCore.Flow.StepPlugin
  def contract do
    %{
      type: @type_name,
      name: "VMAF Quality Check",
      category: "quality",
      stage: "quality",
      description:
        "Scores a rendition against the original with VMAF, from 0 to 100. Higher is closer to the original.",
      executor: :flame,
      dependencies: :all,
      inputs: [
        %{"key" => "reference", "label" => "Original video", "accepts" => ["source.resolve"]},
        %{"key" => "rendition", "label" => "Rendition to check", "accepts" => [@ladder_type]}
      ],
      outputs: [%{"key" => "vmaf", "label" => "VMAF score"}],
      options: [
        %{
          "key" => "threshold",
          "type" => "integer",
          "label" => "Target score",
          "description" =>
            "Results below this score are marked as below target. Around 93 is hard to tell apart from the original.",
          "default" => @default_threshold,
          "min" => 0,
          "max" => 100,
          "editable" => true
        },
        %{
          "key" => "sample_every",
          "type" => "integer",
          "label" => "Check every Nth frame",
          "description" => "Higher values finish sooner and are a little less precise.",
          "default" => @default_sample_every,
          "min" => 1,
          "max" => 30,
          "editable" => true
        },
        %{
          "key" => "max_duration",
          "type" => "integer",
          "default" => @default_max_duration,
          "description" => "Seconds of video to check, from the start."
        }
      ],
      progress: %{"label" => "measuring"},
      results: [
        %{
          "key" => "vmaf.mean",
          "label" => "VMAF score",
          "format" => "number",
          "decimals" => 1,
          "primary" => true
        },
        %{"key" => "verdict", "label" => "Result", "format" => "text"},
        %{"key" => "vmaf.min", "label" => "Lowest frame", "format" => "number", "decimals" => 1},
        %{"key" => "threshold", "label" => "Target score", "format" => "integer"},
        %{"key" => "vmaf.frames", "label" => "Frames checked", "format" => "integer"}
      ]
    }
  end

  @impl MaveCore.Flow.StepPlugin
  def placements(definition) do
    for %{"type" => @ladder_type, "id" => step_id} = step <- Map.get(definition, "steps", []),
        size <- ladder_sizes(step) do
      %{
        "id" => "vmaf_h264_#{size}",
        "name" => "VMAF Quality Check #{String.upcase(size)}",
        "depends_on" => [step_id],
        "params" => %{"size" => size, "source_step_id" => step_id}
      }
    end
  end

  @impl MaveCore.Flow.StepPlugin
  def availability do
    case :persistent_term.get({__MODULE__, :availability}, nil) do
      nil ->
        result = detect_libvmaf()
        :persistent_term.put({__MODULE__, :availability}, result)
        result

      result ->
        result
    end
  end

  @impl MaveCore.Flow.Step
  def run(step, context) do
    params = Map.get(step, "params", %{})
    outputs = Map.get(context, :dependency_outputs, %{})
    size = params["size"]

    cond do
      StepSupport.inspect_reports_no_video?(outputs) ->
        {:ok, skipped(size, "no video stream"), []}

      is_nil(rendition(outputs, size)) ->
        {:ok, skipped(size, "rendition was not created"), []}

      is_nil(comparison_size(outputs)) ->
        {:ok, skipped(size, "source dimensions unknown"), []}

      true ->
        case availability() do
          :ok ->
            measure(step, context, params, outputs, rendition(outputs, size))

          {:unavailable, reason} ->
            {:ok, %{"status" => "unavailable", "size" => size, "reason" => reason}, []}
        end
    end
  end

  defp measure(step, context, params, outputs, rendition) do
    run_input = Map.get(context, :run_input, %{})
    source = Map.get(outputs, "source", %{})
    source_url = source["source_url"] || run_input["input_url"] || run_input["source_url"]
    {width, height} = comparison_size(outputs)
    threshold = integer_param(params, "threshold", @default_threshold, 0, 100)
    sample_every = integer_param(params, "sample_every", @default_sample_every, 1, 30)
    max_duration = integer_param(params, "max_duration", @default_max_duration, 1, 86_400)

    progress =
      StepSupport.ffmpeg_progress(context[:progress_reporter], %{
        stage: "vmaf",
        step_id: step["id"],
        total_ms: checked_duration_ms(outputs, max_duration)
      })

    StepSupport.with_temp_dir("vmaf", fn tmp_dir ->
      with {:ok, ffmpeg_bin} <- StepSupport.find_ffmpeg(),
           {:ok, reference} <-
             StepSupport.prepare_ffmpeg_input(tmp_dir, run_input, source_url, outputs),
           {:ok, distorted} <-
             StepSupport.prepare_storage_ffmpeg_input(
               tmp_dir,
               rendition["bucket"],
               rendition["key"],
               run_input["region"],
               "video/mp4",
               rendition["uri"]
             ),
           {:ok, log_path} <- StepSupport.tmp_file_path(tmp_dir, "vmaf", "json"),
           args =
             ffmpeg_args(distorted, reference, log_path, %{
               width: width,
               height: height,
               sample_every: sample_every,
               max_duration: max_duration
             }),
           {_output, 0} <- StepSupport.run_media_cmd(ffmpeg_bin, args, progress: progress),
           {:ok, log} <- StepSupport.read_tmp_file(log_path),
           {:ok, vmaf} <- parse_log(log) do
        {:ok, output(params["size"], rendition, vmaf, threshold, sample_every, {width, height}),
         []}
      else
        {output, status} when is_binary(output) and is_integer(status) ->
          {:error, {:ffmpeg_exit, status, StepSupport.truncate_binary(output, 1000)}}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @doc false
  def ffmpeg_args(distorted, reference, log_path, opts) do
    scale = "scale=#{opts.width}:#{opts.height}:flags=bicubic,format=yuv420p,setpts=PTS-STARTPTS"

    graph =
      "[0:v]#{scale}[distorted];[1:v]#{scale}[reference];" <>
        "[distorted][reference]libvmaf=log_fmt=json:log_path=#{log_path}:" <>
        "n_subsample=#{opts.sample_every}:n_threads=#{threads()}:shortest=1"

    [
      "-y",
      "-hide_banner",
      "-loglevel",
      "error",
      "-t",
      Integer.to_string(opts.max_duration),
      "-i",
      distorted,
      "-t",
      Integer.to_string(opts.max_duration),
      "-i",
      reference,
      "-lavfi",
      graph,
      "-an",
      "-f",
      "null",
      "-"
    ]
  end

  @doc "Reads the pooled VMAF score from a libvmaf JSON log."
  def parse_log(log) when is_binary(log) do
    case Jason.decode(log) do
      {:ok, %{"pooled_metrics" => %{"vmaf" => %{"mean" => mean} = pooled}} = decoded}
      when is_number(mean) ->
        {:ok,
         %{
           "mean" => round_score(mean),
           "min" => round_score(pooled["min"]),
           "max" => round_score(pooled["max"]),
           "harmonic_mean" => round_score(pooled["harmonic_mean"]),
           "frames" => decoded |> Map.get("frames", []) |> List.wrap() |> length()
         }}

      _ ->
        {:error, :invalid_vmaf_log}
    end
  end

  defp output(size, rendition, vmaf, threshold, sample_every, {width, height}) do
    passed? = vmaf["mean"] >= threshold

    %{
      "status" => "ok",
      "step_type" => @type_name,
      "size" => size,
      "source_step_id" => rendition["step_id"],
      "model" => @model,
      "vmaf" => vmaf,
      "threshold" => threshold,
      "passed" => passed?,
      "verdict" => if(passed?, do: "Meets target", else: "Below target"),
      "sample_every" => sample_every,
      "compared_at" => "#{width}x#{height}"
    }
  end

  defp skipped(size, reason),
    do: %{"status" => "skipped", "step_type" => @type_name, "size" => size, "reason" => reason}

  # The uploaded variant of the requested size, from whichever ladder step made it.
  defp rendition(outputs, size) when is_binary(size) do
    Enum.find_value(outputs, fn
      {_step_id, %{"step_type" => @ladder_type, "variant_outputs" => %{} = variants}} ->
        case Map.get(variants, size) do
          %{"status" => "ok", "bucket" => bucket, "key" => key} = variant
          when is_binary(bucket) and is_binary(key) ->
            variant

          _ ->
            nil
        end

      _ ->
        nil
    end)
  end

  defp rendition(_outputs, _size), do: nil

  # Both videos are scaled to the source size, within 1080p, before comparing.
  defp comparison_size(outputs) do
    case Map.get(outputs, "inspect_media") do
      %{"width" => width, "height" => height}
      when is_integer(width) and is_integer(height) and width > 0 and height > 0 ->
        ratio = Enum.min([1.0, @max_width / width, @max_height / height])
        {even(width * ratio), even(height * ratio)}

      _ ->
        nil
    end
  end

  defp even(value), do: max(2, round(value / 2) * 2)

  defp checked_duration_ms(outputs, max_duration) do
    case StepSupport.inspect_duration_ms(outputs) do
      duration_ms when is_number(duration_ms) and duration_ms > 0 ->
        min(round(duration_ms), max_duration * 1000)

      _ ->
        max_duration * 1000
    end
  end

  defp ladder_sizes(%{"params" => %{"sizes" => sizes}}) when is_list(sizes),
    do: Enum.filter(sizes, &(is_binary(&1) and Regex.match?(~r/^[a-z0-9]+$/, &1)))

  defp ladder_sizes(_step), do: []

  defp integer_param(params, key, default, min, max) do
    case Map.get(params, key) do
      value when is_integer(value) -> value |> max(min) |> min(max)
      _ -> default
    end
  end

  defp round_score(value) when is_number(value), do: Float.round(value * 1.0, 2)
  defp round_score(_value), do: nil

  defp threads, do: System.schedulers_online() |> min(8) |> max(1)

  defp detect_libvmaf do
    with {:ok, ffmpeg_bin} <- StepSupport.find_ffmpeg(),
         {filters, 0} <- StepSupport.run_media_cmd(ffmpeg_bin, ["-hide_banner", "-filters"]),
         true <- String.contains?(filters, " libvmaf ") do
      :ok
    else
      _ -> {:unavailable, "FFmpeg on this installation was built without libvmaf."}
    end
  end
end
