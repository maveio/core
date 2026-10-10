defmodule MaveCoreWeb.Api.ImageController do
  use MaveCoreWeb, :controller

  require Logger

  alias MaveCore.EmbedId
  alias MaveCore.Workers.ImageProcessor

  @supported_formats ~w(jpg jpeg webp avif)
  @max_time_param_bytes 32
  @max_dimension_param_bytes 10

  def show(conn, %{"mave_id" => mave_id_with_ext}) do
    # Parse mave_id: format is {space_hash}{embed_hash}.{ext}
    # Example: abc1234567890.jpg -> space_hash=abc12, embed_hash=34567890
    case parse_mave_id(mave_id_with_ext) do
      {:ok, space_hash, embed_hash, format} ->
        serve_image(conn, space_hash, embed_hash, format)

      {:error, :invalid_format} ->
        conn
        |> put_status(:bad_request)
        |> text("Unsupported format. Supported: #{Enum.join(@supported_formats, ", ")}")

      :error ->
        conn
        |> put_status(:bad_request)
        |> text("Invalid mave_id format")
    end
  end

  defp parse_mave_id(mave_id_with_ext) do
    # Extract and validate extension
    ext = Path.extname(mave_id_with_ext) |> String.trim_leading(".") |> String.downcase()

    if ext in @supported_formats do
      mave_id = Path.rootname(mave_id_with_ext)

      case EmbedId.split(mave_id) do
        {:ok, %{space_hash: space_hash, embed_hash: embed_hash}} ->
          {:ok, space_hash, embed_hash, ext}

        :error ->
          :error
      end
    else
      {:error, :invalid_format}
    end
  end

  defp serve_image(conn, space_hash, embed_hash, format) do
    with {:ok, conn} <- authorize_image(conn, space_hash, embed_hash),
         {:ok, time} <- parse_time(conn.query_params["time"]),
         {:ok, dimensions} <- parse_dimensions(conn.query_params) do
      opts = [{:format, format} | dimensions]

      ImageProcessor.process(space_hash, embed_hash, time, opts)
      |> respond_to_image_result(conn, format)
    else
      {:error, :unauthorized} ->
        conn
        |> put_resp_header("cache-control", "private, no-store")
        |> send_resp(401, "Authorization required")

      :error ->
        send_resp(conn, 400, "Invalid image parameters")
    end
  end

  defp authorize_image(conn, space_hash, embed_hash) do
    case MaveCore.Embeds.get_embed_by_hashes(space_hash, embed_hash) do
      %MaveCore.Embeds.Embed{} = embed ->
        if MaveCore.Playback.protected?(embed) do
          authorize_private_image(conn, embed)
        else
          {:ok, conn}
        end

      _ ->
        {:ok, conn}
    end
  end

  defp authorize_private_image(conn, embed) do
    case MaveCore.Playback.authorize(conn.query_params["token"], embed) do
      {:ok, _expires_at} -> {:ok, put_private(conn, :protected_playback, true)}
      _ -> {:error, :unauthorized}
    end
  end

  defp parse_time(nil), do: {:ok, 0.0}

  defp parse_time(value) when is_binary(value) and byte_size(value) <= @max_time_param_bytes do
    case Float.parse(value) do
      {time, ""} when time >= 0 -> {:ok, time}
      _ -> :error
    end
  end

  defp parse_time(_value), do: :error

  defp parse_dimensions(params) do
    with {:ok, width} <- parse_dimension(params["width"]),
         {:ok, height} <- parse_dimension(params["height"]) do
      {:ok, [width: width, height: height] |> Enum.reject(fn {_key, value} -> is_nil(value) end)}
    end
  end

  defp parse_dimension(nil), do: {:ok, nil}

  defp parse_dimension(value)
       when is_binary(value) and byte_size(value) <= @max_dimension_param_bytes do
    case Integer.parse(value) do
      {dimension, ""} when dimension > 0 -> {:ok, dimension}
      _ -> :error
    end
  end

  defp parse_dimension(_value), do: :error

  defp respond_to_image_result({:ok, _path, image_data}, conn, format) do
    conn
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header(
      "cache-control",
      if(conn.private[:protected_playback],
        do: "private, no-store",
        else: "public, max-age=604800, immutable"
      )
    )
    |> send_download(
      {:binary, image_data},
      filename: "image.#{format}",
      disposition: :inline
    )
  end

  defp respond_to_image_result({:error, :not_found}, conn, _format) do
    send_resp(conn, 404, "Not found")
  end

  defp respond_to_image_result({:error, :generation_in_progress}, conn, _format) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("retry-after", "5")
    |> send_resp(503, "Image generation in progress")
  end

  defp respond_to_image_result(
         {:error, {:rate_limited, retry_after_ms}},
         conn,
         _format
       ) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("retry-after", Integer.to_string(retry_after_seconds(retry_after_ms)))
    |> send_resp(429, "Image generation rate limit exceeded")
  end

  defp respond_to_image_result({:error, :generation_budget_unavailable}, conn, _format) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("retry-after", "5")
    |> send_resp(503, "Image generation temporarily unavailable")
  end

  defp respond_to_image_result({:error, :variant_limit_reached}, conn, _format) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(429, "Image variant limit reached")
  end

  defp respond_to_image_result({:error, :unsupported_dimensions}, conn, _format) do
    send_resp(conn, 400, "Image dimensions are unavailable for this video")
  end

  # This origin is public: reasons can name internal nodes, storage responses,
  # or exception text, so they are logged rather than returned.
  defp respond_to_image_result({:error, reason}, conn, _format) do
    Logger.error("Image generation failed for #{conn.request_path}: #{inspect(reason)}")

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(:internal_server_error)
    |> text("Failed to generate image")
  end

  defp retry_after_seconds(retry_after_ms) when is_integer(retry_after_ms) do
    max(div(retry_after_ms + 999, 1000), 1)
  end
end
