defmodule MaveCore.Workers.McpPruneWorker do
  @moduledoc "Removes expired MCP grants, tokens, and abandoned client registrations."
  use Oban.Worker, queue: :flow_low, max_attempts: 3

  alias MaveCore.MCP.OAuth

  @impl true
  def perform(_job), do: OAuth.prune_expired()
end
