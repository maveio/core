defmodule MaveCoreWeb.Plugs.PasswordPlaybackRateLimit do
  @moduledoc false
  import Plug.Conn

  alias MaveCore.RateLimit
  alias MaveCoreWeb.Plugs.EventIngestRateLimit

  def call(conn, embed_id) do
    config = Application.get_env(:mave_core, __MODULE__, [])
    interval = Keyword.get(config, :interval_ms, 60_000)
    ip = :crypto.hash(:sha256, EventIngestRateLimit.client_ip_string(conn))

    with {:allow, _} <-
           RateLimit.hit({:password_playback_ip, ip}, interval, config[:per_ip] || 30),
         {:allow, _} <-
           RateLimit.hit(
             {:password_playback_embed, embed_id, ip},
             interval,
             config[:per_embed_ip] || 5
           ) do
      conn
    else
      {:deny, timeout_ms} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(max(div(timeout_ms + 999, 1000), 1)))
        |> put_resp_content_type("application/json")
        |> send_resp(429, Jason.encode!(%{error: "rate_limited"}))
        |> halt()
    end
  end
end
