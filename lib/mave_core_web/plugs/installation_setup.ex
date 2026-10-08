defmodule MaveCoreWeb.Plugs.InstallationSetup do
  @moduledoc false
  import Plug.Conn
  import Phoenix.Controller

  alias MaveCore.Installation
  alias MaveCoreWeb.Endpoint

  def init(opts), do: opts

  # Forwarding hosts must never expose the standalone setup, even if they
  # accidentally inherit its environment configuration.
  def standalone?(conn), do: conn.private[:phoenix_endpoint] == Endpoint

  def call(conn, _opts) do
    if standalone?(conn) and conn.method == "GET" and
         (conn.request_path in ["/", "/login", "/signup"] or
            String.starts_with?(conn.request_path, "/auth/")) and Installation.pending?() do
      conn |> redirect(to: "/setup") |> halt()
    else
      conn
    end
  end
end
