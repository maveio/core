defmodule MaveCore.TestSupport.ConcurrentFlowStorageAdapter do
  @moduledoc false

  use GenServer

  alias MaveCore.TestSupport.FlowStorageAdapterStub

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def put_file_public(bucket, path, source_path, content_type, region) do
    barrier = Application.fetch_env!(:mave_core, :test_hls_upload_barrier)
    :ok = GenServer.call(barrier, :await_release, :infinity)

    FlowStorageAdapterStub.put_file_public(bucket, path, source_path, content_type, region)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       owner: Keyword.fetch!(opts, :owner),
       threshold: Keyword.fetch!(opts, :threshold),
       waiting: [],
       released?: false
     }}
  end

  @impl true
  def handle_call(:await_release, _from, %{released?: true} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:await_release, from, state) do
    waiting = [from | state.waiting]

    if length(waiting) >= state.threshold do
      Enum.each(waiting, &GenServer.reply(&1, :ok))
      send(state.owner, {:hls_upload_batch_started, length(waiting)})
      {:noreply, %{state | waiting: [], released?: true}}
    else
      {:noreply, %{state | waiting: waiting}}
    end
  end
end
