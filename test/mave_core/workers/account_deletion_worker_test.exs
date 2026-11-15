defmodule MaveCore.Workers.AccountDeletionWorkerTest do
  use MaveCore.DataCase, async: false

  alias MaveCore.Accounts
  alias MaveCore.Accounts.User
  alias MaveCore.Embeds.Embed
  alias MaveCore.Spaces.Space
  alias MaveCore.Workers.AccountDeletionWorker

  defmodule Storage do
    def update_embed_visibility(_space, hash, "private", _region) do
      send(self(), {:protected, hash})
      :ok
    end
  end

  defmodule FailingCleanup do
    def can_delete_space?(_space), do: :ok
    def enqueue_deleted_space_cleanup(_space), do: {:error, :cleanup_unavailable}
  end

  setup do
    original = Application.get_env(:mave_core, :storage_module)
    Application.put_env(:mave_core, :storage_module, Storage)
    on_exit(fn -> Application.put_env(:mave_core, :storage_module, original) end)
    :ok
  end

  test "deletion commits before storage and resumes between batches" do
    {:ok, owner} = Accounts.create_user("batch-deletion@example.com")
    space = owner.current_space_membership.space

    for n <- 1..21 do
      Repo.insert!(%Embed{space_id: space.id, hash: "batch-delete-#{n}", type: :video})
    end

    assert {:ok, _} =
             Oban.Testing.with_testing_mode(:manual, fn ->
               Accounts.delete_account_and_space(owner, space)
             end)

    refute_received {:protected, _}
    assert Repo.get!(Space, space.id).deleted_at

    job =
      Repo.one!(
        from(j in Oban.Job,
          where: j.worker == "MaveCore.Workers.AccountDeletionWorker",
          where: fragment("?->>'space_id' = ?", j.args, ^space.id)
        )
      )

    assert {:snooze, 1} = AccountDeletionWorker.perform(job)
    for _ <- 1..20, do: assert_received({:protected, _})
    refute_received {:protected, _}

    assert :ok = AccountDeletionWorker.perform(Repo.reload!(job))
    assert_received {:protected, _}
    refute_received {:protected, _}
    assert :ok = AccountDeletionWorker.perform(Repo.reload!(job))
    refute_received {:protected, _}
  end

  test "active spaces cannot be processed" do
    {:ok, owner} = Accounts.create_user("active-deletion@example.com")

    assert {:cancel, :space_not_deleted} =
             AccountDeletionWorker.perform(%Oban.Job{
               args: %{"space_id" => owner.current_space_membership.space.id}
             })

    refute_received {:protected, _}
  end

  test "a stale job cannot protect a changed storage target" do
    {:ok, owner} = Accounts.create_user("changed-storage@example.com")
    space = owner.current_space_membership.space

    {:ok, _} =
      Oban.Testing.with_testing_mode(:manual, fn ->
        Accounts.delete_account_and_space(owner, space)
      end)

    job =
      Repo.one!(
        from(j in Oban.Job,
          where: j.worker == "MaveCore.Workers.AccountDeletionWorker",
          where: fragment("?->>'space_id' = ?", j.args, ^space.id)
        )
      )

    space |> change(hash: "changed-storage") |> Repo.update!()
    assert {:cancel, :space_storage_changed} = AccountDeletionWorker.perform(job)
    refute_received {:protected, _}
  end

  test "failure to enqueue host cleanup rolls back deletion and its media job" do
    {:ok, owner} = Accounts.create_user("rollback-deletion@example.com")
    space = owner.current_space_membership.space
    embed = Repo.insert!(%Embed{space_id: space.id, hash: "rollback-delete", type: :video})
    original = Application.get_env(:mave_core, :account_deletion_backend)
    Application.put_env(:mave_core, :account_deletion_backend, FailingCleanup)

    try do
      assert {:error, :cleanup_unavailable} =
               Oban.Testing.with_testing_mode(:manual, fn ->
                 Accounts.delete_account_and_space(owner, space)
               end)

      refute Repo.get!(User, owner.id).deleted_at
      refute Repo.get!(Space, space.id).deleted_at
      refute Repo.get!(Embed, embed.id).deleted_at

      refute Repo.exists?(
               from(j in Oban.Job,
                 where: j.worker == "MaveCore.Workers.AccountDeletionWorker",
                 where: fragment("?->>'space_id' = ?", j.args, ^space.id)
               )
             )
    after
      if original,
        do: Application.put_env(:mave_core, :account_deletion_backend, original),
        else: Application.delete_env(:mave_core, :account_deletion_backend)
    end
  end
end
