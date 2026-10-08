defmodule MaveCore.EncodingBooster.Concat do
  @moduledoc false

  alias MaveCore.Flow.Steps.Support, as: StepSupport
  alias MaveCore.SafeFile

  @spec join([String.t()], String.t(), keyword()) ::
          {:ok, %{size_bytes: pos_integer()}} | {:error, term()}
  def join(input_paths, output_path, opts \\ [])

  def join([_first, _second | _rest] = input_paths, output_path, opts)
      when is_binary(output_path) and is_list(opts) do
    concat_path = output_path <> ".ffconcat"

    try do
      with :ok <- validate_input_paths(input_paths),
           :ok <- SafeFile.write(concat_path, concat_body(input_paths)),
           {:ok, ffmpeg_bin} <- StepSupport.find_ffmpeg(),
           :ok <- run_concat(ffmpeg_bin, concat_path, output_path, opts),
           :ok <- StepSupport.validate_media_file(output_path, :video),
           {:ok, %{size: size}} when size > 0 <- SafeFile.stat_regular(output_path) do
        {:ok, %{size_bytes: size}}
      else
        {:ok, %{size: 0}} -> {:error, :encoding_booster_empty_concat}
        {:error, _reason} = error -> error
        _other -> {:error, :encoding_booster_concat_failed}
      end
    after
      _ = SafeFile.rm(concat_path)
    end
  end

  def join(_input_paths, _output_path, _opts),
    do: {:error, :encoding_booster_concat_requires_multiple_inputs}

  defp validate_input_paths(input_paths) do
    if Enum.all?(input_paths, &safe_input_path?/1),
      do: :ok,
      else: {:error, :invalid_encoding_booster_concat_input}
  end

  defp safe_input_path?(path) when is_binary(path) do
    not String.contains?(path, ["\n", "\r", "'"]) and
      match?({:ok, %{size: size}} when size > 0, SafeFile.stat_regular(path))
  end

  defp safe_input_path?(_path), do: false

  defp concat_body(input_paths) do
    ["ffconcat version 1.0\n" | Enum.map(input_paths, &["file '", &1, "'\n"])]
  end

  defp run_concat(ffmpeg_bin, concat_path, output_path, opts) do
    args = [
      "-hide_banner",
      "-nostdin",
      "-y",
      "-loglevel",
      "error",
      "-f",
      "concat",
      "-safe",
      "0",
      "-i",
      concat_path,
      "-map",
      "0:v:0",
      "-map",
      "0:a?",
      "-c",
      "copy",
      "-movflags",
      "+faststart",
      output_path
    ]

    runner = Keyword.get(opts, :runner, &StepSupport.run_media_cmd/2)

    case runner.(ffmpeg_bin, args) do
      {_output, 0} -> :ok
      {:error, reason} -> {:error, {:encoding_booster_concat_failed, reason}}
      {_output, status} -> {:error, {:encoding_booster_concat_failed, status}}
      _other -> {:error, :encoding_booster_concat_failed}
    end
  end
end
