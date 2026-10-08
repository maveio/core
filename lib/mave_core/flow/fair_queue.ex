defmodule MaveCore.Flow.FairQueue do
  @moduledoc """
  Calculates a tenant's current share of a bounded fair queue.

  Work-conserving queues divide their configured capacity across every tenant
  that currently has runnable work. A tenant can therefore use nearly the whole
  queue while it is alone, while optional new-space headroom keeps immediate
  capacity for another tenant. The busy tenant loses the ability to refill
  borrowed slots as soon as another tenant starts waiting.
  """

  @spec space_concurrency(keyword(), non_neg_integer()) :: pos_integer()
  def space_concurrency(config, demanding_spaces) when is_list(config) do
    configured_concurrency = positive_integer(Keyword.get(config, :space_concurrency), 1)

    if Keyword.get(config, :work_conserving, false) do
      work_conserving_space_concurrency(config, demanding_spaces, configured_concurrency)
    else
      configured_concurrency
    end
  end

  @doc """
  Returns the current per-run share for a work-conserving queue.

  `:run_concurrency` remains the safety ceiling for one source. When work
  conservation is enabled, a lone run may borrow up to that ceiling, while the
  queue divides its capacity across all runs that currently have work waiting.
  """
  @spec run_concurrency(keyword(), non_neg_integer()) :: pos_integer() | nil
  def run_concurrency(config, demanding_runs) when is_list(config) do
    case Keyword.get(config, :run_concurrency) do
      configured when is_integer(configured) and configured > 0 ->
        if Keyword.get(config, :work_conserving, false) do
          work_conserving_run_concurrency(config, demanding_runs, configured)
        else
          configured
        end

      _other ->
        nil
    end
  end

  defp work_conserving_space_concurrency(config, demanding_spaces, fallback)
       when is_integer(demanding_spaces) and demanding_spaces > 0 do
    case queue_capacity(config) do
      capacity when is_integer(capacity) and capacity > 0 ->
        capacity
        |> ceil_div(demanding_spaces)
        |> reserve_new_space_headroom(config, demanding_spaces)
        |> max(1)

      _other ->
        fallback
    end
  end

  defp work_conserving_space_concurrency(_config, _demanding_spaces, fallback), do: fallback

  defp reserve_new_space_headroom(concurrency, config, 1) do
    case Keyword.get(config, :new_space_headroom) do
      headroom when is_integer(headroom) and headroom > 0 -> concurrency - headroom
      _other -> concurrency
    end
  end

  defp reserve_new_space_headroom(concurrency, _config, _demanding_spaces), do: concurrency

  defp work_conserving_run_concurrency(config, demanding_runs, maximum)
       when is_integer(demanding_runs) and demanding_runs > 0 do
    case queue_capacity(config) do
      capacity when is_integer(capacity) and capacity > 0 ->
        min(maximum, max(1, ceil_div(capacity, demanding_runs)))

      _other ->
        maximum
    end
  end

  defp work_conserving_run_concurrency(_config, _demanding_runs, maximum), do: maximum

  defp queue_capacity(config) do
    Keyword.get(config, :background_concurrency) || Keyword.get(config, :global_concurrency)
  end

  defp ceil_div(dividend, divisor), do: div(dividend + divisor - 1, divisor)

  defp positive_integer(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, fallback), do: fallback
end
