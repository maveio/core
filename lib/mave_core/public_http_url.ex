defmodule MaveCore.PublicHttpUrl do
  @moduledoc false

  @type address :: :inet.ip_address()
  @type error_reason ::
          :invalid_http_url
          | :no_resolved_addresses
          | {:blocked_address, address()}
          | {:resolve_failed, term()}

  @spec validate(String.t()) :: :ok | {:error, error_reason()}
  def validate(url) when is_binary(url) do
    with {:ok, _uri, _address} <- resolve(url), do: :ok
  end

  def validate(_url), do: {:error, :invalid_http_url}

  @spec validate_if_remote(String.t()) :: :ok | {:error, error_reason()}
  def validate_if_remote(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme} when scheme in ["http", "https"] -> validate(url)
      _ -> :ok
    end
  end

  def validate_if_remote(_url), do: :ok

  @spec req_options(String.t(), keyword()) :: {:ok, keyword()} | {:error, error_reason()}
  def req_options(url, opts \\ [])

  def req_options(url, opts) when is_binary(url) and is_list(opts) do
    with {:ok, uri, address} <- resolve(url) do
      opts =
        opts
        |> Keyword.put(:url, pinned_url(uri, address))
        |> Keyword.put(:redirect, false)
        |> put_connect_options(uri, address)
        |> put_auth_options(uri)

      {:ok, opts}
    end
  end

  def req_options(_url, _opts), do: {:error, :invalid_http_url}

  @spec default_resolve(String.t()) :: {:ok, [address()]} | {:error, term()}
  def default_resolve(host) when is_binary(host) do
    host_charlist = String.to_charlist(host)

    addresses =
      [:inet, :inet6]
      |> Enum.flat_map(fn family ->
        case :inet.getaddrs(host_charlist, family) do
          {:ok, addresses} -> addresses
          {:error, _reason} -> []
        end
      end)
      |> Enum.uniq()

    case addresses do
      [_ | _] -> {:ok, addresses}
      [] -> {:error, :nxdomain}
    end
  end

  def default_resolve(_host), do: {:error, :invalid_host}

  defp resolve(url) do
    with {:ok, uri} <- parse_http_url(url),
         {:ok, addresses} <- resolve_host(uri.host),
         :ok <- validate_addresses(addresses) do
      {:ok, uri, List.first(addresses)}
    end
  end

  defp parse_http_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, uri}

      _ ->
        {:error, :invalid_http_url}
    end
  end

  defp resolve_host(host) do
    case parse_address(host) do
      {:ok, address} -> {:ok, [address]}
      {:error, _reason} -> resolve_hostname(host)
    end
  end

  defp parse_address(host) do
    host
    |> String.to_charlist()
    |> :inet.parse_address()
  end

  defp resolve_hostname(host) do
    case configured_resolver().(host) do
      {:ok, [_ | _] = addresses} -> {:ok, Enum.uniq(addresses)}
      {:ok, []} -> {:error, :no_resolved_addresses}
      {:error, reason} -> {:error, {:resolve_failed, reason}}
      other -> {:error, {:resolve_failed, other}}
    end
  end

  defp configured_resolver do
    case Application.get_env(:mave_core, :public_http_url_resolver) do
      resolver when is_function(resolver, 1) ->
        resolver

      {module, function} when is_atom(module) and is_atom(function) ->
        fn host -> apply(module, function, [host]) end

      _ ->
        &default_resolve/1
    end
  end

  defp validate_addresses([_ | _] = addresses) do
    case Enum.find(addresses, &(not public_address?(&1))) do
      nil -> :ok
      address -> {:error, {:blocked_address, address}}
    end
  end

  defp validate_addresses(_), do: {:error, :no_resolved_addresses}

  defp pinned_url(%URI{} = uri, address) do
    uri
    |> Map.put(:host, address_host(address))
    |> Map.put(:authority, nil)
    |> Map.put(:userinfo, nil)
    |> URI.to_string()
  end

  defp address_host(address), do: address |> :inet.ntoa() |> to_string()

  defp put_connect_options(opts, %URI{host: host}, address) do
    connect_options =
      opts
      |> Keyword.get(:connect_options, [])
      |> Keyword.put(:hostname, host)
      |> put_transport_options(address)

    Keyword.put(opts, :connect_options, connect_options)
  end

  defp put_transport_options(connect_options, address) do
    transport_options = Keyword.get(connect_options, :transport_opts, [])

    transport_options =
      if ipv6?(address) do
        Keyword.put(transport_options, :inet6, true)
      else
        transport_options
      end

    if transport_options == [] do
      connect_options
    else
      Keyword.put(connect_options, :transport_opts, transport_options)
    end
  end

  defp put_auth_options(opts, %URI{userinfo: userinfo})
       when is_binary(userinfo) and userinfo != "" do
    if Keyword.has_key?(opts, :auth) or authorization_header?(Keyword.get(opts, :headers, [])) do
      opts
    else
      Keyword.put(opts, :auth, {:basic, URI.decode(userinfo)})
    end
  end

  defp put_auth_options(opts, _uri), do: opts

  defp authorization_header?(headers) when is_list(headers) do
    Enum.any?(headers, fn
      {name, _value} -> String.downcase(to_string(name)) == "authorization"
      _other -> false
    end)
  end

  defp authorization_header?(headers) when is_map(headers) do
    headers
    |> Map.keys()
    |> Enum.any?(&(String.downcase(to_string(&1)) == "authorization"))
  end

  defp authorization_header?(_headers), do: false

  defp ipv6?({_a, _b, _c, _d, _e, _f, _g, _h}), do: true
  defp ipv6?(_address), do: false

  defp public_address?({_a, _b, _c, _d} = address), do: not blocked_ipv4?(address)

  defp public_address?({a, _b, _c, _d, _e, _f, _g, _h} = address) when a in 0x2000..0x3FFF,
    do: not blocked_ipv6?(address)

  defp public_address?({_a, _b, _c, _d, _e, _f, _g, _h}), do: false
  defp public_address?(_address), do: false

  defp blocked_ipv4?(address) do
    unroutable_ipv4?(address) or private_ipv4?(address) or shared_ipv4?(address) or
      link_local_ipv4?(address) or documentation_ipv4?(address) or benchmark_ipv4?(address) or
      reserved_ipv4?(address)
  end

  defp unroutable_ipv4?({0, _b, _c, _d}), do: true
  defp unroutable_ipv4?({127, _b, _c, _d}), do: true
  defp unroutable_ipv4?({_a, _b, _c, _d}), do: false

  defp private_ipv4?({10, _b, _c, _d}), do: true
  defp private_ipv4?({172, b, _c, _d}) when b in 16..31, do: true
  defp private_ipv4?({192, 168, _c, _d}), do: true
  defp private_ipv4?({_a, _b, _c, _d}), do: false

  defp shared_ipv4?({100, b, _c, _d}) when b in 64..127, do: true
  defp shared_ipv4?({_a, _b, _c, _d}), do: false

  defp link_local_ipv4?({169, 254, _c, _d}), do: true
  defp link_local_ipv4?({_a, _b, _c, _d}), do: false

  defp documentation_ipv4?({192, 0, _c, _d}), do: true
  defp documentation_ipv4?({192, 88, 99, _d}), do: true
  defp documentation_ipv4?({198, 51, 100, _d}), do: true
  defp documentation_ipv4?({203, 0, 113, _d}), do: true
  defp documentation_ipv4?({_a, _b, _c, _d}), do: false

  defp benchmark_ipv4?({198, b, _c, _d}) when b in 18..19, do: true
  defp benchmark_ipv4?({_a, _b, _c, _d}), do: false

  defp reserved_ipv4?({a, _b, _c, _d}) when a >= 224, do: true
  defp reserved_ipv4?({_a, _b, _c, _d}), do: false

  defp blocked_ipv6?({0, 0, 0, 0, 0, 0, _g, _h}), do: true
  defp blocked_ipv6?({0, 0, 0, 0, 0, 0xFFFF, _g, _h}), do: true
  defp blocked_ipv6?({0x2001, 0x0DB8, _c, _d, _e, _f, _g, _h}), do: true
  defp blocked_ipv6?({0x2001, b, _c, _d, _e, _f, _g, _h}) when b in 0x0000..0x001F, do: true
  defp blocked_ipv6?({0x2002, _b, _c, _d, _e, _f, _g, _h}), do: true
  defp blocked_ipv6?({a, _b, _c, _d, _e, _f, _g, _h}) when a in 0xFC00..0xFDFF, do: true
  defp blocked_ipv6?({a, _b, _c, _d, _e, _f, _g, _h}) when a in 0xFE80..0xFEBF, do: true
  defp blocked_ipv6?({a, _b, _c, _d, _e, _f, _g, _h}) when a in 0xFF00..0xFFFF, do: true
  defp blocked_ipv6?({_a, _b, _c, _d, _e, _f, _g, _h}), do: false
end
