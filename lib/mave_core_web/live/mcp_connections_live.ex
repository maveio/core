defmodule MaveCoreWeb.McpConnectionsLive do
  @moduledoc false
  use MaveCoreWeb, :live_view
  import MaveCoreWeb.ConnectionComponents
  import MaveCoreWeb.DashboardComponents, except: [icon: 1]
  alias MaveCore.MCP.OAuth

  def mount(_, _, socket),
    do: {:ok, socket |> assign(:page_title, "Connected apps") |> load_connections()}

  def handle_event("revoke", %{"id" => id}, socket) do
    OAuth.revoke_connection(socket.assigns.current_user, id)
    {:noreply, load_connections(socket)}
  end

  def render(assigns) do
    ~H"""
    <.connection_card
      id="mcp-connections"
      title_id="mcp-connections-title"
      title="Connected apps"
      eyebrow="Mave"
      footer="Disconnecting an app immediately revokes its access and refresh tokens."
    >
      <p
        :if={@connections == []}
        id="mcp-connections-empty"
        class="mb-6 text-center text-sm text-stone-500"
      >
        No apps are connected.
      </p>
      <article
        :for={connection <- @connections}
        id={"mcp-connection-#{connection.id}"}
        class="mb-4 rounded-md bg-white p-4 ring-1 ring-stone-200"
      >
        <h2 class="break-words text-sm font-medium text-stone-600">{connection.client.name}</h2>
        <p class="mt-1 text-xs text-stone-400">
          Space {connection.space.hash} · {if OAuth.can_write?(connection),
            do: "Read and write",
            else: "Read only"}
        </p>
        <.dash_button
          id={"mcp-revoke-#{connection.id}"}
          type="button"
          phx-click="revoke"
          phx-value-id={connection.id}
          variant="ghost"
        >Disconnect</.dash_button>
      </article>
      <.link href={~p"/"} class="mb-6 block text-center text-sm text-blue-500 hover:underline">Back to Mave</.link>
    </.connection_card>
    """
  end

  defp load_connections(socket),
    do: assign(socket, :connections, OAuth.connections(socket.assigns.current_user))
end
