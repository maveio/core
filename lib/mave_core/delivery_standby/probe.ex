defmodule MaveCore.DeliveryStandby.Probe do
  @moduledoc """
  Requests public media URLs from the standby edge before DNS points at it.

  Each request connects to the configured edge address but keeps the public
  hostname as Host header and TLS server name. A passing probe therefore shows
  that the standby would answer the URLs embeds already use: same paths, a valid
  certificate, CORS for the player, range requests, and no access to media that
  is not public.
  """

  alias MaveCore.DeliveryStandby.Plan
  alias MaveCore.Embeds.SettingsSerializer
  alias MaveCore.Media.Storage
  alias MaveCore.Spaces.Space

  @default_probe_embeds 2
  @fallback_origin "https://standby-check.invalid"

  @doc """
  Probes one space and returns `{passed_count, findings}`.

  `context` carries the buckets, the public and private embed hashes and the
  comparison plan of the space. Without an edge URL nothing is requested.
  """
  @spec run(Space.t(), map(), String.t() | nil, keyword()) :: {non_neg_integer(), [map()]}
  def run(_space, _context, nil, _opts), do: {0, []}

  def run(%Space{} = space, %{plan: %Plan{} = plan} = context, edge_url, opts) do
    origin = allowed_origin(space)
    limit = Keyword.get(opts, :probe_embeds, @default_probe_embeds)

    public =
      plan.current
      |> embeds_with_manifest()
      |> Enum.take(limit)
      |> Enum.flat_map(&public_probes(&1, plan.current, space, origin))

    private =
      context.private_hashes
      |> Enum.sort()
      |> Enum.take(1)
      |> Enum.map(&{:not_public, "#{&1}/manifest.json", nil, allowed_headers(origin)})

    results =
      Enum.map(public ++ private, fn {kind, key, object, headers} ->
        url = SettingsSerializer.storage_object_url(context.primary_bucket, key)
        evaluate(kind, url, object, request(edge_url, url, headers, opts))
      end)

    findings =
      for {:error, code, detail} <- results do
        %{severity: :critical, code: code, space: space.hash, detail: detail}
      end

    {Enum.count(results, &(&1 == :ok)), tls_findings(space, edge_url, results) ++ findings}
  end

  defp public_probes(hash, current, space, origin) do
    manifest = Enum.find(current, &(&1.key == "#{hash}/manifest.json"))
    largest = current |> Enum.filter(&under?(&1.key, hash)) |> Enum.max_by(& &1.size_bytes)

    [
      {:manifest, manifest.key, manifest, allowed_headers(origin)},
      {:range, largest.key, largest, [{"range", "bytes=0-0"} | allowed_headers(origin)]}
    ] ++
      if space.hotlink_protection_enabled == true,
        do: [{:hotlink, manifest.key, manifest, []}],
        else: []
  end

  defp embeds_with_manifest(current) do
    current
    |> Enum.flat_map(fn object ->
      case String.split(object.key, "/") do
        [hash, "manifest.json"] -> [hash]
        _other -> []
      end
    end)
    |> Enum.sort()
  end

  defp under?(key, hash), do: String.starts_with?(key, hash <> "/")

  defp evaluate(_kind, url, _object, {:error, reason}),
    do: {:error, :edge_unreachable, "#{url} did not answer through the standby: #{reason}"}

  defp evaluate(:manifest, url, object, {:ok, response}) do
    cond do
      response.status != 200 ->
        {:error, :public_media_refused, "#{url} answered #{response.status} instead of 200"}

      byte_size(response.body) != object.size_bytes ->
        {:error, :public_media_differs, "#{url} returned a body of a different size"}

      Req.Response.get_header(response, "access-control-allow-origin") == [] ->
        {:error, :cors_missing, "#{url} answered without Access-Control-Allow-Origin"}

      true ->
        :ok
    end
  end

  defp evaluate(:range, url, object, {:ok, response}) do
    total = "/#{object.size_bytes}"

    case {response.status, Req.Response.get_header(response, "content-range")} do
      {206, [range | _rest]} ->
        if String.ends_with?(range, total),
          do: :ok,
          else:
            {:error, :public_media_differs,
             "#{url} reports #{range}, expected a total of #{object.size_bytes}"}

      {status, _range} ->
        {:error, :range_requests_unsupported, "#{url} answered #{status} to a range request"}
    end
  end

  defp evaluate(:hotlink, url, _object, {:ok, response}) do
    if response.status in [401, 403],
      do: :ok,
      else:
        {:error, :hotlink_protection_missing,
         "#{url} answered #{response.status} without a Referer; the space has hotlink protection"}
  end

  defp evaluate(:not_public, url, _object, {:ok, response}) do
    if response.status in 200..299,
      do: {:error, :not_public_served, "#{url} is not public but the standby serves it"},
      else: :ok
  end

  # A plain-HTTP edge address cannot show that the standby holds a certificate
  # for the public hostname.
  defp tls_findings(space, edge_url, results) do
    if results != [] and String.starts_with?(edge_url, "http://") and
         public_scheme(space) == "https" do
      [
        %{
          severity: :warning,
          code: :tls_not_verified,
          space: space.hash,
          detail:
            "the edge URL uses http, so the certificate for the public hostname was not tested"
        }
      ]
    else
      []
    end
  end

  defp public_scheme(space) do
    space.hash
    |> Storage.bucket_for_space()
    |> SettingsSerializer.storage_object_url("manifest.json")
    |> URI.parse()
    |> Map.get(:scheme)
  end

  defp request(edge_url, public_url, headers, opts) do
    public = URI.parse(public_url)
    edge = URI.parse(edge_url)
    url = URI.to_string(%URI{public | scheme: edge.scheme, host: edge.host, port: edge.port})

    options =
      Keyword.merge(
        [
          url: url,
          headers: [{"host", host_header(public)} | headers],
          connect_options: [timeout: 5_000, hostname: public.host],
          receive_timeout: 15_000,
          decode_body: false,
          redirect: false,
          retry: false
        ],
        Keyword.get(opts, :probe_req_options, [])
      )

    case Req.get(options) do
      {:ok, response} -> {:ok, response}
      {:error, exception} -> {:error, Exception.message(exception)}
    end
  end

  defp host_header(%URI{host: host, port: port, scheme: scheme}) do
    if port in [nil, URI.default_port(scheme)], do: host, else: "#{host}:#{port}"
  end

  defp allowed_headers(origin), do: [{"origin", origin}, {"referer", origin <> "/"}]

  defp allowed_origin(%Space{} = space) do
    domains =
      if space.hotlink_protection_enabled == true,
        do: Enum.map(space.domains, & &1.domain),
        else: ["*"]

    domains
    |> Storage.build_allowed_origins()
    |> Enum.find(@fallback_origin, &(&1 != "*"))
  end
end
