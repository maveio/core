defmodule MaveCoreWeb.Api.EncodingBoosterHLSUploadController do
  use MaveCoreWeb, :controller

  alias MaveCore.EncodingBooster.HLSUpload

  def create(conn, %{"files" => files}) when is_list(files) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, uploads} <- HLSUpload.authorize(token, files) do
      json(conn, %{"uploads" => uploads})
    else
      {:error, :missing_token} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{"error" => "unauthorized"})

      {:error, :invalid_hls_upload_token} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{"error" => "unauthorized"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"error" => error_message(reason)})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{"error" => "invalid HLS upload request"})
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      _other -> {:error, :missing_token}
    end
  end

  defp error_message({:hls_upload_presign_failed, _name, _reason}),
    do: "could not authorize HLS upload"

  defp error_message(_reason), do: "invalid HLS upload request"
end
