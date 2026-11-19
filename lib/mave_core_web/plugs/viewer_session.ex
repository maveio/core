defmodule MaveCoreWeb.Plugs.ViewerSession do
  @moduledoc """
  Gives a visitor of a live stream's watch page a random id in the session.
  The chat uses it to tell viewers apart without an account: to count
  participants, limit how fast one viewer posts and keep one vote per viewer.
  """

  import Plug.Conn

  @behaviour Plug
  @key "live_viewer_id"

  def key, do: @key

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case get_session(conn, @key) do
      id when is_binary(id) and id != "" ->
        conn

      _ ->
        id = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
        put_session(conn, @key, id)
    end
  end
end
