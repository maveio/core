defmodule MaveCoreWeb.Api.Data.EventsController do
  use MaveCoreWeb, :controller

  plug MaveCoreWeb.Plugs.EventIngestRateLimit when action in [:create]

  alias MaveCore.Metrics.IngestionBuffer
  alias MaveCoreWeb.Api.Data.EventIngest

  action_fallback MaveCoreWeb.FallbackController

  # POST /api/v1/events
  def create(conn, %{"events" => events}) when is_list(events) do
    user_agent = get_req_header(conn, "user-agent") |> List.first() || ""

    case EventIngest.validate_and_enrich(events, user_agent) do
      {:ok, enriched_events} ->
        country = viewer_country(conn)
        IngestionBuffer.push(Enum.map(enriched_events, &Map.put(&1, "country", country)))
        send_resp(conn, :accepted, "")

      {:error, :too_many_events} ->
        conn
        |> put_status(:request_entity_too_large)
        |> json(%{error: "too_many_events"})

      {:error, {:invalid_event, idx, reason}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_event", index: idx, reason: inspect(reason)})

      {:error, :invalid_payload} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid payload, expected 'events' list"})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Invalid payload, expected 'events' list"})
  end

  # Only a header set by the deployment's own proxy or CDN is used; a country
  # sent in the event body is always overwritten.
  defp viewer_country(conn) do
    case Application.get_env(:mave_core, :viewer_country_header) do
      header when is_binary(header) and header != "" ->
        conn |> get_req_header(header) |> List.first()

      _ ->
        nil
    end
  end
end
