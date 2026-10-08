defmodule MaveCoreWeb.Api.Flow.RunsControllerTest do
  use MaveCoreWeb.ConnCase

  alias MaveCore.Accounts
  alias MaveCore.Flow

  @definition %{
    "steps" => [
      %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"},
      %{
        "id" => "manifest",
        "type" => "manifest.build",
        "name" => "Build Manifest",
        "depends_on" => ["source"]
      }
    ]
  }

  setup do
    old_flow_admin_config = Application.get_env(:mave_core, :flow_admin)
    old_storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter)

    Application.put_env(:mave_core, :flow_admin, emails: [], email_domains: ["mave.io"])

    Application.put_env(
      :mave_core,
      :flow_storage_adapter,
      MaveCore.TestSupport.FlowStorageAdapterStub
    )

    {flow_admin_session, flow_admin_csrf_token} =
      flow_admin_session("flow-api-admin-#{System.unique_integer([:positive])}@mave.io")

    on_exit(fn ->
      restore_env(:flow_admin, old_flow_admin_config)
      restore_env(:flow_storage_adapter, old_storage_adapter)
    end)

    {:ok, flow_admin_session: flow_admin_session, flow_admin_csrf_token: flow_admin_csrf_token}
  end

  test "lists step types", %{conn: conn} = context do
    conn = conn |> flow_admin_conn(context) |> get(~p"/v1/flow/step-types")
    response = json_response(conn, 200)
    assert is_list(response["data"])
    assert Enum.any?(response["data"], fn step -> step["type"] == "manifest.build" end)
  end

  test "creates template version and run through API", %{conn: conn} = context do
    conn =
      conn
      |> flow_admin_conn(context)
      |> post(~p"/v1/flow/templates", %{"slug" => "publish_api", "name" => "Publish API"})

    %{"data" => %{"id" => template_id}} = json_response(conn, 201)

    conn =
      conn
      |> flow_admin_conn(context)
      |> post(~p"/v1/flow/templates/#{template_id}/versions", %{
        "definition" => @definition
      })

    %{"data" => %{"id" => _version_id, "version" => 1}} = json_response(conn, 201)

    conn =
      conn
      |> flow_admin_conn(context)
      |> post(~p"/v1/flow/runs", %{
        "template_slug" => "publish_api",
        "enqueue" => false,
        "input" => %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4",
          "source_body" => "stub-media-body",
          "source_content_type" => "video/mp4",
          "media_inspect_strict" => false,
          "media_package_hls_variant_strict" => false,
          "media_package_hls_audio_strict" => false,
          "media_probe" => %{
            "duration" => 10.0,
            "size_bytes" => 15,
            "filetype" => "mp4",
            "aspect_ratio" => "16 / 9",
            "streams" => []
          }
        }
      })

    %{"data" => %{"id" => run_id, "status" => "running", "steps" => steps}} =
      json_response(conn, 202)

    assert length(steps) == 2

    {:ok, _run} = Flow.reconcile_run(run_id, enqueue_jobs: false)
    assert {:ok, _} = Flow.execute_step(run_id, "source", enqueue_coordinator: false)
    {:ok, _run} = Flow.reconcile_run(run_id, enqueue_jobs: false)
    assert {:ok, _} = Flow.execute_step(run_id, "manifest", enqueue_coordinator: false)
    {:ok, _run} = Flow.reconcile_run(run_id, enqueue_jobs: false)

    conn = conn |> flow_admin_conn(context) |> get(~p"/v1/flow/runs/#{run_id}")

    %{"data" => %{"status" => "succeeded", "artifacts" => artifacts}} = json_response(conn, 200)
    assert Enum.any?(artifacts, fn artifact -> artifact["name"] == "manifest" end)
  end

  test "lists and installs built-in presets", %{conn: conn} = context do
    conn = conn |> flow_admin_conn(context) |> get(~p"/v1/flow/presets")
    %{"data" => presets} = json_response(conn, 200)
    assert Enum.any?(presets, fn preset -> preset["slug"] == "publish_default" end)

    conn =
      conn |> flow_admin_conn(context) |> post(~p"/v1/flow/presets/publish_default/install", %{})

    %{"data" => %{"version_created" => true}} = json_response(conn, 201)

    conn =
      conn |> flow_admin_conn(context) |> post(~p"/v1/flow/presets/publish_default/install", %{})

    %{"data" => %{"version_created" => false}} = json_response(conn, 200)
  end

  test "can execute a run inline through API", %{conn: conn} = context do
    conn =
      conn |> flow_admin_conn(context) |> post(~p"/v1/flow/presets/publish_default/install", %{})

    _ = json_response(conn, 201)

    conn =
      conn
      |> flow_admin_conn(context)
      |> post(~p"/v1/flow/runs", %{
        "template_slug" => "publish_default",
        "execution" => "inline",
        "input" => %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4",
          "source_body" => "stub-media-body",
          "source_content_type" => "video/mp4",
          "media_probe" => %{
            "format" => %{
              "duration" => "10.0",
              "size" => "1000000",
              "format_name" => "mov,mp4,m4a,3gp,3g2,mj2"
            },
            "streams" => [
              %{
                "codec_type" => "video",
                "codec_name" => "h264",
                "width" => 640,
                "height" => 360,
                "display_aspect_ratio" => "16:9"
              }
            ]
          },
          "media_package_hls_variant_strict" => false,
          "media_package_hls_audio_strict" => false,
          "media_build_hls_master_strict" => false
        }
      })

    %{"data" => %{"status" => "succeeded", "artifacts" => artifacts}} = json_response(conn, 200)
    assert Enum.any?(artifacts, fn artifact -> artifact["name"] == "manifest" end)
    assert Enum.any?(artifacts, fn artifact -> artifact["name"] == "original" end)

    assert Enum.any?(artifacts, fn artifact ->
             artifact["name"] == "manifest" and artifact["size_bytes"] > 0
           end)
  end

  test "flow API rejects unauthenticated requests while data API remains protected", %{conn: conn} do
    conn = get(conn, ~p"/v1/flow/step-types")

    assert %{"error" => "Flow admin authentication required"} =
             json_response(conn, 401)

    conn = recycle(conn)
    conn = get(conn, ~p"/api/v1/videos/ubg50LeDE9v86ye/data")
    assert response(conn, 401)
  end

  test "flow API accepts configured admin account sessions", %{conn: conn} do
    conn =
      conn
      |> authenticated_conn("flow-admin@mave.io")
      |> get(~p"/v1/flow/step-types")

    response = json_response(conn, 200)
    assert is_list(response["data"])
  end

  test "flow API accepts configured admin account sessions during maintenance", %{conn: conn} do
    with_maintenance(fn ->
      conn =
        conn
        |> authenticated_conn("flow-maintenance-admin@mave.io")
        |> get(~p"/v1/flow/step-types")

      response = json_response(conn, 200)
      assert is_list(response["data"])
    end)
  end

  test "flow API rejects authenticated non-admin account sessions", %{conn: conn} do
    conn =
      conn
      |> authenticated_conn("flow-user@example.com")
      |> get(~p"/v1/flow/step-types")

    assert %{"error" => "Flow admin authorization required"} = json_response(conn, 403)
  end

  test "flow API requires CSRF for configured admin account session writes", %{conn: conn} do
    conn =
      conn
      |> authenticated_conn("flow-admin-write@mave.io")
      |> post(~p"/v1/flow/presets/publish_default/install", %{})

    assert %{"error" => "Flow admin CSRF token required"} = json_response(conn, 403)
  end

  test "flow API accepts CSRF-valid configured admin account session writes", %{conn: conn} do
    Plug.CSRFProtection.delete_csrf_token()
    csrf_token = Plug.CSRFProtection.get_csrf_token()
    csrf_state = Plug.CSRFProtection.dump_state()

    conn =
      conn
      |> authenticated_conn("flow-admin-csrf@mave.io", csrf_state: csrf_state)
      |> put_req_header("x-csrf-token", csrf_token)
      |> post(~p"/v1/flow/presets/publish_default/install", %{})

    %{"data" => %{"version_created" => true}} = json_response(conn, 201)
  end

  defp authenticated_conn(conn, email) do
    authenticated_conn(conn, email, [])
  end

  defp authenticated_conn(conn, email, opts) do
    session_token = session_token_for(email)

    session =
      case Keyword.fetch(opts, :csrf_state) do
        {:ok, csrf_state} -> %{"_csrf_token" => csrf_state, :user_token => session_token}
        :error -> [user_token: session_token]
      end

    init_test_session(conn, session)
  end

  defp flow_admin_session(email) do
    session_token = session_token_for(email)
    Plug.CSRFProtection.delete_csrf_token()
    csrf_token = Plug.CSRFProtection.get_csrf_token()
    csrf_state = Plug.CSRFProtection.dump_state()

    {%{"_csrf_token" => csrf_state, :user_token => session_token}, csrf_token}
  end

  defp flow_admin_conn(conn, context) do
    conn
    |> fresh_conn()
    |> init_test_session(context.flow_admin_session)
    |> put_req_header("x-csrf-token", context.flow_admin_csrf_token)
  end

  defp fresh_conn(%Plug.Conn{state: :unset} = conn), do: conn
  defp fresh_conn(conn), do: recycle(conn)

  defp session_token_for(email) do
    assert {:ok, user} = Accounts.create_user(email)
    login_token = Accounts.generate_user_login_token(user)
    assert {:ok, {logged_in_user, persisted_login_token}} = Accounts.login_user(login_token)

    Accounts.generate_user_session_token(persisted_login_token, logged_in_user)
  end

  defp with_maintenance(fun) do
    previous = Application.get_env(:mave_core, :maintenance_mode)
    Application.put_env(:mave_core, :maintenance_mode, true)

    try do
      fun.()
    after
      restore_env(:maintenance_mode, previous)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)
end
