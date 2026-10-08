defmodule MaveCore.ReleaseTest do
  use MaveCore.DataCase, async: false

  alias MaveCore.Accounts
  alias MaveCore.Release

  setup do
    original_domain = Application.get_env(:mave_core, :domain)
    Application.put_env(:mave_core, :domain, "http://localhost:4000")

    on_exit(fn ->
      if original_domain do
        Application.put_env(:mave_core, :domain, original_domain)
      else
        Application.delete_env(:mave_core, :domain)
      end
    end)
  end

  test "bootstrap creates the first confirmed owner and a default workspace" do
    assert {:ok, result} = Release.bootstrap_owner(" owner@example.com ")
    assert result.created?
    assert MaveCore.Repo.exists?("installation_setup")
    assert result.email == "owner@example.com"
    assert result.login_url =~ ~r{^http://localhost:4000/videos\?token=}

    owner = Accounts.get_user_by_email("owner@example.com")
    assert owner.confirmed_at
    assert owner.current_space_membership.role == "owner"
    assert owner.current_space_membership.space.region == "default"
  end

  test "bootstrap is idempotent for the same owner" do
    assert {:ok, first} = Release.bootstrap_owner("owner@example.com")
    assert {:ok, second} = Release.bootstrap_owner("owner@example.com")

    assert first.created?
    refute second.created?
    assert first.login_url != second.login_url
  end

  test "bootstrap refuses to create a different owner after setup" do
    assert {:ok, _first} = Release.bootstrap_owner("owner@example.com")

    assert {:ok, _later_user} =
             Accounts.create_user("someone-else@example.com", %{skip_email_validation: true})

    assert {:error, :already_bootstrapped} =
             Release.bootstrap_owner("someone-else@example.com")
  end
end
