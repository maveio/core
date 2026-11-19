defmodule MaveCoreWeb.DeliveryController do
  @moduledoc """
  Stable public media URLs for multi-region delivery.

  `/delivery/{bucket}/{path}` redirects to the same object in the region that
  currently serves the space. Relative URLs inside playlists and manifests
  resolve against the redirect target, so only entry points pass through here.
  The redirect names a public storage URL and grants no access of its own.
  """
  use MaveCoreWeb, :controller

  alias MaveCore.MultiRegion
  alias MaveCore.MultiRegion.Delivery
  alias MaveCore.Playback.Media

  def show(conn, %{"bucket" => bucket, "path" => path}) do
    path = Enum.join(path, "/")

    with :ok <- Media.valid_path(path),
         {:ok, bucket_url} <- Delivery.resolve(bucket) do
      conn
      |> put_resp_header(
        "cache-control",
        "public, max-age=#{MultiRegion.config(:redirect_max_age_seconds)}"
      )
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_status(:found)
      |> redirect(external: bucket_url <> "/" <> path <> query_suffix(conn))
    else
      _other -> send_resp(conn, :not_found, "Media unavailable")
    end
  end

  defp query_suffix(%Plug.Conn{query_string: ""}), do: ""
  defp query_suffix(%Plug.Conn{query_string: query}), do: "?" <> query
end
