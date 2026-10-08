defmodule MaveCoreWeb.UploadHookAuthTest do
  use MaveCoreWeb.ConnCase

  setup do
    config = Application.get_env(:mave_core, :upload, [])
    on_exit(fn -> Application.put_env(:mave_core, :upload, config) end)
    :ok
  end

  test "missing, blank and malformed configured secrets fail closed", %{conn: conn} do
    for secret <- [nil, "", " \t\n", 123, [], %{}] do
      Application.put_env(:mave_core, :upload, hook_secret: secret)

      for params <- [%{}, %{"secret" => "attacker"}] do
        response = post(conn, "/internal/upload-hooks/tusd", params)
        assert json_response(response, 403) == %{"error" => "Forbidden"}
      end
    end
  end

  test "malformed and incorrect supplied secrets fail closed", %{conn: conn} do
    Application.put_env(:mave_core, :upload, hook_secret: "configured-secret")

    for secret <- [nil, "", "wrong", "configured-secrex", ["configured-secret"], %{}] do
      response =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/internal/upload-hooks/tusd", Jason.encode!(%{secret: secret}))

      assert json_response(response, 403) == %{"error" => "Forbidden"}
    end
  end

  test "a valid query secret still reaches the hook handler", %{conn: conn} do
    Application.put_env(:mave_core, :upload, hook_secret: "configured-secret")

    conn =
      post(conn, "/internal/upload-hooks/tusd?secret=configured-secret", %{
        "Type" => "post-create"
      })

    assert json_response(conn, 200) == %{"status" => "ok", "action" => "ignored"}
  end

  test "runtime configuration rejects explicitly blank secrets" do
    with_secret_env(fn ->
      for name <- ["MAVE_CORE_INTERNAL_SECRET", "MAVE_UPLOAD_HOOK_SECRET"] do
        for value <- ["", " \t"] do
          System.put_env(name, value)

          assert_raise RuntimeError, "#{name} must not be blank", &runtime_config/0
        end

        System.put_env(name, "configured-secret")
      end
    end)
  end

  test "an unset upload secret retains the internal secret fallback" do
    with_secret_env(fn ->
      System.delete_env("MAVE_UPLOAD_HOOK_SECRET")
      config = runtime_config()
      assert config[:mave_core][:upload][:hook_secret] == "configured-secret"
    end)
  end

  defp runtime_config do
    Config.Reader.read!(Path.expand("../../config/runtime.exs", __DIR__),
      env: :test,
      target: :host
    )
  end

  defp with_secret_env(fun) do
    names = ["MAVE_CORE_INTERNAL_SECRET", "MAVE_UPLOAD_HOOK_SECRET"]
    previous = Map.new(names, &{&1, System.get_env(&1)})

    try do
      Enum.each(names, &System.put_env(&1, "configured-secret"))
      fun.()
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end
end
