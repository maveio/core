defmodule MaveCore.Metrics.CdnRequest do
  @moduledoc """
  One media request as reported by the CDN or edge server.

  Core stays provider-neutral: a log shipper posts records in the shape below
  and Core attributes them to a space and video. Records that cannot be
  attributed, or that are outside the accepted time range, are dropped.

      %{
        "timestamp" => 1_794_863_000_000,          # Unix ms or ISO 8601
        "url" => "https://space-ab1cd.cdn.example/VIDEOHASH0/h264/720p/seg_4.m4s",
        "status" => 200,
        "cache_status" => "HIT",                   # provider value, normalized
        "bytes" => 734_112,                        # response bytes
        "ttfb_ms" => 23,                           # edge time to first byte
        "country" => "NL",                         # viewer country, ISO 3166-1
        "pop" => "AMS"                             # edge location
      }

  `embed_id` (space hash followed by embed hash) can replace `url`; `host` and
  `path` can replace it as well. `origin` states whether the request reached
  the origin and defaults to every request that was not served from cache.
  """

  use Ecto.Schema

  alias MaveCore.Metrics.PlaybackQuality

  @max_age_ms 31 * 24 * 60 * 60 * 1000
  @max_future_ms 10 * 60 * 1000
  @max_ttfb_ms 600_000
  @max_pop_bytes 16

  @hit ~w(hit stale revalidated updating)
  @miss ~w(miss expired)
  @bypass ~w(bypass dynamic none uncacheable pass)

  @primary_key false
  schema "cdn_requests" do
    field :timestamp, :utc_datetime_usec
    field :space_hash, :string
    field :embed_hash, :string
    field :status, Ch, type: "UInt16"
    field :cache_status, Ch, type: "LowCardinality(String)"
    field :origin, Ch, type: "UInt8"
    field :bytes, Ch, type: "UInt64"
    field :ttfb_ms, Ch, type: "UInt32"
    field :country, Ch, type: "LowCardinality(String)"
    field :pop, Ch, type: "LowCardinality(String)"
  end

  @doc "Returns the row for a reported record, or `:error` when it must be dropped."
  def normalize(record, now_ms \\ System.system_time(:millisecond))

  def normalize(record, now_ms) when is_map(record) do
    with {:ok, timestamp} <- timestamp(record["timestamp"], now_ms),
         {:ok, space_hash, embed_hash} <- target(record),
         {:ok, status} <- status(record["status"]) do
      cache_status = cache_status(record["cache_status"])

      {:ok,
       %{
         timestamp: DateTime.from_unix!(timestamp * 1000, :microsecond),
         space_hash: space_hash,
         embed_hash: embed_hash,
         status: status,
         cache_status: cache_status,
         origin: origin(record["origin"], cache_status),
         bytes: non_negative(record["bytes"]),
         ttfb_ms: min(non_negative(record["ttfb_ms"]), @max_ttfb_ms),
         country: PlaybackQuality.country(record["country"]),
         pop: pop(record["pop"])
       }}
    end
  end

  def normalize(_record, _now_ms), do: :error

  @doc "Maps a provider cache status to `hit`, `miss`, `bypass` or `unknown`."
  def cache_status(value) when is_binary(value) do
    value = value |> String.trim() |> String.downcase()

    cond do
      value in @hit -> "hit"
      value in @miss -> "miss"
      value in @bypass -> "bypass"
      true -> "unknown"
    end
  end

  def cache_status(_value), do: "unknown"

  @doc """
  Finds the space and video in a media URL. Supports the playback origin and
  public CDN layouts (`space-<hash>` as subdomain or path segment followed by
  the embed hash) and the API route `/playback/media/<embed id>/`.
  """
  def attribute(host, path) do
    segments = path |> to_string() |> String.split("/", trim: true)
    labels = host |> to_string() |> String.downcase() |> String.split(".")

    case {labels, space_segment(segments), media_segment(segments)} do
      {["space-" <> space_hash | _], _, _} -> hashes(space_hash, List.first(segments))
      {_, {space_hash, embed_hash}, _} -> hashes(space_hash, embed_hash)
      {_, _, embed_id} when is_binary(embed_id) -> split_embed_id(embed_id)
      _ -> :error
    end
  end

  defp space_segment(["space-" <> space_hash, embed_hash | _]), do: {space_hash, embed_hash}
  defp space_segment([_ | rest]), do: space_segment(rest)
  defp space_segment([]), do: nil

  defp media_segment(["playback", "media", embed_id | _]), do: embed_id
  defp media_segment([_ | rest]), do: media_segment(rest)
  defp media_segment([]), do: nil

  defp target(%{"embed_id" => embed_id}) when is_binary(embed_id), do: split_embed_id(embed_id)

  defp target(%{"url" => url}) when is_binary(url) do
    uri = URI.parse(url)
    attribute(uri.host, uri.path)
  end

  defp target(%{"path" => path} = record) when is_binary(path) do
    path = path |> String.split("?", parts: 2) |> hd()
    attribute(record["host"], path)
  end

  defp target(_record), do: :error

  defp split_embed_id(embed_id) do
    case MaveCore.EmbedId.split(embed_id) do
      {:ok, %{space_hash: space_hash, embed_hash: embed_hash}} -> hashes(space_hash, embed_hash)
      :error -> :error
    end
  end

  defp hashes(space_hash, embed_hash) when is_binary(space_hash) and is_binary(embed_hash) do
    if space_hash =~ ~r/\A[A-Za-z0-9]{5}\z/ and embed_hash =~ ~r/\A[A-Za-z0-9]{10}\z/,
      do: {:ok, space_hash, embed_hash},
      else: :error
  end

  defp hashes(_space_hash, _embed_hash), do: :error

  defp timestamp(value, now_ms) when is_integer(value) do
    if value >= now_ms - @max_age_ms and value <= now_ms + @max_future_ms,
      do: {:ok, value},
      else: :error
  end

  defp timestamp(value, now_ms) when is_float(value), do: timestamp(trunc(value), now_ms)

  defp timestamp(value, now_ms) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> timestamp(DateTime.to_unix(datetime, :millisecond), now_ms)
      _ -> :error
    end
  end

  defp timestamp(_value, _now_ms), do: :error

  defp status(value) when is_integer(value) and value in 100..599, do: {:ok, value}

  defp status(value) when is_binary(value) do
    case Integer.parse(value) do
      {status, ""} -> status(status)
      _ -> :error
    end
  end

  defp status(_value), do: :error

  defp origin(value, _cache_status) when is_boolean(value), do: if(value, do: 1, else: 0)
  defp origin(_value, cache_status), do: if(cache_status == "hit", do: 0, else: 1)

  defp non_negative(value) when is_number(value), do: value |> trunc() |> max(0)
  defp non_negative(_value), do: 0

  defp pop(value) when is_binary(value) do
    value = String.replace(value, ~r/[^A-Za-z0-9_\-]/, "")
    if byte_size(value) > @max_pop_bytes, do: binary_part(value, 0, @max_pop_bytes), else: value
  end

  defp pop(_value), do: ""
end
