defmodule MaveCoreWeb.PageController do
  use MaveCoreWeb, :controller

  def health(conn, _params) do
    text(conn, "UP")
  end
end
