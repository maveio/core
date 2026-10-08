defmodule MaveCoreWeb.Plugs.EventIngestRateLimit do
  @moduledoc false

  import Bitwise
  import Plug.Conn

  @defaults [
    bucket: :events,
    interval_ms: 60_000,
    max_requests: 120
  ]

  def init(opts), do: opts

  def call(conn, opts) do
    bucket = Keyword.get(opts, :bucket, @defaults[:bucket])

    config = Application.get_env(:mave_core, __MODULE__, [])

    interval_ms =
      Keyword.get(opts, :interval_ms) ||
        Keyword.get(config, :interval_ms, @defaults[:interval_ms])

    max_requests =
      Keyword.get(opts, :max_requests) ||
        Keyword.get(config, :max_requests, @defaults[:max_requests])

    key = "#{bucket}:#{client_ip_string(conn)}"

    case MaveCore.RateLimit.hit(key, interval_ms, max_requests) do
      {:allow, _count} ->
        conn

      {:deny, timeout_ms} ->
        retry_after_seconds = retry_after_seconds(timeout_ms, interval_ms)

        body =
          Phoenix.json_library().encode!(%{
            error: "rate_limited",
            retry_after_seconds: retry_after_seconds
          })

        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("retry-after", Integer.to_string(retry_after_seconds))
        |> send_resp(429, body)
        |> halt()
    end
  end

  defp client_ip_string(conn) do
    remote_ip = normalize_ip(conn.remote_ip)

    if trusted_proxy?(remote_ip) do
      forwarded_ip(conn) || ip_string(remote_ip)
    else
      ip_string(remote_ip)
    end
  end

  defp forwarded_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [header] -> parse_forwarded_for(header)
      _missing_or_ambiguous -> nil
    end
  end

  defp parse_forwarded_for(header) when is_binary(header) do
    addresses =
      header
      |> String.split(",", trim: false)
      |> Enum.map(&parse_ip/1)

    if addresses != [] and Enum.all?(addresses, &match?({:ok, _ip}, &1)) do
      addresses
      |> Enum.map(fn {:ok, ip} -> ip end)
      |> Enum.reverse()
      |> Enum.drop_while(&trusted_proxy?/1)
      |> List.first()
      |> case do
        nil -> nil
        ip -> ip_string(ip)
      end
    end
  end

  defp parse_forwarded_for(_header), do: nil

  defp parse_ip(value) when is_binary(value) do
    value = String.trim(value)

    with false <- value == "",
         {:ok, ip_tuple} <- value |> String.to_charlist() |> :inet.parse_address() do
      {:ok, normalize_ip(ip_tuple)}
    else
      _ -> :error
    end
  end

  defp parse_ip(_value), do: :error

  defp trusted_proxy?(nil), do: false

  defp trusted_proxy?(ip) do
    :mave_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:trusted_proxy_cidrs, [])
    |> Enum.any?(&ip_in_cidr?(ip, &1))
  end

  defp ip_in_cidr?(ip, cidr) when is_binary(cidr) do
    with [network_string, prefix_string] <- String.split(cidr, "/", parts: 2),
         {:ok, network} <- parse_ip(network_string),
         {prefix, ""} <- Integer.parse(prefix_string),
         {ip_integer, bits} <- ip_integer(ip),
         {network_integer, ^bits} <- ip_integer(network),
         true <- prefix >= 0 and prefix <= bits do
      mask = cidr_mask(bits, prefix)
      (ip_integer &&& mask) == (network_integer &&& mask)
    else
      _ -> false
    end
  end

  defp ip_in_cidr?(_ip, _cidr), do: false

  defp ip_integer({a, b, c, d}) do
    {Enum.reduce([a, b, c, d], 0, fn part, acc -> (acc <<< 8) + part end), 32}
  end

  defp ip_integer(ip) when tuple_size(ip) == 8 do
    {ip
     |> Tuple.to_list()
     |> Enum.reduce(0, fn part, acc -> (acc <<< 16) + part end), 128}
  end

  defp ip_integer(_ip), do: :error

  defp cidr_mask(_bits, 0), do: 0
  defp cidr_mask(bits, prefix), do: ((1 <<< prefix) - 1) <<< (bits - prefix)

  defp normalize_ip({0, 0, 0, 0, 0, 65_535, high, low}) do
    {high >>> 8, high &&& 255, low >>> 8, low &&& 255}
  end

  defp normalize_ip(ip), do: ip

  defp ip_string(nil), do: "unknown"

  defp ip_string(ip) do
    ip
    |> :inet.ntoa()
    |> to_string()
  rescue
    _ -> "unknown"
  end

  defp retry_after_seconds(timeout_ms, fallback_interval_ms) when is_integer(timeout_ms) do
    ms = if timeout_ms > 0, do: timeout_ms, else: fallback_interval_ms
    max(div(ms + 999, 1000), 1)
  end

  defp retry_after_seconds(_timeout_ms, fallback_interval_ms) do
    max(div(fallback_interval_ms + 999, 1000), 1)
  end
end
