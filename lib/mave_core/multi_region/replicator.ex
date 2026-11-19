defmodule MaveCore.MultiRegion.Replicator do
  @moduledoc """
  Makes a replica bucket match the primary bucket of a space.

  The primary is the only place Core writes to, so replication is a one-way
  comparison of object listings: missing or changed objects are copied, objects
  that left the primary are deleted. Running it again is always safe.

  Only media of embeds that are publicly playable is copied, and it is removed
  from a replica when an embed is deleted or becomes private: a replica must not
  widen access. Objects that belong to no known embed stay in the primary.
  """
  import Ecto.Query

  alias MaveCore.Embeds.Embed
  alias MaveCore.Media.Storage
  alias MaveCore.MultiRegion
  alias MaveCore.Repo
  alias MaveCore.Spaces
  alias MaveCore.Spaces.Space

  @type stats :: %{
          objects: non_neg_integer(),
          bytes: non_neg_integer(),
          copied: non_neg_integer(),
          deleted: non_neg_integer()
        }

  @doc """
  Replicates the objects below `prefix` (the whole bucket by default) from the
  primary region of `space` to `region`.
  """
  @spec sync(Space.t(), String.t(), keyword()) :: {:ok, stats()} | {:error, term()}
  def sync(%Space{} = space, region, opts \\ []) when is_binary(region) do
    prefix = Keyword.get(opts, :prefix, "")
    primary = MultiRegion.primary_region(space)
    source_bucket = Storage.bucket_for_space(space.hash, primary)
    bucket = Storage.bucket_for_space(space.hash, region)

    with :ok <- distinct_buckets(region, bucket, primary, source_bucket),
         :ok <- storage().ensure_bucket(bucket, region),
         :ok <- Spaces.sync_bucket_access_for_region(space, region),
         {:ok, source} <- storage().list_objects(source_bucket, prefix, primary),
         {:ok, replica} <- storage().list_objects(bucket, prefix, region) do
      public = public_embed_hashes(space)
      source = Map.filter(source, fn {key, _object} -> public?(key, public) end)
      stale = stale_keys(source, replica)
      removed = replica |> Map.keys() |> Enum.reject(&Map.has_key?(source, &1))

      with :ok <- copy(stale, bucket, region, source_bucket, primary),
           :ok <- delete(removed, bucket, region) do
        {:ok,
         %{
           objects: map_size(source),
           bytes: source |> Map.values() |> Enum.map(&(&1.size_bytes || 0)) |> Enum.sum(),
           copied: length(stale),
           deleted: length(removed)
         }}
      end
    end
  end

  @doc "Deletes every object of the space from a region that is no longer a replica."
  @spec purge(Space.t(), String.t()) :: :ok | {:error, term()}
  def purge(%Space{} = space, region) when is_binary(region) do
    primary = MultiRegion.primary_region(space)
    bucket = Storage.bucket_for_space(space.hash, region)

    with :ok <-
           distinct_buckets(
             region,
             bucket,
             primary,
             Storage.bucket_for_space(space.hash, primary)
           ) do
      storage().delete_prefix(bucket, "", region)
    end
  end

  @doc """
  Removes one embed's media from every replica, for example before the embed is
  confirmed private. Fails when a replica cannot confirm the removal.
  """
  @spec remove_embed(Space.t(), String.t()) :: :ok | {:error, term()}
  def remove_embed(%Space{} = space, embed_hash)
      when is_binary(embed_hash) and embed_hash != "" do
    primary = MultiRegion.primary_region(space)
    source_bucket = Storage.bucket_for_space(space.hash, primary)

    Enum.reduce_while(MultiRegion.replica_regions(space), :ok, fn region, :ok ->
      bucket = Storage.bucket_for_space(space.hash, region)

      with :ok <- distinct_buckets(region, bucket, primary, source_bucket),
           :ok <- storage().delete_prefix(bucket, embed_hash <> "/", region) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, {:replica_removal_failed, region, reason}}}
      end
    end)
  end

  # Guards the deletes above: a replica that resolves to the primary bucket would
  # otherwise remove the objects it is meant to protect.
  defp distinct_buckets(region, bucket, primary, source_bucket) do
    if region == primary or Storage.same_bucket?(region, bucket, primary, source_bucket),
      do: {:error, :replica_is_primary_bucket},
      else: :ok
  end

  defp public_embed_hashes(%Space{id: space_id}) do
    from(e in Embed,
      where:
        e.space_id == ^space_id and is_nil(e.deleted_at) and
          e.playback_visibility == :public and e.playback_status == :public,
      select: e.hash
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp public?(key, public_hashes) do
    case String.split(key, "/", parts: 2) do
      [embed_hash, _rest] -> MapSet.member?(public_hashes, embed_hash)
      _other -> false
    end
  end

  defp stale_keys(source, replica) do
    source
    |> Enum.reject(fn {key, object} -> in_sync?(object, Map.get(replica, key)) end)
    |> Enum.map(fn {key, _object} -> key end)
  end

  defp in_sync?(_object, nil), do: false

  # Equal ETags prove equal content for single-part objects. Multipart ETags
  # depend on part sizes, so those fall back to the write order: a replica
  # object written after its source is current.
  defp in_sync?(source, replica) do
    source.size_bytes == replica.size_bytes and
      (same_etag?(source.etag, replica.etag) or
         not_older?(replica.last_modified, source.last_modified))
  end

  defp same_etag?(left, right), do: is_binary(left) and left != "" and left == right

  defp not_older?(%DateTime{} = replica, %DateTime{} = source),
    do: DateTime.compare(replica, source) != :lt

  defp not_older?(_replica, _source), do: false

  # Playlists and manifests go last, so a replica never points at media that has
  # not arrived yet.
  defp copy(keys, bucket, region, source_bucket, primary) do
    {indexes, media} = Enum.split_with(keys, &index?/1)

    with :ok <- copy_batch(media, bucket, region, source_bucket, primary) do
      copy_batch(indexes, bucket, region, source_bucket, primary)
    end
  end

  defp index?(key), do: Path.extname(key) in [".m3u8", ".json", ".html"]

  defp copy_batch([], _bucket, _region, _source_bucket, _primary), do: :ok

  defp copy_batch(keys, bucket, region, source_bucket, primary) do
    keys
    |> Task.async_stream(
      fn key ->
        {key,
         storage().copy_public_between_profiles(bucket, key, region, source_bucket, key, primary)}
      end,
      max_concurrency: MultiRegion.config(:copy_concurrency),
      ordered: false,
      timeout: :infinity
    )
    |> Enum.reduce_while(:ok, fn
      {:ok, {_key, :ok}}, :ok -> {:cont, :ok}
      # The object left the primary between listing and copying.
      {:ok, {_key, {:error, :not_found}}}, :ok -> {:cont, :ok}
      {:ok, {key, {:error, reason}}}, :ok -> {:halt, {:error, {:copy_failed, key, reason}}}
      {:exit, reason}, :ok -> {:halt, {:error, {:copy_failed, reason}}}
    end)
  end

  defp delete(keys, bucket, region) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      case storage().delete_object(bucket, key, region) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:delete_failed, key, reason}}}
      end
    end)
  end

  defp storage, do: Application.get_env(:mave_core, :multi_region_storage, Storage)
end
