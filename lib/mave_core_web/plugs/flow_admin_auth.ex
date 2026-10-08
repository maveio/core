defmodule MaveCoreWeb.Plugs.FlowAdminAuth do
  @moduledoc false

  import Plug.Conn
  use MaveCoreWeb, :controller

  alias MaveCore.Flow.Admin

  @safe_methods ~w(GET HEAD OPTIONS)

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      Admin.dashboard_enabled_for?(conn.assigns[:current_user]) and csrf_safe?(conn) ->
        assign(conn, :flow_admin_authenticated_by, :user)

      Admin.dashboard_enabled_for?(conn.assigns[:current_user]) ->
        csrf_forbidden(conn)

      conn.assigns[:current_user] ->
        forbidden(conn)

      true ->
        unauthorized(conn)
    end
  end

  defp csrf_safe?(%{method: method}) when method in @safe_methods, do: true

  defp csrf_safe?(conn) do
    csrf_state =
      conn
      |> get_session("_csrf_token")
      |> Plug.CSRFProtection.dump_state_from_session()

    csrf_token =
      List.first(get_req_header(conn, "x-csrf-token")) ||
        Map.get(conn.body_params || %{}, "_csrf_token")

    Plug.CSRFProtection.valid_state_and_csrf_token?(csrf_state, csrf_token)
  end

  defp csrf_forbidden(conn) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "Flow admin CSRF token required"})
    |> halt()
  end

  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "Flow admin authentication required"})
    |> halt()
  end

  defp forbidden(conn) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "Flow admin authorization required"})
    |> halt()
  end
end
