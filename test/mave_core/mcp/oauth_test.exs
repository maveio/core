defmodule MaveCore.MCP.OAuthTest do
  use MaveCore.DataCase, async: true
  import MaveCore.MCPFixtures
  alias MaveCore.Accounts
  alias MaveCore.MCP.{Client, Config, Grant, OAuth, Token}
  alias MaveCore.Spaces

  test "registration validates redirects and client metadata" do
    for uri <- [
          "http://example.com/cb",
          "javascript:alert(1)",
          "https://example.com/#fragment",
          "https://user:pass@example.com/cb",
          "https://example.com/\ncb",
          "file:///tmp/callback"
        ] do
      assert {:error, :invalid_client_metadata} =
               OAuth.register(%{"client_name" => "Test", "redirect_uris" => [uri]})
    end

    for params <- [
          %{},
          %{"client_name" => [], "redirect_uris" => []},
          %{
            "client_name" => "Test",
            "redirect_uris" => ["https://example.com/cb"],
            "token_endpoint_auth_method" => "client_secret_basic"
          }
        ] do
      assert {:error, :invalid_client_metadata} = OAuth.register(params)
    end

    assert {:ok, _} =
             OAuth.register(%{
               "client_name" => "Test",
               "redirect_uris" => ["https://example.com/callback"]
             })
  end

  test "requires PKCE S256, a registered redirect and the exact resource" do
    %{params: params} = mcp_request_fixture()

    for {key, value} <- [
          {"resource", "https://other.example/mcp"},
          {"redirect_uri", "http://127.0.0.1:9999/callback"},
          {"code_challenge_method", "plain"},
          {"code_challenge", "short"},
          {"client_id", "invalid"},
          {"scope", "mave:admin"},
          {"state", %{}}
        ] do
      assert {:error, :invalid_request} = OAuth.authorization_request(Map.put(params, key, value))
    end

    assert {:error, :invalid_request} =
             OAuth.authorization_request(Map.delete(params, "resource"))
  end

  test "codes are hashed, bound to the client, redirect and verifier, and consumed once" do
    f = mcp_code_fixture()
    assert f.query["state"] == "client-state"
    assert f.query["existing"] == "1"
    grant = Repo.one!(Grant)
    assert grant.code_hash == :crypto.hash(:sha256, f.exchange["code"])
    refute grant.code_hash == f.exchange["code"]

    for {key, value} <- [
          {"client_id", "other"},
          {"code_verifier", String.duplicate("x", 43)},
          {"redirect_uri", "https://evil.example/cb"},
          {"resource", "https://other.example/mcp"}
        ] do
      assert {:error, :invalid_grant} = OAuth.exchange(Map.put(f.exchange, key, value))
    end

    assert {:ok, tokens} = OAuth.exchange(f.exchange)
    assert {:ok, %{space_id: space_id}} = OAuth.authenticate(tokens.access_token)
    assert space_id == f.space.id
    assert Spaces.list_user_managed_keys(f.space) == []
    token = Repo.one!(Token)
    assert token.access_hash == :crypto.hash(:sha256, tokens.access_token)
    assert token.refresh_hash == :crypto.hash(:sha256, tokens.refresh_token)
    assert {:error, :invalid_grant} = OAuth.exchange(f.exchange)
    assert {:error, :invalid_token} = OAuth.authenticate(tokens.access_token)
  end

  test "expired codes and access tokens fail" do
    f = mcp_code_fixture()

    Repo.one!(Grant)
    |> Ecto.Changeset.change(code_expires_at: DateTime.add(DateTime.utc_now(), -1))
    |> Repo.update!()

    assert {:error, :invalid_grant} = OAuth.exchange(f.exchange)
    f = mcp_grant_fixture()

    Repo.get_by!(Token, access_hash: :crypto.hash(:sha256, f.tokens.access_token))
    |> Ecto.Changeset.change(access_expires_at: DateTime.add(DateTime.utc_now(), -1))
    |> Repo.update!()

    assert {:error, :invalid_token} = OAuth.authenticate(f.tokens.access_token)
  end

  test "refresh rotates tokens and replay revokes the connection" do
    f = mcp_grant_fixture(scope: "mave:read mave:write")
    params = refresh_params(f)
    assert {:error, :invalid_grant} = OAuth.exchange(Map.put(params, "client_id", "other"))
    assert {:error, :invalid_grant} = OAuth.exchange(Map.put(params, "resource", "wrong"))
    assert {:ok, next} = OAuth.exchange(params)
    assert next.refresh_token != f.tokens.refresh_token
    assert {:error, :invalid_token} = OAuth.authenticate(f.tokens.access_token)
    assert {:ok, _} = OAuth.authenticate(next.access_token)
    assert {:error, :invalid_grant} = OAuth.exchange(params)
    assert {:error, :invalid_token} = OAuth.authenticate(next.access_token)
  end

  test "refresh cannot add permissions or extend its absolute lifetime" do
    f = mcp_grant_fixture()
    original = Repo.one!(Token)

    assert {:error, :invalid_grant} =
             OAuth.exchange(Map.put(refresh_params(f), "scope", "mave:read mave:write"))

    assert {:ok, next} = OAuth.exchange(refresh_params(f))
    next_row = Repo.get_by!(Token, access_hash: :crypto.hash(:sha256, next.access_token))
    assert next_row.refresh_expires_at == original.refresh_expires_at
  end

  test "revocation and loss of membership invalidate access and refresh tokens" do
    f = mcp_grant_fixture()

    assert :ok =
             OAuth.revoke_token(%{"client_id" => f.client.id, "token" => f.tokens.refresh_token})

    assert {:error, :invalid_token} = OAuth.authenticate(f.tokens.access_token)
    assert {:error, :invalid_grant} = OAuth.exchange(refresh_params(f))
    f = mcp_grant_fixture()
    membership = Accounts.get_membership(f.user, f.space)
    Repo.delete!(membership)
    assert {:error, :invalid_token} = OAuth.authenticate(f.tokens.access_token)
    assert {:error, :invalid_grant} = OAuth.exchange(refresh_params(f))
  end

  test "another user's space or connection cannot be approved or revoked" do
    f = mcp_grant_fixture()
    other = mcp_user_fixture()
    assert {:error, :access_denied} = OAuth.approve(f.request, other, f.space.id)
    assert {:error, :not_found} = OAuth.revoke_connection(other, f.grant.id)
    assert {:ok, _} = OAuth.authenticate(f.tokens.access_token)
    assert {:ok, _} = OAuth.revoke_connection(f.user, f.grant.id)
    assert OAuth.connections(f.user) == []
    assert {:error, :invalid_token} = OAuth.authenticate(f.tokens.access_token)
  end

  test "pruning removes expired records without removing active connections" do
    f = mcp_grant_fixture()
    old = DateTime.add(DateTime.utc_now(), -100 * 86_400)
    Repo.get!(Client, f.client.id) |> Ecto.Changeset.change(inserted_at: old) |> Repo.update!()
    assert :ok = OAuth.prune_expired()
    assert {:ok, _} = OAuth.authenticate(f.tokens.access_token)
    Repo.one!(Token) |> Ecto.Changeset.change(refresh_expires_at: old) |> Repo.update!()
    Repo.one!(Grant) |> Ecto.Changeset.change(code_expires_at: old) |> Repo.update!()
    assert :ok = OAuth.prune_expired()
    assert Repo.all(Token) == []
    assert Repo.all(Grant) == []
    assert Repo.all(Client) == []
  end

  defp refresh_params(f),
    do: %{
      "grant_type" => "refresh_token",
      "client_id" => f.client.id,
      "refresh_token" => f.tokens.refresh_token,
      "resource" => Config.resource_url()
    }
end
