defmodule MaveCore.Flow.Steps.MediaGenerateAudioPeaksStep do
  @moduledoc "Generates bounded, real amplitude peaks for audio player timelines from audio and video uploads."
  @behaviour MaveCore.Flow.Step

  alias MaveCore.EncodingBooster
  alias MaveCore.Flow.Steps.Support, as: StepSupport
  alias MaveCore.Media.Storage

  @peak_count 512
  @sample_rate 48_000

  @impl true
  def run(step, context) do
    outputs = Map.get(context, :dependency_outputs, %{})
    input = Map.get(context, :run_input, %{})
    inspected = Map.get(outputs, "inspect_media", %{})

    cond do
      inspected["has_audio"] != true ->
        {:ok, %{"status" => "skipped", "reason" => "no audio"}, []}

      get_in(outputs, ["transcode_audio", "mode"]) == "copy" ->
        {:ok, %{"status" => "unavailable", "reason" => "audio encoding bypassed"}, []}

      true ->
        generate(step, input, outputs, context)
    end
  end

  defp generate(step, input, outputs, context) do
    duration_ms = StepSupport.inspect_duration_ms(outputs)

    if is_number(duration_ms) and duration_ms > 0 and duration_ms <= 86_400_000 do
      generate_for_duration(step, input, outputs, context, duration_ms / 1000)
    else
      {:ok, %{"status" => "unavailable", "reason" => "unsupported duration"}, []}
    end
  end

  defp generate_for_duration(step, input, outputs, context, duration) do
    source = Map.get(outputs, "source", %{})
    source_url = source["source_url"] || input["input_url"] || input["source_url"]
    space_hash = source["space_hash"] || input["space_hash"]
    embed_hash = source["embed_hash"] || input["embed_hash"]
    version = StepSupport.normalize_version(source["version"] || input["version"])
    region = input["region"]
    storage = Application.get_env(:mave_core, :flow_storage_adapter, Storage)

    progress =
      StepSupport.ffmpeg_progress(context[:progress_reporter], %{
        stage: "generate_audio_peaks",
        step_id: step["id"],
        total_ms: round(duration * 1000)
      })

    with {:ok, space_hash} <- StepSupport.require_binary(space_hash, :space_hash),
         {:ok, embed_hash} <- StepSupport.require_binary(embed_hash, :embed_hash),
         {:ok, peaks} <- extract(context, source_url, duration, progress) do
      bucket = Storage.bucket_for_space(space_hash, region)
      prefix = if version > 0, do: "#{embed_hash}/v#{version}", else: embed_hash
      key = "#{prefix}/audio_peaks.json"

      waveform = %{
        "version" => 1,
        "duration" => duration,
        "peaks" => peaks,
        "audio_track" => get_in(outputs, ["transcode_audio", "audio_track", "filename"])
      }

      json = Jason.encode!(waveform)

      with {:ok, _} <- storage.put_public(bucket, key, json, "application/json", region) do
        {:ok,
         %{
           "status" => "ok",
           "step_type" => "media.generate_audio_peaks",
           "mode" =>
             if(context[:encoding_booster_dispatch] == :direct,
               do: "encoding_booster",
               else: "ffmpeg"
             ),
           "waveform" => waveform
         },
         [
           %{
             name: "audio_peaks",
             uri: "s3://#{bucket}/#{key}",
             media_type: "application/json",
             size_bytes: byte_size(json),
             metadata: %{"version" => version}
           }
         ]}
      end
    end
  end

  defp extract(%{encoding_booster_dispatch: :direct} = context, source_url, duration, _progress) do
    result =
      StepSupport.with_temp_dir("audio_peaks", fn dir ->
        with {:ok, path} <- StepSupport.tmp_file_path(dir, "peaks", "txt"),
             {:ok, input_url} <-
               StepSupport.encoding_booster_input_url(
                 context[:run_input] || %{},
                 source_url,
                 context[:dependency_outputs] || %{},
                 preferred_storage_step_id: "transcode_audio"
               ),
             {:ok, _timing} <-
               booster_adapter().encode_to_file(
                 input_url,
                 path,
                 booster_options(input_url, duration)
               ),
             {:ok, body} <- StepSupport.read_tmp_file(path) do
          parse_peaks(body)
        end
      end)

    case result do
      {:error, :encoding_booster_busy} ->
        result

      {:error, reason} ->
        if EncodingBooster.fallback_enabled?(),
          do: {:error, {:encoding_booster_fallback_required, "request_failed", reason}},
          else: result

      _ ->
        result
    end
  end

  defp extract(context, source_url, duration, progress) do
    input = context[:run_input] || %{}
    outputs = context[:dependency_outputs] || %{}

    StepSupport.with_temp_dir("audio_peaks", fn dir ->
      with {:ok, path} <- StepSupport.tmp_file_path(dir, "peaks", "txt"),
           {:ok, _, _} <-
             StepSupport.run_ffmpeg_with_storage_fallback(
               dir,
               input,
               source_url,
               outputs,
               &{:ok, ffmpeg_args(&1, path, duration)},
               progress: progress,
               preferred_storage_step_id: "transcode_audio"
             ),
           {:ok, body} <- StepSupport.read_tmp_file(path) do
        parse_peaks(body)
      end
    end)
  end

  defp booster_adapter do
    Application.get_env(:mave_core, :encoding_booster_adapter, EncodingBooster)
  end

  defp booster_options(input_url, duration) do
    options = [operation: "audio_peaks", duration_seconds: duration]

    if Storage.ffmpeg_storage_url?(input_url) do
      case Storage.ffmpeg_input_referer() do
        referer when is_binary(referer) -> Keyword.put(options, :input_referer, referer)
        _ -> options
      end
    else
      options
    end
  end

  defp ffmpeg_args(source, path, duration) do
    samples = ceil(duration * @sample_rate / @peak_count)
    # Keep channels separate: opposite-phase stereo must not disappear in a mono mix.
    # One frame per timeline bucket bounds astats memory and its metadata output.
    escaped_path = path |> String.replace("\\", "\\\\") |> String.replace("'", "'\\''")

    filter =
      "aresample=#{@sample_rate},asetnsamples=n=#{samples}:p=0," <>
        "astats=metadata=1:reset=1:measure_perchannel=none:measure_overall=Peak_level," <>
        "ametadata=mode=print:key=lavfi.astats.Overall.Peak_level:file='#{escaped_path}'"

    [
      "-y",
      "-v",
      "error",
      "-i",
      source,
      "-t",
      to_string(duration),
      "-map",
      "0:a:0",
      "-vn",
      "-af",
      filter,
      "-f",
      "null",
      # Keep an explicit output path so the sandbox grants this job's sidecar directory.
      path <> ".null"
    ]
  end

  @doc false
  def parse_peaks(body) do
    peaks =
      Regex.scan(~r/^lavfi\.astats\.Overall\.Peak_level=(.*)$/m, body, capture: :all_but_first)
      |> Enum.take(@peak_count)
      |> Enum.map(fn
        ["-inf"] ->
          0.0

        [value] ->
          case Float.parse(value) do
            {db, ""} -> Float.round(:math.pow(10, min(db, 0.0) / 20), 4)
            _ -> nil
          end
      end)

    if peaks != [] and Enum.all?(peaks, &is_number/1),
      do: {:ok, peaks},
      else: {:error, :invalid_audio_peaks}
  end
end
