defmodule MaveCoreWeb.Api.WebhooksControllerTest do
  use MaveCoreWeb.ConnCase

  alias MaveCore.{Accounts, Spaces}

  setup do
    {:ok, user} =
      Accounts.create_user("webhook-api-#{System.unique_integer([:positive])}@example.com")

    space = user.current_space_membership.space
    {:ok, key} = Spaces.create_key(space)
    resolver = Application.get_env(:mave_core, :public_http_url_resolver)

    Application.put_env(:mave_core, :public_http_url_resolver, fn _ ->
      {:ok, [{93, 184, 216, 34}]}
    end)

    on_exit(fn ->
      if resolver,
        do: Application.put_env(:mave_core, :public_http_url_resolver, resolver),
        else: Application.delete_env(:mave_core, :public_http_url_resolver)
    end)

    %{space: space, key: key, auth: "Bearer #{Spaces.display_api_key(key.key, key.secret)}"}
  end

  test "both route families require authentication", %{conn: conn} do
    for prefix <- ["/v1", "/api/v1"] do
      assert conn |> get(prefix <> "/webhooks") |> json_response(401)
      assert conn |> post(prefix <> "/webhooks", registration()) |> json_response(401)
      assert conn |> delete(prefix <> "/webhooks/#{Ecto.UUID.generate()}") |> json_response(401)
    end
  end

  test "registration preserves the secret but never serializes it and reuses canonical events", %{
    conn: conn,
    auth: auth,
    space: space
  } do
    created = conn |> authorized(auth) |> post("/v1/webhooks", registration())
    assert %{"data" => data} = json_response(created, 201)
    assert Map.keys(data) |> Enum.sort() == ~w(created_at enabled enabled_events id url)
    assert data["enabled_events"] == ["video_ready", "video_uploaded"]
    assert data["enabled"]

    stored = Spaces.get_webhook_for_space(space, data["id"])
    assert stored.secret == registration()["secret"]

    repeated =
      conn
      |> authorized(auth)
      |> post(
        "/api/v1/webhooks",
        Map.put(registration(), "enabled_events", ["video_uploaded", "video_ready", "video_ready"])
      )

    assert %{"data" => ^data} = json_response(repeated, 200)
    listed = conn |> authorized(auth) |> get("/api/v1/webhooks") |> json_response(200)
    assert listed == %{"data" => [data]}
    refute created.resp_body =~ registration()["secret"]
  end

  test "Basic credentials can list and subscribe", %{conn: conn, key: key} do
    auth = Plug.BasicAuth.encode_basic_auth(key.key, key.secret)

    assert conn
           |> authorized(auth)
           |> post("/api/v1/webhooks", registration())
           |> json_response(201)

    assert %{"data" => [_]} =
             conn |> authorized(auth) |> get("/v1/webhooks") |> json_response(200)
  end

  test "read-only keys can list but cannot register or unregister", %{
    conn: conn,
    auth: auth,
    key: key,
    space: space
  } do
    {:ok, {webhook, :created}} = Spaces.register_webhook(space, registration())
    {:ok, _key} = Spaces.make_key_read_only(key)

    assert conn |> authorized(auth) |> get("/v1/webhooks") |> json_response(200)
    assert conn |> authorized(auth) |> post("/v1/webhooks", registration()) |> json_response(403)

    assert conn
           |> authorized(auth)
           |> delete("/api/v1/webhooks/#{webhook.id}")
           |> json_response(403)

    assert Spaces.get_webhook_for_space(space, webhook.id)
  end

  test "tenant fields cannot change ownership and other tenants are invisible", %{
    conn: conn,
    auth: auth,
    space: space
  } do
    {:ok, other} =
      Accounts.create_user("other-webhook-#{System.unique_integer([:positive])}@example.com")

    other_space = other.current_space_membership.space
    {:ok, {foreign, :created}} = Spaces.register_webhook(other_space, registration())

    assert %{"data" => []} = conn |> authorized(auth) |> get("/v1/webhooks") |> json_response(200)
    assert conn |> authorized(auth) |> delete("/v1/webhooks/#{foreign.id}") |> response(204)
    assert Spaces.get_webhook_for_space(other_space, foreign.id)

    params = Map.merge(registration(), %{"space_id" => other_space.id, "enabled" => false})

    assert %{"data" => %{"id" => id, "enabled" => true}} =
             conn |> authorized(auth) |> post("/v1/webhooks", params) |> json_response(201)

    assert Spaces.get_webhook_for_space(space, id)
    refute Spaces.get_webhook_for_space(other_space, id)
  end

  test "delete is idempotent including malformed and absent identifiers", %{
    conn: conn,
    auth: auth,
    space: space
  } do
    {:ok, {webhook, :created}} = Spaces.register_webhook(space, registration())

    for id <- [webhook.id, webhook.id, "not-a-uuid", Ecto.UUID.generate()] do
      assert conn |> authorized(auth) |> delete("/api/v1/webhooks/#{id}") |> response(204)
    end

    assert Spaces.list_webhooks(space) == []
  end

  test "invalid registrations return field errors without reflecting sensitive values", %{
    conn: conn,
    auth: auth
  } do
    for params <- [
          %{},
          Map.put(registration(), "secret", nil),
          Map.put(registration(), "enabled_events", []),
          Map.put(registration(), "enabled_events", ["video_published"]),
          Map.put(registration(), "url", "http://example.com/hook"),
          Map.put(registration(), "url", "https://127.0.0.1/hook")
        ] do
      result = conn |> authorized(auth) |> post("/v1/webhooks", params)
      assert %{"errors" => errors} = json_response(result, 422)
      assert map_size(errors) > 0
      refute result.resp_body =~ registration()["secret"]
    end
  end

  test "Phoenix log filtering and schema inspection redact signing secrets" do
    secret = registration()["secret"]
    refute inspect(%MaveCore.Spaces.Webhook{secret: secret}) =~ secret
    assert %{"secret" => "[FILTERED]"} = Phoenix.Logger.filter_values(%{"secret" => secret})
  end

  defp authorized(conn, auth), do: put_req_header(conn, "authorization", auth)

  defp registration do
    %{
      "url" => "https://example.com/automation",
      "secret" => "synthetic-integration-signing-key",
      "enabled_events" => ["video_ready", "video_uploaded"]
    }
  end
end
