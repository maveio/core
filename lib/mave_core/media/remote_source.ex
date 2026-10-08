defmodule MaveCore.Media.RemoteSource do
  @moduledoc false

  alias MaveCore.PublicHttpUrl
  alias MaveCore.SafeFile

  @default_max_bytes 20 * 1024 * 1024 * 1024
  @too_large_private_key :mave_core_media_input_too_large
  @bytes_private_key :mave_core_media_input_bytes

  @spec max_bytes() :: pos_integer()
  def max_bytes do
    :mave_core
    |> Application.get_env(:media_input, [])
    |> config_value(:max_bytes, @default_max_bytes)
    |> positive_integer(@default_max_bytes)
  end

  @spec download_to_file(String.t(), String.t(), keyword()) ::
          {:ok, %{bytes: non_neg_integer(), headers: map()}} | {:error, term()}
  def download_to_file(url, destination_path, opts \\ [])

  def download_to_file(url, destination_path, opts)
      when is_binary(url) and is_binary(destination_path) and is_list(opts) do
    max_bytes = positive_integer(Keyword.get(opts, :max_bytes), max_bytes())

    with {:ok, path} <- SafeFile.writable_path(destination_path),
         {:ok, file} <- File.open(path, [:write, :binary]) do
      result =
        try do
          request_to_file(url, file, max_bytes, opts)
        after
          _ = File.close(file)
        end

      case result do
        {:ok, _download} = success ->
          success

        {:error, _reason} = error ->
          _ = SafeFile.rm(path)
          error
      end
    end
  end

  def download_to_file(_url, _destination_path, _opts), do: {:error, :invalid_remote_source}

  defp request_to_file(url, file, max_bytes, opts) do
    request_options =
      [
        into: bounded_file_body(file, max_bytes),
        raw: true,
        decode_body: false,
        retry: false,
        connect_options: [timeout: Keyword.get(opts, :connect_timeout, 10_000)],
        receive_timeout: Keyword.get(opts, :receive_timeout, 60_000)
      ]

    with {:ok, request_options} <- PublicHttpUrl.req_options(url, request_options),
         {:ok, response} <- Req.get(request_options) do
      response_result(response, max_bytes)
    else
      {:error, reason} -> {:error, normalize_request_error(reason)}
    end
  end

  defp response_result(%Req.Response{} = response, max_bytes) do
    cond do
      Req.Response.get_private(response, @too_large_private_key, false) ->
        {:error, {:media_input_too_large, max_bytes}}

      response.status in 200..299 ->
        {:ok,
         %{
           bytes: Req.Response.get_private(response, @bytes_private_key, 0),
           headers: response.headers
         }}

      true ->
        {:error, {:http_error, response.status}}
    end
  end

  defp bounded_file_body(file, max_bytes) do
    fn {:data, data}, {request, %Req.Response{} = response} when is_binary(data) ->
      received = Req.Response.get_private(response, @bytes_private_key, 0)

      if declared_too_large?(response, max_bytes) or received + byte_size(data) > max_bytes do
        response = Req.Response.put_private(response, @too_large_private_key, true)
        {:halt, {request, response}}
      else
        write_chunk(file, data, received, request, response)
      end
    end
  end

  defp write_chunk(file, data, received, request, response) do
    case IO.binwrite(file, data) do
      :ok ->
        response =
          Req.Response.put_private(response, @bytes_private_key, received + byte_size(data))

        {:cont, {request, response}}

      {:error, reason} ->
        raise File.Error, reason: reason, action: "write", path: "remote media input"
    end
  end

  defp declared_too_large?(response, max_bytes) do
    response
    |> Req.Response.get_header("content-length")
    |> List.first()
    |> parse_content_length()
    |> case do
      size when is_integer(size) -> size > max_bytes
      _unknown -> false
    end
  end

  defp parse_content_length(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {size, ""} when size >= 0 -> size
      _other -> nil
    end
  end

  defp parse_content_length(_value), do: nil

  defp normalize_request_error({:blocked_address, _address} = reason),
    do: {:unsafe_source_url, reason}

  defp normalize_request_error(:invalid_http_url), do: {:unsafe_source_url, :invalid_http_url}

  defp normalize_request_error(:no_resolved_addresses),
    do: {:unsafe_source_url, :no_resolved_addresses}

  defp normalize_request_error({:resolve_failed, _reason} = reason),
    do: {:unsafe_source_url, reason}

  defp normalize_request_error(reason), do: reason

  defp config_value(config, key, default) when is_map(config),
    do: Map.get(config, key, Map.get(config, Atom.to_string(key), default))

  defp config_value(config, key, default) when is_list(config),
    do: Keyword.get(config, key, default)

  defp config_value(_config, _key, default), do: default

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default
end
