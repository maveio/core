defmodule MaveCore.Flow.Steps.ManifestBuildStep do
  @moduledoc """
  Builds and uploads `manifest.json` used by the player.
  """
  @behaviour MaveCore.Flow.Step

  alias MaveCore.Flow.ManifestBuilder
  alias MaveCore.Flow.Steps.Support, as: StepSupport
  alias MaveCore.Media.Storage

  @impl true
  def run(_step_definition, context) do
    run_input = Map.get(context, :run_input, %{})
    dependency_outputs = Map.get(context, :dependency_outputs, %{})
    dependency_artifacts = Map.get(context, :dependency_artifacts, %{})
    storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter, Storage)
    region = Map.get(run_input, "region")
    source_output = Map.get(dependency_outputs, "source", %{})
    embed_hash = Map.get(source_output, "embed_hash") || Map.get(run_input, "embed_hash")
    space_hash = Map.get(source_output, "space_hash") || Map.get(run_input, "space_hash")

    with {:ok, build} <-
           ManifestBuilder.build(%{
             run_input: run_input,
             dependency_outputs: dependency_outputs,
             dependency_artifacts: dependency_artifacts
           }),
         {:ok, bytes} <-
           put_manifest(
             storage_adapter,
             build["bucket"],
             build["key"],
             build["json"],
             region
           ),
         {:ok, embed_hash} <- StepSupport.require_binary(embed_hash, :embed_hash),
         {:ok, space_hash} <- StepSupport.require_binary(space_hash, :space_hash) do
      output = %{
        "manifest_key" => build["key"],
        "manifest_uri" => build["uri"],
        "checksum" => build["checksum"],
        "size_bytes" => bytes
      }

      artifacts = [
        %{
          name: "manifest",
          uri: build["uri"],
          media_type: "application/json",
          size_bytes: bytes,
          metadata: %{
            "space_hash" => space_hash,
            "embed_hash" => embed_hash,
            "version" => get_manifest_version(build["manifest"]),
            "checksum" => build["checksum"]
          }
        }
      ]

      {:ok, output, artifacts}
    end
  end

  defp put_manifest(storage_adapter, bucket, key, json, region) do
    case storage_adapter.put_public(bucket, key, json, "application/json", region) do
      {:ok, _body} -> {:ok, byte_size(json)}
      {:error, reason} -> {:error, {:manifest_upload_failed, reason}}
    end
  end

  defp get_manifest_version(%{"video" => %{"version" => version}}), do: version
  defp get_manifest_version(_), do: 0
end
