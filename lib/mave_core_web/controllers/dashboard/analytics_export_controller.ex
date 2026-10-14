defmodule MaveCoreWeb.Dashboard.AnalyticsExportController do
  @moduledoc false
  use MaveCoreWeb, :controller

  alias MaveCore.Accounts
  alias MaveCore.Analytics.Export
  alias MaveCore.Analytics.Range
  alias MaveCore.LegacyShortUUID
  alias MaveCore.Spaces.Space
  alias MaveCore.UsageLimits

  def download(conn, params) do
    with {:ok, space} <- resolve_space(conn.assigns.current_user, params),
         :ok <- UsageLimits.can_view_space_data?(space),
         {:ok, %Range{} = range} <- Range.parse(params) do
      stream_export(conn, space, range)
    else
      {:error, :invalid_range} ->
        conn |> put_status(:unprocessable_entity) |> text(Range.error_message())

      {:ok, nil} ->
        conn |> put_status(:unprocessable_entity) |> text(Range.error_message())

      :error ->
        send_resp(conn, :not_found, "Space not found")

      {:error, :missing_space} ->
        send_resp(conn, :not_found, "Space not found")

      {:error, _reason} ->
        send_resp(conn, :forbidden, "This space cannot export aggregate data.")
    end
  end

  defp stream_export(conn, space, range) do
    conn =
      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header(
        "content-disposition",
        "attachment; filename=\"video-analytics-#{range.from}-#{range.to}.csv\""
      )
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("x-content-type-options", "nosniff")

    space
    |> Export.batches(range)
    |> Enum.reduce_while({:pending, conn}, &send_batch/2)
    |> finish_export()
  end

  defp send_batch({:error, :analytics_unavailable}, {:pending, conn}) do
    conn =
      conn
      |> delete_resp_header("content-disposition")
      |> put_resp_content_type("text/plain")
      |> send_resp(:service_unavailable, "Analytics are temporarily unavailable.")

    {:halt, {:finished, conn}}
  end

  defp send_batch({:error, :analytics_unavailable}, _state) do
    # Abort an already-started response rather than deliver a successful-looking,
    # truncated CSV when a later analytics batch fails.
    raise "Analytics export interrupted"
  end

  defp send_batch({:ok, rows}, {:pending, conn}) do
    conn = send_chunked(conn, :ok)
    send_batch({:ok, [Export.header(), rows]}, {:started, conn})
  end

  defp send_batch({:ok, rows}, {:started, conn}) do
    case chunk(conn, rows) do
      {:ok, conn} -> {:cont, {:started, conn}}
      {:error, _reason} -> {:halt, {:finished, conn}}
    end
  end

  defp finish_export({:pending, conn}) do
    {_action, {_state, conn}} = send_batch({:ok, []}, {:pending, conn})
    conn
  end

  defp finish_export({_state, conn}), do: conn

  defp resolve_space(user, %{"space_id" => id}) do
    with {:ok, id} <- LegacyShortUUID.cast(id),
         {:ok, user} <- Accounts.set_current_space_by_id(user, id) do
      current_space(user)
    end
  end

  defp resolve_space(user, _params) do
    with {:ok, user} <- Accounts.ensure_default_space(user) do
      current_space(user)
    end
  end

  defp current_space(%{current_space_membership: %{space: %Space{} = space}}), do: {:ok, space}
  defp current_space(_user), do: {:error, :missing_space}
end
