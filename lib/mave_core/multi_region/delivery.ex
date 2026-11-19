defmodule MaveCore.MultiRegion.Delivery do
  @moduledoc """
  Resolves where a space's public media is served from right now.

  Every storage profile has a browser-reachable base URL: its `:public_base_url`,
  an entry in `:multi_region_public_base_urls`, or its storage endpoint. The
  delivery route redirects each request to the region that currently serves the
  space, so one stable URL keeps working when delivery moves.
  """
  alias MaveCore.Media.Storage
  alias MaveCore.MultiRegion
  alias MaveCore.MultiRegion.Cache
  alias MaveCore.Spaces
  alias MaveCore.Spaces.Space

  @cache_ttl_ms 5_000
  @bucket_format ~r/\A[a-z0-9][a-z0-9.-]{0,57}([a-z0-9]{5})\z/

  @doc "Public URL of an object in the region that currently serves the space."
  def object_url(%Space{} = space, key) when is_binary(key) do
    region_object_url(space, MultiRegion.delivery_region(space), key)
  end

  @doc "Public URL of an object in one specific region of the space."
  def region_object_url(%Space{} = space, region, key) when is_binary(region) do
    case region_bucket_url(space, region) do
      nil -> nil
      bucket_url -> bucket_url <> "/" <> String.trim_leading(key, "/")
    end
  end

  @doc """
  Resolves a public bucket name, as it appears in media URLs, to the bucket URL
  of the region that currently serves that space.
  """
  @spec resolve(String.t()) :: {:ok, String.t()} | :error
  def resolve(bucket) when is_binary(bucket) do
    # Only known buckets are cached, so made-up names cannot grow the cache.
    case Cache.get({:delivery, bucket}) do
      {:ok, bucket_url} ->
        {:ok, bucket_url}

      :miss ->
        with {:ok, bucket_url} <- do_resolve(bucket) do
          Cache.put({:delivery, bucket}, bucket_url, @cache_ttl_ms)
          {:ok, bucket_url}
        end
    end
  end

  @doc """
  Base URLs that delivery may redirect to, for the dashboard's content security
  policy. Hostname placeholders become wildcards.
  """
  def public_base_urls do
    providers = Application.get_env(:mave_core, :storage_providers, %{})

    [MaveCore.StorageProfiles.default() | Enum.map(Map.keys(providers), &to_string/1)]
    |> Enum.uniq()
    |> Enum.map(&public_base_url/1)
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.replace(&1, "{bucket}", "*"))
  end

  defp do_resolve(bucket) do
    with [_bucket, hash] <- Regex.run(@bucket_format, bucket),
         %Space{} = space <- Spaces.get_space_by_hash(hash),
         true <- bucket in public_bucket_names(space),
         url when is_binary(url) <- region_bucket_url(space, MultiRegion.delivery_region(space)) do
      {:ok, url}
    else
      _other -> :error
    end
  end

  defp public_bucket_names(space) do
    primary = MultiRegion.primary_region(space)

    Enum.uniq([
      Storage.public_bucket_for_space(space.hash, primary),
      Storage.bucket_for_space(space.hash, primary)
    ])
  end

  # A base URL may place the bucket in the hostname with a `{bucket}` marker,
  # for CDNs that serve each space from its own subdomain.
  defp region_bucket_url(space, region) do
    bucket = Storage.bucket_for_space(space.hash, region)

    case public_base_url(region) do
      nil ->
        nil

      base_url ->
        if String.contains?(base_url, "{bucket}"),
          do: String.replace(base_url, "{bucket}", bucket),
          else: base_url <> "/" <> bucket
    end
  end

  defp public_base_url(region) do
    configured =
      :mave_core
      |> Application.get_env(:multi_region_public_base_urls, %{})
      |> Map.get(region)

    case configured do
      value when is_binary(value) and value != "" -> String.trim_trailing(value, "/")
      _value -> Storage.profile_public_base_url(region)
    end
  end
end
