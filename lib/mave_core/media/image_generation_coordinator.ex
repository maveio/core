defmodule MaveCore.Media.ImageGenerationCoordinator do
  @moduledoc """
  Lightweight cross-node coordination for image cache misses.

  Nebulex partitions each cache key to one owner node and backs it with a local
  ETS cache, so duplicate cache misses across clustered image/web pods can be
  coordinated without database traffic.
  """

  require Logger

  alias MaveCore.Media.ImageGenerationCache

  @default_call_timeout_ms 5_000

  def claim(cache_key, ttl_ms) when is_binary(cache_key) and is_integer(ttl_ms) and ttl_ms > 0 do
    owner_id = Ecto.UUID.generate()

    case put_new(cache_key, owner_id, ttl_ms) do
      true -> {:ok, owner_id}
      false -> :busy
      {:error, reason} -> {:error, reason}
    end
  end

  def release(cache_key, owner_id) when is_binary(cache_key) and is_binary(owner_id) do
    case release_owned(cache_key, owner_id) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_new(cache_key, owner_id, ttl_ms) do
    ImageGenerationCache.put_new!(
      cache_key,
      owner_id,
      ttl: ttl_ms,
      timeout: call_timeout_ms()
    )
  rescue
    error ->
      {:error, error}
  catch
    :exit, reason ->
      Logger.warning("Image generation coordinator unavailable: #{inspect(reason)}")
      {:error, {:coordinator_unavailable, reason}}
  end

  defp release_owned(cache_key, owner_id) do
    ImageGenerationCache.transaction(
      fn -> delete_if_owner(cache_key, owner_id) end,
      keys: [cache_key],
      timeout: call_timeout_ms()
    )
    |> normalize_release_result()
  rescue
    error ->
      {:error, error}
  catch
    :exit, reason ->
      Logger.warning("Image generation coordinator release failed: #{inspect(reason)}")
      {:error, {:coordinator_unavailable, reason}}
  end

  defp delete_if_owner(cache_key, owner_id) do
    case ImageGenerationCache.get!(cache_key, timeout: call_timeout_ms()) do
      ^owner_id -> ImageGenerationCache.delete!(cache_key, timeout: call_timeout_ms())
      _other -> :ok
    end
  end

  defp normalize_release_result({:ok, _result}), do: :ok
  defp normalize_release_result({:error, reason}), do: {:error, reason}
  defp normalize_release_result(other), do: other

  defp call_timeout_ms do
    :mave_core
    |> Application.get_env(:image_generation_singleflight, [])
    |> Access.get(:coordinator_call_timeout_ms, @default_call_timeout_ms)
  end
end
