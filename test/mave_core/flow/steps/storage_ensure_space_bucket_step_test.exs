defmodule MaveCore.Flow.Steps.StorageEnsureSpaceBucketStepTest do
  use MaveCore.DataCase, async: false

  alias MaveCore.Accounts
  alias MaveCore.Flow.Steps.StorageEnsureSpaceBucketStep
  alias MaveCore.TestSupport.FlowStorageAdapterStub

  setup do
    old_storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter)
    old_syncer = Application.get_env(:mave_core, :bucket_cors_syncer)
    test_pid = self()

    Application.put_env(:mave_core, :flow_storage_adapter, FlowStorageAdapterStub)

    Application.put_env(:mave_core, :bucket_cors_syncer, fn space ->
      send(test_pid, {:bucket_cors_synced, space.hash, space.region})
      :ok
    end)

    on_exit(fn ->
      if is_nil(old_storage_adapter) do
        Application.delete_env(:mave_core, :flow_storage_adapter)
      else
        Application.put_env(:mave_core, :flow_storage_adapter, old_storage_adapter)
      end

      if is_nil(old_syncer) do
        Application.delete_env(:mave_core, :bucket_cors_syncer)
      else
        Application.put_env(:mave_core, :bucket_cors_syncer, old_syncer)
      end

      FlowStorageAdapterStub.reset!()
    end)

    email = "bucket-step-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(email)
    %{space: user.current_space_membership.space}
  end

  test "ensures bucket and syncs access using normalized space hash", %{space: space} do
    space_hash = space.hash
    space_region = space.region

    assert {:ok, output, []} =
             StorageEnsureSpaceBucketStep.run(%{}, %{
               run_input: %{
                 "space_hash" => "#{space_hash}\n",
                 "region" => space.region
               },
               dependency_outputs: %{}
             })

    assert output["space_hash"] == space_hash
    assert output["bucket"] == "space-#{space_hash}"
    assert output["region"] == space.region

    assert_receive {:bucket_cors_synced, ^space_hash, ^space_region}
  end
end
