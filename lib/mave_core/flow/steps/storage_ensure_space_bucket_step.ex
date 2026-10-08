defmodule MaveCore.Flow.Steps.StorageEnsureSpaceBucketStep do
  @moduledoc """
  Ensures the space bucket exists before write steps.
  """
  @behaviour MaveCore.Flow.Step

  alias MaveCore.Flow.Steps.Support, as: StepSupport
  alias MaveCore.Media.Storage
  alias MaveCore.Spaces

  @impl true
  def run(_step_definition, context) do
    run_input = Map.get(context, :run_input, %{})
    source = Map.get(Map.get(context, :dependency_outputs, %{}), "source", %{})

    space_hash = Map.get(source, "space_hash") || Map.get(run_input, "space_hash")
    region = Map.get(run_input, "region")

    with {:ok, space_hash} <- StepSupport.require_binary(space_hash, :space_hash) do
      normalized_space_hash = String.trim(space_hash)
      storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter, Storage)
      bucket = Storage.bucket_for_space(normalized_space_hash, region)

      case storage_adapter.ensure_bucket(bucket, region) do
        :ok ->
          :ok = Spaces.sync_bucket_access_for_space_hash(normalized_space_hash, region)

          {:ok,
           %{
             "bucket" => bucket,
             "space_hash" => normalized_space_hash,
             "region" => region
           }, []}

        {:error, reason} ->
          {:error, {:ensure_bucket_failed, reason}}
      end
    end
  end
end
