defmodule MaveCore.LiveStreams.Sweeper do
  @moduledoc false

  use GenServer

  alias MaveCore.LiveStreams
  alias MaveCore.LiveStreams.Session

  @interval 5_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Process.send_after(self(), :sweep, @interval)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    Process.send_after(self(), :sweep, @interval)

    try do
      LiveStreams.sweep(&Session.running?/1)
    rescue
      # The database may be briefly unavailable; the next sweep retries.
      _error -> :ok
    end

    {:noreply, state}
  end
end
