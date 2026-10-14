defmodule MaveCore.MCPFixtures do
  @moduledoc false
  alias MaveCore.Accounts
  alias MaveCore.MCP.{Config, OAuth}

  def mcp_user_fixture do
    {:ok, user} = Accounts.create_user("mcp-#{System.unique_integer([:positive])}@example.com")
    user
  end

  def mcp_request_fixture(opts \\ []) do
    {:ok, client} =
      OAuth.register(%{
        "client_name" => "Test assistant",
        "redirect_uris" => ["http://127.0.0.1:4567/callback?existing=1"]
      })

    verifier = String.duplicate("v", 43)

    params = %{
      "client_id" => client.id,
      "redirect_uri" => hd(client.redirect_uris),
      "response_type" => "code",
      "resource" => Config.resource_url(),
      "state" => "client-state",
      "scope" => Keyword.get(opts, :scope, "mave:read"),
      "code_challenge_method" => "S256",
      "code_challenge" => :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    }

    {:ok, request} = OAuth.authorization_request(params)
    %{client: client, verifier: verifier, params: params, request: request}
  end

  def mcp_code_fixture(opts \\ []) do
    fixture = mcp_request_fixture(opts)
    user = Keyword.get_lazy(opts, :user, &mcp_user_fixture/0)
    space = user.current_space_membership.space
    {:ok, url} = OAuth.approve(fixture.request, user, space.id)
    query = URI.decode_query(URI.parse(url).query)

    exchange = %{
      "grant_type" => "authorization_code",
      "client_id" => fixture.client.id,
      "resource" => Config.resource_url(),
      "code" => query["code"],
      "code_verifier" => fixture.verifier,
      "redirect_uri" => fixture.request.redirect_uri
    }

    Map.merge(fixture, %{user: user, space: space, exchange: exchange, query: query})
  end

  def mcp_grant_fixture(opts \\ []) do
    fixture = mcp_code_fixture(opts)
    {:ok, tokens} = OAuth.exchange(fixture.exchange)
    {:ok, grant} = OAuth.authenticate(tokens.access_token)
    Map.merge(fixture, %{tokens: tokens, grant: grant})
  end
end
