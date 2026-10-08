defmodule MaveCore.Media.ImageGenerationBudget do
  @moduledoc """
  Distributed per-embed budget for cache-miss image generation.

  Cached image delivery does not use this budget. Reservations are made only
  immediately before starting new FLAME work.
  """

  require Logger

  alias MaveCore.Media.ImageGenerationCache

  @default_per_minute 20
  @default_per_day 200
  @default_call_timeout_ms 5_000
  @minute_ms :timer.minutes(1)
  @day_ms :timer.hours(24)

  @type result ::
          :ok
          | {:error, {:rate_limited, pos_integer()}}
          | {:error, {:unavailable, term()}}

  @spec reserve(String.t(), String.t()) :: result()
  def reserve(space_hash, embed_hash) do
    reserve(space_hash, embed_hash, System.system_time(:millisecond))
  end

  @doc false
  @spec reserve(String.t(), String.t(), non_neg_integer()) :: result()
  def reserve(space_hash, embed_hash, now_ms)
      when is_binary(space_hash) and is_binary(embed_hash) and
             is_integer(now_ms) and now_ms >= 0 do
    limits = [
      {:day, @day_ms, config(:per_day, @default_per_day)},
      {:minute, @minute_ms, config(:per_minute, @default_per_minute)}
    ]

    reserve_limits(limits, space_hash, embed_hash, now_ms, [])
  rescue
    error ->
      {:error, {:unavailable, error}}
  catch
    :exit, reason ->
      {:error, {:unavailable, reason}}
  end

  defp reserve_limits([], _space_hash, _embed_hash, _now_ms, _reserved_keys), do: :ok

  defp reserve_limits(
         [{scope, interval_ms, max_attempts} | remaining],
         space_hash,
         embed_hash,
         now_ms,
         reserved_keys
       ) do
    retry_after_ms = interval_ms - rem(now_ms, interval_ms)

    if max_attempts == 0 do
      rollback(reserved_keys)
      {:error, {:rate_limited, retry_after_ms}}
    else
      key = counter_key(scope, interval_ms, space_hash, embed_hash, now_ms)

      case increment(key, interval_ms) do
        {:ok, count} when count <= max_attempts ->
          reserve_limits(
            remaining,
            space_hash,
            embed_hash,
            now_ms,
            [key | reserved_keys]
          )

        {:ok, _count} ->
          rollback([key | reserved_keys])
          {:error, {:rate_limited, retry_after_ms}}

        {:error, reason} ->
          rollback(reserved_keys)
          {:error, {:unavailable, reason}}
      end
    end
  end

  defp increment(key, interval_ms) do
    cache_module().incr(key, 1,
      default: 0,
      ttl: interval_ms * 2,
      timeout: config(:call_timeout_ms, @default_call_timeout_ms)
    )
  end

  defp rollback(keys) do
    Enum.each(keys, fn key ->
      case cache_module().decr(key, 1,
             default: 0,
             timeout: config(:call_timeout_ms, @default_call_timeout_ms)
           ) do
        {:ok, _count} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to roll back image generation budget: #{inspect(reason)}")
      end
    end)
  end

  defp counter_key(scope, interval_ms, space_hash, embed_hash, now_ms) do
    {:image_generation_budget, scope, div(now_ms, interval_ms), space_hash, embed_hash}
  end

  defp cache_module do
    config(:cache_module, ImageGenerationCache)
  end

  defp config(key, default) do
    :mave_core
    |> Application.get_env(:image_generation_budget, [])
    |> Access.get(key, default)
    |> validate_config!(key)
  end

  defp validate_config!(value, key)
       when key in [:per_minute, :per_day] and is_integer(value) and value >= 0,
       do: value

  defp validate_config!(value, :call_timeout_ms) when is_integer(value) and value > 0,
    do: value

  defp validate_config!(value, :cache_module) when is_atom(value), do: value

  defp validate_config!(value, key) do
    raise ArgumentError, "invalid image generation budget #{key}: #{inspect(value)}"
  end
end
