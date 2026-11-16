defmodule MaveCore.DeliveryStandby.Plan do
  @moduledoc """
  Compares one space's primary bucket with its standby copy.

  The standby may only hold objects that are public for everyone: the prefixes
  of embeds whose public playback is confirmed, plus the shared player themes.
  Everything else found on the standby is revoked, whatever the primary holds.
  """

  @shared_prefixes ["themes"]

  defstruct copy: [], revoke: [], orphaned: [], current: [], in_sync: 0, in_sync_bytes: 0

  @type object :: %{
          required(:key) => String.t(),
          required(:size_bytes) => non_neg_integer(),
          optional(:etag) => String.t() | nil,
          optional(:last_modified) => DateTime.t() | nil
        }

  @type t :: %__MODULE__{
          copy: [{:missing | :stale, object()}],
          revoke: [object()],
          orphaned: [object()],
          current: [object()],
          in_sync: non_neg_integer(),
          in_sync_bytes: non_neg_integer()
        }

  @doc """
  Builds the plan from both object listings and the hashes of the space's
  public embeds.

  `copy` holds public objects the standby misses or holds in an older state,
  `current` holds the ones it already serves, `revoke` holds standby objects
  that are not public, and `orphaned` holds standby objects of public embeds
  that the primary no longer has.
  """
  @spec build([object()], [object()], Enumerable.t()) :: t()
  def build(primary_objects, standby_objects, public_embed_hashes) do
    public = MapSet.new(public_embed_hashes)
    standby = Map.new(standby_objects, &{&1.key, &1})
    publishable = Enum.filter(primary_objects, &publishable?(&1.key, public))
    primary_keys = MapSet.new(publishable, & &1.key)

    {copy, in_sync} =
      Enum.reduce(publishable, {[], []}, fn object, {copy, in_sync} ->
        case Map.get(standby, object.key) do
          nil -> {[{:missing, object} | copy], in_sync}
          existing -> compare(object, existing, copy, in_sync)
        end
      end)

    {revoke, orphaned} =
      standby_objects
      |> Enum.reject(&MapSet.member?(primary_keys, &1.key))
      |> Enum.split_with(&(not publishable?(&1.key, public)))

    %__MODULE__{
      copy: Enum.reverse(copy),
      revoke: revoke,
      orphaned: orphaned,
      current: in_sync,
      in_sync: length(in_sync),
      in_sync_bytes: in_sync |> Enum.map(& &1.size_bytes) |> Enum.sum()
    }
  end

  @doc "Reports whether a key may be stored on the standby."
  @spec publishable?(String.t(), MapSet.t()) :: boolean()
  def publishable?(key, %MapSet{} = public_embed_hashes) when is_binary(key) do
    case String.split(key, "/", parts: 2) do
      [prefix, rest] when rest != "" ->
        prefix in @shared_prefixes or MapSet.member?(public_embed_hashes, prefix)

      _top_level_object ->
        false
    end
  end

  @doc """
  Reports whether the standby object can stand in for the primary object.

  Single-part uploads carry an MD5 ETag that settles the question. Multipart
  ETags depend on the part size and differ between providers, so those objects
  count as current when the size matches and the copy is not older.
  """
  @spec current?(object(), object()) :: boolean()
  def current?(%{size_bytes: size} = primary, %{size_bytes: size} = standby) do
    case {md5_etag(primary), md5_etag(standby)} do
      {etag, etag} when is_binary(etag) -> true
      {left, right} when is_binary(left) and is_binary(right) -> false
      _multipart -> not older?(standby, primary)
    end
  end

  def current?(_primary, _standby), do: false

  defp compare(object, existing, copy, in_sync) do
    if current?(object, existing),
      do: {copy, [object | in_sync]},
      else: {[{:stale, object} | copy], in_sync}
  end

  defp md5_etag(%{etag: etag}) when is_binary(etag) do
    if Regex.match?(~r/\A[0-9a-f]{32}\z/i, etag), do: String.downcase(etag)
  end

  defp md5_etag(_object), do: nil

  defp older?(%{last_modified: %DateTime{} = standby}, %{last_modified: %DateTime{} = primary}),
    do: DateTime.compare(standby, primary) == :lt

  defp older?(_standby, _primary), do: false
end
