defmodule MaveCoreWeb.UserSessionController do
  use MaveCoreWeb, :controller

  alias MaveCoreWeb.UserAuth

  def delete(conn, _params) do
    UserAuth.log_out_user(conn)
  end
end
