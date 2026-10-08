defmodule MaveCoreWeb.Api.Data.EventsControllerTest do
  use MaveCoreWeb.ConnCase

  @session_id "12090000-0000-4000-8000-000000000001"

  setup do
    previous = Application.get_env(:mave_core, :maintenance_mode)
    Application.delete_env(:mave_core, :maintenance_mode)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:mave_core, :maintenance_mode)
      else
        Application.put_env(:mave_core, :maintenance_mode, previous)
      end
    end)
  end

  describe "POST /v1/events" do
    test "accepts valid list of events", %{conn: conn} do
      now_ms = System.system_time(:millisecond)

      payload = %{
        "events" => [
          %{
            "name" => "play",
            "session_id" => @session_id,
            "video_id" => "v1",
            "timestamp" => now_ms
          },
          %{
            "name" => "pause",
            "session_id" => @session_id,
            "video_id" => "v1",
            "timestamp" => now_ms + 1
          }
        ]
      }

      conn = post(conn, ~p"/v1/events", payload)
      assert response(conn, 202)
    end

    test "returns 400 for bad payload", %{conn: conn} do
      conn = post(conn, ~p"/v1/events", %{"foo" => "bar"})
      assert response(conn, 400)
    end

    test "stays available during maintenance", %{conn: conn} do
      Application.put_env(:mave_core, :maintenance_mode, true)

      now_ms = System.system_time(:millisecond)

      payload = %{
        "events" => [
          %{
            "name" => "play",
            "session_id" => @session_id,
            "video_id" => "v1",
            "timestamp" => now_ms
          }
        ]
      }

      conn = post(conn, ~p"/v1/events", payload)

      assert response(conn, 202)
    end

    test "rejects a mixed batch containing an invalid session UUID", %{conn: conn} do
      now_ms = System.system_time(:millisecond)

      payload = %{
        "events" => [
          %{"name" => "play", "session_id" => @session_id, "timestamp" => now_ms},
          %{"name" => "pause", "session_id" => "not-a-uuid", "timestamp" => now_ms}
        ]
      }

      conn = post(conn, ~p"/v1/events", payload)

      assert %{
               "error" => "invalid_event",
               "index" => 1,
               "reason" => "{:invalid, \"session_id\"}"
             } = json_response(conn, 422)
    end
  end
end
