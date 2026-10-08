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
        IngestionBuffer.push(enriched_events)
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
end
