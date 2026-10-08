defmodule MaveCore.Media.ImageVariantBudget do
  @moduledoc """
  Durable bounds for generated public image variants.

  The space row is locked while reserving a path, so concurrent requests on
  different application nodes cannot race past the aggregate limits.
  """

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias MaveCore.Embeds.Embed
  alias MaveCore.Media.ImageVariant
  alias MaveCore.Repo
  alias MaveCore.Spaces.Space

  @default_per_embed 1_000
  @default_per_space 10_000
  @default_per_installation 50_000

  @type reservation :: :new | :existing

  @spec reserve(String.t(), String.t(), String.t()) ::
          {:ok, reservation()} | {:error, :limit_reached | :not_found | {:unavailable, term()}}
  def reserve(space_hash, embed_hash, output_path)
      when is_binary(space_hash) and is_binary(embed_hash) and is_binary(output_path) do
    Repo.transaction(fn ->
      lock_installation_budget()

      with %Space{} = space <- lock_space(space_hash),
           %Embed{} = embed <- active_embed(space.id, embed_hash) do
        reserve_path(space.id, embed.id, output_path)
      else
        nil -> Repo.rollback(:not_found)
      end
    end)
    |> case do
      {:ok, reservation} -> {:ok, reservation}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, {:unavailable, error}}
  catch
    :exit, reason -> {:error, {:unavailable, reason}}
  end

  defp lock_space(space_hash) do
    from(space in Space,
      where: space.hash == ^space_hash and is_nil(space.deleted_at),
      lock: "FOR UPDATE"
    )
    |> Repo.one()
  end

  defp active_embed(space_id, embed_hash) do
    from(embed in Embed,
      where:
        embed.space_id == ^space_id and embed.hash == ^embed_hash and is_nil(embed.deleted_at)
    )
    |> Repo.one()
  end

  defp reserve_path(space_id, embed_id, output_path) do
    if reserved?(embed_id, output_path) do
      :existing
    else
      enforce_limit!(embed_id, :embed_id, config(:per_embed, @default_per_embed))
      enforce_limit!(space_id, :space_id, config(:per_space, @default_per_space))
      enforce_installation_limit!(config(:per_installation, @default_per_installation))

      %ImageVariant{}
      |> Ecto.Changeset.change(%{
        space_id: space_id,
        embed_id: embed_id,
        output_path: output_path
      })
      |> Repo.insert!()

      :new
    end
  end

  defp reserved?(embed_id, output_path) do
    Repo.exists?(
      from variant in ImageVariant,
        where: variant.embed_id == ^embed_id and variant.output_path == ^output_path
    )
  end

  defp enforce_limit!(id, field, limit) do
    count =
      from(variant in ImageVariant, where: field(variant, ^field) == ^id)
      |> Repo.aggregate(:count, :id)

    if count >= limit, do: Repo.rollback(:limit_reached)
  end

  defp enforce_installation_limit!(limit) do
    if Repo.aggregate(ImageVariant, :count, :id) >= limit do
      Repo.rollback(:limit_reached)
    end
  end

  defp lock_installation_budget do
    SQL.query!(
      Repo,
      "SELECT pg_advisory_xact_lock(hashtext('mave:image-variant-budget'))",
      []
    )
  end

  defp config(key, default) do
    :mave_core
    |> Application.get_env(:image_variant_budget, [])
    |> Keyword.get(key, default)
    |> validate_limit!(key)
  end

  defp validate_limit!(value, _key) when is_integer(value) and value > 0, do: value

  defp validate_limit!(value, key) do
    raise ArgumentError, "invalid image variant budget #{key}: #{inspect(value)}"
  end
end
