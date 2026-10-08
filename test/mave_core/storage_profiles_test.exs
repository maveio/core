defmodule MaveCore.StorageProfilesTest do
  use ExUnit.Case, async: true

  alias MaveCore.Spaces.Space
  alias MaveCore.StorageProfiles

  test "defaults to the configured default storage profile" do
    old_default_storage_profile = Application.get_env(:mave_core, :default_storage_profile)
    old_default_region = Application.get_env(:mave_core, :default_region)

    Application.put_env(:mave_core, :default_storage_profile, "default")
    Application.put_env(:mave_core, :default_region, "eu")

    on_exit(fn ->
      restore_env(:default_storage_profile, old_default_storage_profile)
      restore_env(:default_region, old_default_region)
    end)

    assert StorageProfiles.default() == "default"
    assert StorageProfiles.resolve(nil) == "default"
    assert StorageProfiles.resolve("") == "default"
  end

  test "resolves legacy region values as storage profiles for now" do
    assert StorageProfiles.resolve("eu") == "eu"
    assert StorageProfiles.resolve(:world) == "world"
    assert StorageProfiles.for_space(%Space{region: "eu_3"}) == "eu_3"
  end

  test "prefers explicit storage_profile in run input" do
    assert StorageProfiles.from_run_input(%{"storage_profile" => "cloudflare_eu"}) ==
             "cloudflare_eu"

    assert StorageProfiles.from_run_input(%{"region" => "eu"}) == "eu"
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)
end
