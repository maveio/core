defmodule MaveCore.CliAuthorizationsTest do
  use MaveCore.DataCase, async: true

  alias MaveCore.Accounts
  alias MaveCore.CliAuthorizations
  alias MaveCore.CliAuthorizations.Authorization
  alias MaveCore.Spaces
  alias MaveCore.Spaces.Key
  alias MaveCore.Workers.CliAuthorizationPruneWorker

  setup do
    email = "cli-auth-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(email)
    %{space: user.current_space_membership.space}
  end

  test "creates a short-lived authorization without storing the raw device code" do
    now = ~U[2026-07-30 20:00:00.000000Z]

    assert {:ok, %{authorization: authorization, device_code: device_code}} =
             CliAuthorizations.create_authorization(now: now)

    assert authorization.status == :pending
    assert authorization.expires_at == DateTime.add(now, 600, :second)
    assert authorization.device_code_hash == :crypto.hash(:sha256, device_code)
    refute authorization.device_code_hash == device_code
    assert authorization.user_code =~ ~r/^[A-F0-9]{5}-[A-F0-9]{5}$/
  end

  test "approval creates a key only when the device exchanges its code", %{space: space} do
    assert {:ok, %{authorization: authorization, device_code: device_code}} =
             CliAuthorizations.create_authorization()

    assert {:error, :authorization_pending} = CliAuthorizations.exchange(device_code)
    assert Spaces.list_user_managed_keys(space) == []

    assert {:ok, %Authorization{status: :approved, space_id: space_id}} =
             CliAuthorizations.approve(authorization.user_code, space)

    assert space_id == space.id
    assert Spaces.list_user_managed_keys(space) == []

    assert {:ok,
            %{
              access_token: access_token,
              token_type: "Bearer",
              space_id: returned_space_id,
              space_hash: returned_space_hash
            }} = CliAuthorizations.exchange(device_code)

    assert returned_space_id == space.id
    assert returned_space_hash == space.hash

    assert [key] = Spaces.list_user_managed_keys(space)
    assert key.description == "Mave CLI"
    assert key.cli_metadata == %{}
    assert key.access_level == :read_write
    assert access_token == Spaces.display_api_key(key.key, key.secret)
    assert {:error, :invalid_grant} = CliAuthorizations.exchange(device_code)
  end

  test "denied and expired requests never create credentials", %{space: space} do
    now = ~U[2026-07-30 20:00:00.000000Z]

    assert {:ok, %{authorization: denied, device_code: denied_code}} =
             CliAuthorizations.create_authorization(now: now)

    assert {:ok, %Authorization{status: :denied}} =
             CliAuthorizations.deny(denied.user_code, now: now)

    assert {:error, :access_denied} = CliAuthorizations.exchange(denied_code, now: now)

    assert {:ok, %{authorization: expiring, device_code: expired_code}} =
             CliAuthorizations.create_authorization(now: now)

    after_expiry = DateTime.add(now, 601, :second)

    assert {:error, :expired_token} =
             CliAuthorizations.get_for_browser(expiring.user_code, now: after_expiry)

    assert {:error, :expired_token} =
             CliAuthorizations.exchange(expired_code, now: after_expiry)

    assert Spaces.list_user_managed_keys(space) == []
  end

  test "keeps bounded client metadata and copies it to the issued connection", %{space: space} do
    metadata = %{
      "client" => " mave-cli ",
      "version" => "0.1.0",
      "device_name" => "  Studio\nMac\u202E  ",
      "access_level" => "read_only",
      "space_id" => Ecto.UUID.generate()
    }

    assert {:ok, %{authorization: authorization, device_code: code}} =
             CliAuthorizations.create_authorization(client_metadata: metadata)

    expected = %{"client" => "mave-cli", "version" => "0.1.0", "device_name" => "StudioMac"}
    assert authorization.client_metadata == expected
    assert {:ok, _} = CliAuthorizations.approve(authorization.user_code, space)
    assert {:ok, _} = CliAuthorizations.exchange(code)
    assert [key] = Spaces.list_user_managed_keys(space)
    assert key.cli_metadata == expected
    assert key.access_level == :read_write
    assert {:ok, _, authenticated_space} = Spaces.authenticate_api_key(key.key, key.secret)
    assert authenticated_space.id == space.id
  end

  test "ignores missing, invalid and oversized optional metadata" do
    for params <- [
          nil,
          %{},
          %{"device_name" => "  "},
          %{"device_name" => 42},
          %{
            "device_name" => String.duplicate("x", 161),
            "client" => String.duplicate("x", 65),
            "version" => %{}
          }
        ] do
      assert {:ok, %{authorization: authorization}} =
               CliAuthorizations.create_authorization(client_metadata: params)

      assert authorization.client_metadata == %{}
    end

    metadata = %{
      "device_name" => String.duplicate("é", 160),
      "client" => String.duplicate("x", 64),
      "version" => String.duplicate("x", 64)
    }

    assert {:ok, %{authorization: authorization}} =
             CliAuthorizations.create_authorization(client_metadata: metadata)

    assert authorization.client_metadata == metadata
  end

  test "ordinary keys cannot acquire CLI provenance through editable attributes", %{space: space} do
    assert {:ok, key} =
             Spaces.create_key(space, %{
               "description" => "Mave CLI",
               "cli_metadata" => %{"device_name" => "Fake"}
             })

    refute Key.cli_connection?(key)
    assert {:ok, updated} = Spaces.update_key(key, %{"cli_metadata" => %{}})
    assert updated.cli_metadata == nil
  end

  test "prunes authorizations a day after they expire without revoking issued keys",
       %{space: space} do
    now = DateTime.utc_now()
    two_days_ago = DateTime.add(now, -2, :day)

    {:ok, %{authorization: consumed, device_code: device_code}} =
      CliAuthorizations.create_authorization(now: two_days_ago)

    {:ok, _} = CliAuthorizations.approve(consumed.user_code, space, now: two_days_ago)
    {:ok, _token} = CliAuthorizations.exchange(device_code, now: two_days_ago)

    {:ok, %{authorization: abandoned}} =
      CliAuthorizations.create_authorization(now: DateTime.add(now, -25, :hour))

    {:ok, %{authorization: recent}} =
      CliAuthorizations.create_authorization(now: DateTime.add(now, -23, :hour))

    {:ok, %{authorization: pending}} = CliAuthorizations.create_authorization(now: now)

    assert {:ok, 1} = CliAuthorizations.prune_expired(now: now, batch_size: 1)
    assert {:ok, 1} = CliAuthorizations.prune_expired(now: now, batch_size: 1)
    assert {:ok, 0} = CliAuthorizations.prune_expired(now: now)

    refute Repo.get(Authorization, consumed.id)
    refute Repo.get(Authorization, abandoned.id)
    assert Repo.get(Authorization, recent.id)
    assert Repo.get(Authorization, pending.id)
    assert [%Key{description: "Mave CLI"} = key] = Spaces.list_user_managed_keys(space)
    assert {:ok, _, authenticated_space} = Spaces.authenticate_api_key(key.key, key.secret)
    assert authenticated_space.id == space.id
  end

  test "retains the exact cutoff and recent expired requests across statuses" do
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -24, :hour)

    for status <- [:pending, :approved, :denied, :consumed, :expired] do
      for {expires_at, retained?} <- [
            {DateTime.add(cutoff, -1, :microsecond), false},
            {cutoff, true},
            {DateTime.add(cutoff, 1, :microsecond), true}
          ] do
        {:ok, %{authorization: authorization}} = CliAuthorizations.create_authorization(now: now)

        authorization
        |> Ecto.Changeset.change(status: status, expires_at: expires_at)
        |> Repo.update!()

        assert {:ok, _} = CliAuthorizations.prune_expired(now: now)
        assert Repo.get(Authorization, authorization.id) != nil == retained?
      end
    end
  end

  test "worker continues full batches until the expired backlog is cleared" do
    now = DateTime.utc_now()
    expired_at = DateTime.add(now, -2, :day)

    1..10_001
    |> Enum.map(fn index ->
      %{
        id: Ecto.UUID.generate(),
        device_code_hash: :crypto.hash(:sha256, "prune-#{index}"),
        user_code: "prune-#{index}",
        status: :pending,
        expires_at: expired_at,
        inserted_at: now,
        updated_at: now
      }
    end)
    |> Enum.chunk_every(500)
    |> Enum.each(&Repo.insert_all(Authorization, &1))

    {:ok, %{authorization: pending}} = CliAuthorizations.create_authorization(now: now)

    assert {:snooze, 1} = CliAuthorizationPruneWorker.perform(%Oban.Job{})
    assert Repo.aggregate(Authorization, :count) == 2
    assert :ok = CliAuthorizationPruneWorker.perform(%Oban.Job{})
    assert Repo.aggregate(Authorization, :count) == 1
    assert Repo.get!(Authorization, pending.id)
    assert :ok = CliAuthorizationPruneWorker.perform(%Oban.Job{})
  end

  test "normalizes codes entered without their separator" do
    assert CliAuthorizations.normalize_user_code("abcde f0123") == "ABCDE-F0123"
  end
end
