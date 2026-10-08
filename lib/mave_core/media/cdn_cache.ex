defmodule MaveCore.Media.CdnCache do
  @moduledoc """
  Runtime hook for CDN cache invalidation.

  Core stays provider-neutral. Deployments that have a CDN can configure
  `:mave_core, :cdn_cache_purger` with either a module exposing
  `purge_cache/3` or a three-arity function.
  """

  require Logger

  alias MaveCore.Spaces.Space

  @type purge_result :: :ok | {:error, term()}

  @spec configured?() :: boolean()
  def configured?, do: not is_nil(purger())

  @spec purge(Space.t() | String.t(), String.t() | nil, [String.t()] | String.t()) ::
          purge_result()
  def purge(space_or_hash, region, paths) do
    paths = normalize_paths(paths)

    cond do
      paths == [] ->
        :ok

      not valid_space_target?(space_or_hash) ->
        {:error, :missing_space_hash}

      true ->
        case purger() do
          nil ->
            {:error, :cdn_cache_purger_not_configured}

          module when is_atom(module) ->
            module.purge_cache(space_or_hash, purge_region(space_or_hash, region), paths)

          fun when is_function(fun, 3) ->
            fun.(space_or_hash, purge_region(space_or_hash, region), paths)

          other ->
            {:error, {:invalid_cdn_cache_purger, inspect(other)}}
        end
    end
  end

  @spec purge_best_effort(Space.t() | String.t(), String.t() | nil, [String.t()] | String.t()) ::
          :ok
  def purge_best_effort(space_or_hash, region, paths) do
    case purge(space_or_hash, region, paths) do
      :ok ->
        :ok

      {:error, :cdn_cache_purger_not_configured} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to purge CDN cache for space #{space_label(space_or_hash)}: #{inspect(reason)}"
        )

        :ok
    end
  end

  @spec normalize_paths([String.t()] | String.t() | term()) :: [String.t()]
  def normalize_paths(paths) when is_list(paths) do
    paths
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize_path/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def normalize_paths(path) when is_binary(path), do: normalize_paths([path])
  def normalize_paths(_paths), do: []

  defp normalize_path(path) do
    path
    |> String.trim()
    |> String.trim_leading("/")
  end

  defp valid_space_target?(%Space{id: id}), do: is_binary(id)

  defp valid_space_target?(space_hash),
    do: is_binary(space_hash) and String.trim(space_hash) != ""

  defp purge_region(%Space{region: space_region}, nil), do: space_region
  defp purge_region(_space_or_hash, region), do: region

  defp space_label(%Space{id: id, hash: hash}), do: "#{hash || "unknown"}:#{id}"
  defp space_label(space_hash), do: space_hash

  defp purger do
    Application.get_env(:mave_core, :cdn_cache_purger)
  end
end
