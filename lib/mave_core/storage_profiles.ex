defmodule MaveCore.StorageProfiles do
  @moduledoc """
  Resolves the storage profile used by core for media operations.

  Legacy mave used `region` as the routing key for storage and encoder placement.
  During migration we keep those values working, but treat them as storage-profile
  identifiers internally so core can eventually run against a single default
  profile while SaaS owns richer provider mapping.
  """

  alias MaveCore.Spaces.Space

  def default do
    Application.get_env(:mave_core, :default_storage_profile) ||
      Application.get_env(:mave_core, :default_region, "default")
  end

  def resolve(nil), do: default()
  def resolve(""), do: default()

  def resolve(profile) when is_atom(profile) do
    profile
    |> Atom.to_string()
    |> resolve()
  end

  def resolve(profile) when is_binary(profile) do
    normalized = String.trim(profile)
    if normalized == "", do: default(), else: normalized
  end

  def for_space(%Space{region: region}), do: resolve(region)
  def for_space(%{region: region}), do: resolve(region)
  def for_space(_), do: default()

  def from_run_input(%{"storage_profile" => profile}), do: resolve(profile)
  def from_run_input(%{"region" => region}), do: resolve(region)
  def from_run_input(_), do: default()
end
