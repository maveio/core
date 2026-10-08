defmodule MaveCoreWeb.UploadSocketTest do
  use MaveCore.DataCase, async: false

  alias MaveCore.Accounts
  alias MaveCore.Spaces
  alias MaveCore.Uploads.Token
  alias MaveCoreWeb.{Endpoint, UploadSocket}

  test "connect accepts a documented API-key JWT scoped to an embed id" do
    space = space_fixture()
    {:ok, key} = Spaces.create_key(space)
    embed_id = "#{space.hash}0000000001"
    token = Token.sign_api_key(key, embed_id)

    assert {:ok, socket} = UploadSocket.connect(%{"token" => token}, socket(), nil)
    assert socket.assigns.upload_claims["sub"] == embed_id
  end

  test "connect accepts a documented API-key JWT scoped to a space id" do
    space = space_fixture()
    {:ok, key} = Spaces.create_key(space)
    space_id = space.id
    token = Token.sign_api_key(key, space_id)

    assert {:ok, socket} = UploadSocket.connect(%{"token" => token}, socket(), nil)
    assert socket.assigns.upload_claims["sub"] == space_id
  end

  test "connect rejects missing or invalid upload JWTs" do
    assert :error = UploadSocket.connect(%{}, socket(), nil)
    assert :error = UploadSocket.connect(%{"token" => "not-a-valid-jwt"}, socket(), nil)
  end

  test "connect immediately follows its signing key's current access level" do
    space = space_fixture()
    {:ok, key} = Spaces.create_key(space)
    token = Token.sign_api_key(key, space.id)

    assert {:ok, _socket} = UploadSocket.connect(%{"token" => token}, socket(), nil)
    assert {:ok, read_only_key} = Spaces.make_key_read_only(key)
    assert :error = UploadSocket.connect(%{"token" => token}, socket(), nil)

    assert {:ok, _read_write_key} =
             Spaces.set_key_access_level(read_only_key, :read_write)

    assert {:ok, _socket} = UploadSocket.connect(%{"token" => token}, socket(), nil)
  end

  test "connect rejects upload JWTs without an internal session during maintenance" do
    space = space_fixture()
    {:ok, key} = Spaces.create_key(space)
    token = Token.sign_api_key(key, space.id)

    with_maintenance(fn ->
      assert :error = UploadSocket.connect(%{"token" => token}, socket(), nil)
    end)
  end

  test "connect accepts upload JWTs with a signed admin maintenance claim" do
    space = space_fixture()
    {:ok, key} = Spaces.create_key(space)
    token = Token.sign_api_key(key, space.id, admin_maintenance_bypass: true)

    with_maintenance(fn ->
      assert {:ok, socket} = UploadSocket.connect(%{"token" => token}, socket(), nil)
      assert socket.assigns.upload_claims["sub"] == space.id
    end)
  end

  test "connect rejects forged admin maintenance claims" do
    space = space_fixture()
    {:ok, key} = Spaces.create_key(space)
    token = Token.sign_api_key(key, space.id, claims: %{"mave_admin_upload" => true})

    with_maintenance(fn ->
      assert :error = UploadSocket.connect(%{"token" => token}, socket(), nil)
    end)
  end

  test "connect accepts upload JWTs with an internal dashboard session during maintenance" do
    email = "upload-admin-#{System.unique_integer([:positive])}@example.com"
    admin = user_fixture(email)
    space = space_fixture()
    {:ok, key} = Spaces.create_key(space)
    token = Token.sign_api_key(key, space.id)

    with_flow_admin(email, fn ->
      with_maintenance(fn ->
        assert {:ok, socket} =
                 UploadSocket.connect(
                   %{"token" => token},
                   socket(),
                   %{session: user_session(admin)}
                 )

        assert socket.assigns.upload_claims["sub"] == space.id
      end)
    end)
  end

  test "connect rejects upload JWTs with a customer session during maintenance" do
    user = user_fixture("upload-customer-#{System.unique_integer([:positive])}@example.com")
    space = space_fixture()
    {:ok, key} = Spaces.create_key(space)
    token = Token.sign_api_key(key, space.id)

    with_maintenance(fn ->
      assert :error =
               UploadSocket.connect(
                 %{"token" => token},
                 socket(),
                 %{session: user_session(user)}
               )
    end)
  end

  defp socket, do: %Phoenix.Socket{endpoint: Endpoint}

  defp space_fixture do
    user = user_fixture("upload-socket-#{System.unique_integer([:positive])}@example.com")
    user.current_space_membership.space
  end

  defp user_fixture(email) do
    {:ok, user} = Accounts.create_user(email)
    user
  end

  defp user_session(user) do
    login_token = Accounts.generate_user_login_token(user)
    {:ok, {logged_in_user, persisted_login_token}} = Accounts.login_user(login_token)
    session_token = Accounts.generate_user_session_token(persisted_login_token, logged_in_user)

    %{"user_token" => session_token}
  end

  defp with_maintenance(fun) do
    previous = Application.get_env(:mave_core, :maintenance_mode)
    Application.put_env(:mave_core, :maintenance_mode, true)

    try do
      fun.()
    after
      if is_nil(previous) do
        Application.delete_env(:mave_core, :maintenance_mode)
      else
        Application.put_env(:mave_core, :maintenance_mode, previous)
      end
    end
  end

  defp with_flow_admin(email, fun) do
    previous = Application.get_env(:mave_core, :flow_admin)
    Application.put_env(:mave_core, :flow_admin, emails: [email], email_domains: [])

    try do
      fun.()
    after
      if is_nil(previous) do
        Application.delete_env(:mave_core, :flow_admin)
      else
        Application.put_env(:mave_core, :flow_admin, previous)
      end
    end
  end
end
