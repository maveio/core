defmodule MaveCoreWeb.Api.Data.CdnTelemetryControllerTest do
  use MaveCoreWeb.ConnCase, async: false

  @token "test-cdn-telemetry-token"

  setup do
    previous = Application.get_env(:mave_core, :cdn_telemetry_token)
    Application.put_env(:mave_core, :cdn_telemetry_token, @token)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:mave_core, :cdn_telemetry_token, previous),
        else: Application.delete_env(:mave_core, :cdn_telemetry_token)
    end)
  end

  defp record(overrides \\ %{}) do
    Map.merge(
      %{
        "timestamp" => System.system_time(:millisecond),
        "url" => "https://space-cdnta.cdn.example/VIDEOHASH0/h264/720p/segment_1.m4s",
        "status" => 200,
        "cache_status" => "HIT",
        "bytes" => 1_000,
        "ttfb_ms" => 20
      },
      overrides
    )
  end

  defp authorized(conn, token \\ @token),
    do: put_req_header(conn, "authorization", "Bearer " <> token)

  test "accepts attributable records and reports what was dropped", %{conn: conn} do
    records = [record(), record(%{"url" => "https://cdn.example/unrelated.js"}), "garbage"]

    conn = conn |> authorized() |> post(~p"/internal/cdn-telemetry", %{"records" => records})

    assert json_response(conn, 202) == %{"accepted" => 1, "dropped" => 2}
  end

  test "requires the operator token", %{conn: conn} do
    payload = %{"records" => [record()]}

    assert conn |> post(~p"/internal/cdn-telemetry", payload) |> json_response(401)

    assert conn
           |> authorized("another-telemetry-token")
           |> post(~p"/internal/cdn-telemetry", payload)
           |> json_response(401)
  end

  test "is disabled until a token is configured", %{conn: conn} do
    Application.delete_env(:mave_core, :cdn_telemetry_token)

    conn = conn |> authorized() |> post(~p"/internal/cdn-telemetry", %{"records" => [record()]})

    assert json_response(conn, 404) == %{"error" => "cdn_telemetry_disabled"}
  end

  test "rejects malformed and oversized payloads", %{conn: conn} do
    assert conn
           |> authorized()
           |> post(~p"/internal/cdn-telemetry", %{"records" => "nope"})
           |> json_response(400)

    assert conn
           |> authorized()
           |> post(~p"/internal/cdn-telemetry", %{"records" => List.duplicate(%{}, 2001)})
           |> json_response(413)
  end
end
