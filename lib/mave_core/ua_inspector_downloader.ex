defmodule MaveCore.UAInspectorDownloader do
  @moduledoc false

  @behaviour UAInspector.Downloader.Adapter

  @impl UAInspector.Downloader.Adapter
  def read_remote(location) do
    with {:ok, _started} <- Application.ensure_all_started(:req) do
      case Req.get(location, decode_body: false) do
        {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
          {:ok, body}

        {:ok, %Req.Response{status: status}} ->
          {:error, {:status, status, location}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
