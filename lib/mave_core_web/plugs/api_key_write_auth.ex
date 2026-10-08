defmodule MaveCoreWeb.Plugs.ApiKeyWriteAuth do
  @moduledoc false

  import Plug.Conn
  use MaveCoreWeb, :controller

  alias MaveCore.Spaces
  alias MaveCore.Spaces.Key

  def init(opts), do: opts

  def call(%{assigns: %{current_api_key: %Key{} = key}} = conn, _opts) do
    if Spaces.key_can_write?(key) do
      conn
    else
      forbidden(conn)
    end
  end

  def call(conn, _opts), do: forbidden(conn)

  defp forbidden(conn) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "This API key is read-only"})
    |> halt()
  end
end
