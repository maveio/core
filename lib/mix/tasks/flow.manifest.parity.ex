defmodule Mix.Tasks.Flow.Manifest.Parity do
  @shortdoc "Compare legacy and core manifest JSON files"
  @moduledoc """
  Compares two manifest JSON documents after parity normalization.

  Usage:

      mix flow.manifest.parity /path/to/legacy-manifest.json /path/to/core-manifest.json

  The refs can be local files or `s3://bucket/key` URIs.

  Optional flags:

      --region <region>    Region used for S3 provider resolution
  """

  use Mix.Task

  alias MaveCore.Flow.ManifestParity
  alias MaveCore.Media.Storage

  @impl Mix.Task
  def run(args) do
    {opts, refs, _invalid} = OptionParser.parse(args, strict: [region: :string])
    region = Keyword.get(opts, :region)

    case refs do
      [legacy_ref, core_ref] ->
        maybe_start_s3_clients([legacy_ref, core_ref])

        with {:ok, legacy_manifest} <- load_manifest(legacy_ref, region),
             {:ok, core_manifest} <- load_manifest(core_ref, region) do
          report_manifest_diff(legacy_manifest, core_manifest)
        else
          {:error, reason} ->
            Mix.raise("Failed to read/decode manifests: #{inspect(reason)}")
        end

      _ ->
        Mix.raise("Usage: mix flow.manifest.parity [--region REGION] LEGACY_REF CORE_REF")
    end
  end

  defp load_manifest(ref, region) do
    with {:ok, payload} <- load_json(ref, region) do
      decode_manifest(payload)
    end
  end

  defp decode_manifest(payload) when is_map(payload), do: {:ok, payload}

  defp decode_manifest(payload) when is_binary(payload), do: Jason.decode(payload)

  defp decode_manifest(payload) when is_list(payload), do: decode_iodata_manifest(payload)

  defp decode_manifest(payload), do: {:error, {:unsupported_manifest_payload, payload}}

  defp load_json("s3://" <> bucket_and_key, region) do
    case String.split(bucket_and_key, "/", parts: 2) do
      [bucket, key] when bucket != "" and key != "" ->
        case Storage.get(bucket, key, region) do
          {:ok, body} when is_map(body) ->
            {:ok, body}

          {:ok, body} when is_binary(body) ->
            {:ok, body}

          {:ok, body} ->
            {:ok, body}

          {:error, reason} ->
            {:error, {:s3_read_failed, ref: "s3://#{bucket}/#{key}", reason: reason}}
        end

      _ ->
        {:error, {:invalid_s3_ref, "s3://#{bucket_and_key}"}}
    end
  end

  defp load_json(path, _region), do: File.read(path)

  defp maybe_start_s3_clients(refs) do
    if Enum.any?(refs, &String.starts_with?(&1, "s3://")) do
      {:ok, _} = Application.ensure_all_started(:req)
      {:ok, _} = Application.ensure_all_started(:req_s3)
    end
  end

  defp report_manifest_diff(legacy_manifest, core_manifest) do
    case ManifestParity.diff(legacy_manifest, core_manifest) do
      :equal ->
        Mix.shell().info("Manifest parity check passed.")

      diff ->
        Mix.shell().error("Manifest parity check failed.")
        Mix.shell().error("Legacy normalized:")
        Mix.shell().error(inspect(diff.legacy, pretty: true, limit: :infinity))
        Mix.shell().error("Core normalized:")
        Mix.shell().error(inspect(diff.core, pretty: true, limit: :infinity))
        Mix.raise("Manifest parity mismatch")
    end
  end

  defp decode_iodata_manifest(payload) do
    payload
    |> IO.iodata_to_binary()
    |> Jason.decode()
  rescue
    ArgumentError ->
      {:error, {:unsupported_manifest_payload, payload}}
  end
end
