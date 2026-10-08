defmodule MaveCoreWeb.Api.ImageControllerMaintenanceTest do
  use MaveCoreWeb.ConnCase

  setup do
    previous = Application.get_env(:mave_core, :maintenance_mode)
    Application.put_env(:mave_core, :maintenance_mode, true)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:mave_core, :maintenance_mode)
      else
        Application.put_env(:mave_core, :maintenance_mode, previous)
      end
    end)
  end

  test "image origin route stays available during maintenance", %{conn: conn} do
    conn = get(conn, "/invalid.jpg?time=0")

    assert response(conn, 400) =~ "Invalid mave_id format"
  end
end
