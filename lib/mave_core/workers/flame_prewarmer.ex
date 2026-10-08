defmodule MaveCore.Workers.FlamePrewarmer do
  @moduledoc false

  use GenServer
  require Logger

  @default_call_timeout_ms 5 * 60 * 1000
  @default_initial_delay_ms 5_000
  @default_interval_ms 60_000
  @default_pool MaveCore.Workers.FlameRunner

  defstruct pool: @default_pool,
            interval_ms: @default_interval_ms,
            initial_delay_ms: @default_initial_delay_ms,
            call_timeout_ms: @default_call_timeout_ms,
            warmer: nil

  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      pool: Keyword.get(opts, :pool, @default_pool),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      initial_delay_ms: Keyword.get(opts, :initial_delay_ms, @default_initial_delay_ms),
      call_timeout_ms: Keyword.get(opts, :call_timeout_ms, @default_call_timeout_ms),
      warmer: Keyword.get(opts, :warmer, &__MODULE__.warm/2)
    }

    schedule_warm(state.initial_delay_ms)
    {:ok, state}
  end

  def warm(pool, timeout_ms) do
    FLAME.call(pool, fn -> :ok end, timeout: timeout_ms)
  end

  @impl true
  def handle_info(:warm, %__MODULE__{} = state) do
    warm_once(state)
    schedule_warm(state.interval_ms)
    {:noreply, state}
  end

  defp warm_once(%__MODULE__{} = state) do
    state.warmer.(state.pool, state.call_timeout_ms)
    :ok
  rescue
    exception ->
      Logger.warning("FLAME prewarm failed: #{Exception.message(exception)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("FLAME prewarm failed: #{kind} #{inspect(reason)}")
      :ok
  end

  defp schedule_warm(delay_ms) do
    Process.send_after(self(), :warm, delay_ms)
  end
end
