defmodule MaveCore.Media.CdnCacheTest do
  use ExUnit.Case, async: false

  alias MaveCore.Media.CdnCache
  alias MaveCore.Spaces.Space

  setup do
    previous_purger = Application.get_env(:mave_core, :cdn_cache_purger)

    on_exit(fn ->
      if is_nil(previous_purger) do
        Application.delete_env(:mave_core, :cdn_cache_purger)
      else
        Application.put_env(:mave_core, :cdn_cache_purger, previous_purger)
      end
    end)

    :ok
  end

  test "purge passes a concrete space through to the configured purger" do
    test_pid = self()

    Application.put_env(:mave_core, :cdn_cache_purger, fn space, region, paths ->
      send(test_pid, {:purged, space, region, paths})
      :ok
    end)

    space = %Space{id: Ecto.UUID.generate(), hash: "trial", region: "eu"}

    assert :ok = CdnCache.purge(space, nil, ["/video/"])
    assert_received {:purged, ^space, "eu", ["video/"]}
  end
end
