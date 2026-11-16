defmodule MaveCore.LiveStreams.Supervisor do
  @moduledoc """
  Processes behind live streaming. Every node gets the task supervisor used to
  remove media. Nodes with live streaming enabled also accept RTMP connections
  and run the ingest sessions.
  """

  use Supervisor

  alias MaveCore.LiveStreams.Config
  alias MaveCore.LiveStreams.RTMP.Connection
  alias MaveCore.LiveStreams.Sweeper

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children =
      [{Task.Supervisor, name: MaveCore.LiveStreams.TaskSupervisor}] ++
        if(Config.enabled?(), do: ingest_children(), else: [])

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp ingest_children do
    [
      {Registry, keys: :unique, name: MaveCore.LiveStreams.Registry},
      {DynamicSupervisor, name: MaveCore.LiveStreams.SessionSupervisor, strategy: :one_for_one},
      Sweeper,
      {ThousandIsland,
       port: Config.get(:rtmp_port),
       handler_module: Connection,
       num_acceptors: 4,
       num_connections: Config.get(:max_connections),
       read_timeout: Config.get(:idle_timeout_seconds) * 1000,
       transport_options: [nodelay: true],
       supervisor_options: [name: MaveCore.LiveStreams.Listener]}
    ]
  end
end
