defmodule MaveCoreWeb.Api.Upload.TusdHooksController do
  use MaveCoreWeb, :controller

  require Logger

  alias MaveCore.Uploads

  def create(conn, params) do
    if authorized?(params) do
      handle_hook(conn, params)
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Forbidden"})
    end
  end

  defp handle_hook(conn, %{"Type" => "pre-create"} = params) do
    case Uploads.authorize_tusd_hook(params, endpoint: conn.private[:phoenix_endpoint]) do
      {:ok, scope} ->
        json(conn, Uploads.pre_create_hook_response(params, scope))

      {:error, reason} ->
        Logger.warning("Rejected tusd upload create hook: #{inspect(reason)}")
        json(conn, reject_upload_response(reason))
    end
  end

  defp handle_hook(conn, params) do
    case Uploads.process_tusd_hook(params, endpoint: conn.private[:phoenix_endpoint]) do
      {:ok, :ignored} ->
        conn
        |> put_status(:ok)
        |> json(%{status: "ok", action: "ignored"})

      {:ok, result} ->
        conn
        |> put_status(:ok)
        |> json(Map.put(result, :status, "ok"))

      {:error, reason} ->
        Logger.error("Failed to process tusd hook: #{inspect(reason)}")

        conn
        |> put_status(:ok)
        |> json(%{status: "error", error: inspect(reason)})
    end
  end

  defp reject_upload_response(reason) do
    {status_code, body} = reject_upload_http_response(reason)

    %{
      RejectUpload: true,
      HTTPResponse: %{
        StatusCode: status_code,
        Body: Jason.encode!(body),
        Header: %{"Content-Type" => "application/json"}
      }
    }
  end

  defp reject_upload_http_response(:upload_file_size_limit_exceeded),
    do: {413, %{error: "upload file size limit exceeded"}}

  defp reject_upload_http_response(:upload_size_required),
    do: {413, %{error: "upload size is required"}}

  defp reject_upload_http_response(_reason),
    do: {403, %{error: "upload authentication failed"}}

  defp authorized?(params) do
    expected_secret =
      :mave_core
      |> Application.get_env(:upload, [])
      |> Keyword.get(:hook_secret)

    supplied_secret = params["secret"]

    is_binary(expected_secret) and String.trim(expected_secret) != "" and
      is_binary(supplied_secret) and byte_size(supplied_secret) == byte_size(expected_secret) and
      Plug.Crypto.secure_compare(supplied_secret, expected_secret)
  end
end
