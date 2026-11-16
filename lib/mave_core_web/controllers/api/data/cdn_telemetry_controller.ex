defmodule MaveCoreWeb.Api.Data.CdnTelemetryController do
  @moduledoc """
  Receives delivery telemetry from the deployment's CDN or edge log shipper.

  Disabled until `MAVE_CDN_TELEMETRY_TOKEN` is set. The token belongs to the
  operator: accepted records may refer to any space.
  """

  use MaveCoreWeb, :controller

  alias MaveCore.Metrics.CdnRequest
  alias MaveCore.Metrics.IngestionBuffer

  @max_records_per_request 2000

  # POST /internal/cdn-telemetry
  def create(conn, params) do
    with :ok <- authorize(conn),
         {:ok, records} <- records(params) do
      now_ms = System.system_time(:millisecond)

      rows =
        for record <- records,
            {:ok, row} <- [CdnRequest.normalize(record, now_ms)],
            do: row

      IngestionBuffer.push_cdn_requests(rows)

      conn
      |> put_status(:accepted)
      |> json(%{accepted: length(rows), dropped: length(records) - length(rows)})
    else
      {:error, status, error} -> conn |> put_status(status) |> json(%{error: error})
    end
  end

  defp records(%{"records" => records}) when is_list(records) do
    if length(records) > @max_records_per_request,
      do: {:error, :request_entity_too_large, "too_many_records"},
      else: {:ok, records}
  end

  defp records(_params), do: {:error, :bad_request, "Invalid payload, expected 'records' list"}

  defp authorize(conn) do
    expected = Application.get_env(:mave_core, :cdn_telemetry_token)

    case {expected, get_req_header(conn, "authorization")} do
      {expected, _header} when not is_binary(expected) or expected == "" ->
        {:error, :not_found, "cdn_telemetry_disabled"}

      {expected, ["Bearer " <> token]} ->
        if byte_size(token) == byte_size(expected) and Plug.Crypto.secure_compare(token, expected),
          do: :ok,
          else: {:error, :unauthorized, "unauthorized"}

      _missing ->
        {:error, :unauthorized, "unauthorized"}
    end
  end
end
