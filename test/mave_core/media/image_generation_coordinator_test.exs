defmodule MaveCore.Media.ImageGenerationCoordinatorTest do
  use ExUnit.Case, async: false

  alias MaveCore.Media.ImageGenerationCache
  alias MaveCore.Media.ImageGenerationCoordinator

  test "claim returns busy until the owner releases the cache key" do
    cache_key = unique_cache_key()

    assert {:ok, owner} = ImageGenerationCoordinator.claim(cache_key, 60_000)
    assert :busy = ImageGenerationCoordinator.claim(cache_key, 60_000)

    assert :ok = ImageGenerationCoordinator.release(cache_key, owner)
    assert {:ok, _new_owner} = ImageGenerationCoordinator.claim(cache_key, 60_000)
  end

  test "release does not remove a lock owned by a different request" do
    cache_key = unique_cache_key()

    assert {:ok, owner} = ImageGenerationCoordinator.claim(cache_key, 60_000)
    assert :ok = ImageGenerationCache.put!(cache_key, "other-owner", ttl: 60_000)

    assert :ok = ImageGenerationCoordinator.release(cache_key, owner)
    assert "other-owner" = ImageGenerationCache.get!(cache_key)
  end

  defp unique_cache_key do
    "test:#{System.unique_integer([:positive, :monotonic])}"
  end
end
