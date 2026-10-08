defmodule MaveCore.Media.Command do
  @moduledoc false

  @safe_environment ~w(PATH LANG LC_ALL SYSTEMROOT MAVE_MEDIA_MAX_ADDRESS_BYTES MAVE_MEDIA_MAX_FILE_BYTES MAVE_MEDIA_MAX_CPU_SECONDS MAVE_MEDIA_SANDBOX_BACKEND MAVE_MEDIA_SANDBOX_GPU CUDA_VISIBLE_DEVICES)
  @protocols "file,http,https,tcp,tls,crypto,pipe"

  def prepare(executable, args, scratch_root) do
    args = restrict_protocols(executable, args)

    case System.get_env("MAVE_MEDIA_SANDBOX", "disabled") do
      "disabled" ->
        {:ok, executable, args}

      "required" ->
        case System.find_executable("mave-media-broker") do
          nil ->
            {:error, :media_sandbox_not_found}

          launcher ->
            {:ok, launcher,
             scratch_args(args, scratch_root) ++
               bundled_asset_args(args) ++ ["--", executable | args]}
        end

      _other ->
        {:error, :invalid_media_sandbox_mode}
    end
  end

  # Port and System.cmd inherit the parent environment unless each unwanted key
  # is explicitly removed. Apply this even for native development without Linux.
  def environment do
    System.get_env()
    |> Enum.map(fn {key, value} -> {key, if(key in @safe_environment, do: value)} end)
  end

  defp restrict_protocols(executable, args) do
    if Path.basename(executable) == "ffmpeg" do
      ["-nostdin" | restrict_ffmpeg_inputs(args)]
    else
      restrict_single_input(args)
    end
  end

  defp restrict_single_input(args) do
    if "-protocol_whitelist" in args, do: args, else: ["-protocol_whitelist", @protocols | args]
  end

  defp restrict_ffmpeg_inputs(args) do
    if "-i" in args do
      {args, _explicit?} = Enum.flat_map_reduce(args, false, &restrict_input_arg/2)
      args
    else
      restrict_single_input(args)
    end
  end

  defp restrict_input_arg("-protocol_whitelist" = arg, _explicit?), do: {[arg], true}
  defp restrict_input_arg("-i", true), do: {["-i"], false}
  defp restrict_input_arg("-i", false), do: {["-protocol_whitelist", @protocols, "-i"], false}
  defp restrict_input_arg(arg, explicit?), do: {[arg], explicit?}

  defp bundled_asset_args(args) do
    path = Application.app_dir(:mave_core, "priv/static/images/play.png")
    if path in args, do: ["--read-only", path], else: []
  end

  # Arguments are constructed by trusted step handlers, never by upload metadata.
  # Grant only the referenced job beneath the scratch root, not all workers' temp files.
  defp scratch_args(args, scratch_root) do
    root = Path.expand(scratch_root)

    args
    |> Enum.filter(&String.starts_with?(&1, root <> "/"))
    |> Enum.map(fn path ->
      path |> Path.expand() |> Path.relative_to(root) |> Path.split()
    end)
    |> Enum.flat_map(fn
      [first | _] when first not in ["..", "/", "."] -> [Path.join(root, first)]
      _other -> []
    end)
    |> Enum.uniq()
    |> Enum.flat_map(&["--scratch", &1])
  end
end
