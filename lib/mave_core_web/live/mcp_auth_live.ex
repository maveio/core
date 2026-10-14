defmodule MaveCoreWeb.McpAuthLive do
  @moduledoc false
  use MaveCoreWeb, :live_view

  import MaveCoreWeb.ConnectionComponents
  import MaveCoreWeb.DashboardComponents, except: [icon: 1]
  alias MaveCore.MCP.OAuth

  def mount(params, _session, socket) do
    request =
      case OAuth.authorization_request(params) do
        {:ok, request} -> request
        _ -> nil
      end

    {:ok,
     socket
     |> assign(:page_title, "Connect to Mave")
     |> assign(:request, request)
     |> assign(:expires_at, System.monotonic_time(:second) + 600)
     |> assign(:error, nil)
     |> assign(
       :approval_form,
       to_form(%{"space_id" => socket.assigns.current_space.id}, as: :authorization)
     )}
  end

  def handle_event("authorize", %{"authorization" => %{"space_id" => space_id}}, socket) do
    if socket.assigns.request && System.monotonic_time(:second) < socket.assigns.expires_at do
      case OAuth.approve(socket.assigns.request, socket.assigns.current_user, space_id) do
        {:ok, url} ->
          {:noreply, redirect_to_client(socket, url)}

        {:error, _} ->
          {:noreply, assign(socket, :error, "Choose a space you can access and try again.")}
      end
    else
      {:noreply,
       assign(socket, :error, "This request expired. Reconnect from your app to continue.")}
    end
  end

  def handle_event("deny", _, %{assigns: %{request: request}} = socket)
      when not is_nil(request) do
    {:noreply,
     redirect_to_client(socket, OAuth.redirect_url(request, %{"error" => "access_denied"}))}
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  # The OAuth context accepts only an exact, registered HTTPS/loopback redirect URI.
  # sobelow_skip ["XSS.Redirect"]
  defp redirect_to_client(socket, url), do: redirect(socket, external: url)

  def render(assigns) do
    ~H"""
    <.connection_card
      id="mcp-auth-window"
      title_id="mcp-auth-title"
      title={if @request, do: "Connect to Mave", else: "Unable to connect"}
      eyebrow="Mave · App connection"
      footer="Only connect an app if you started this request."
    >
      <%= if @request do %>
        <div class="mb-5 rounded-md bg-white px-4 py-3 text-center shadow-sm ring-1 ring-stone-200/50">
          <p id="mcp-client-name" class="break-words text-sm font-medium text-stone-600">
            {@request.client.name}
          </p>
          <p id="mcp-client-destination" class="mt-1 break-all text-xs text-stone-400">
            {URI.parse(@request.redirect_uri).host}
          </p>
          <p class="mt-2 text-[0.65rem] text-stone-400">
            App name and return address supplied by the client
          </p>
        </div>
        <p class="text-sm leading-6 text-stone-500">Choose the space this app can access.</p>
        <div
          id="mcp-permissions"
          class="my-5 rounded-md border border-stone-200 px-4 py-3 text-sm leading-6 text-stone-500"
        >
          <p class="font-medium text-stone-600">This app will be able to:</p>
          <ul class="mt-2 list-disc space-y-1 pl-4">
            <li>View videos, collections, and video details</li>
            <li :if={"mave:write" in String.split(@request.scope)}>
              Create, rename, move, and delete videos and collections
            </li>
          </ul>
          <p :if={@request.scope == "mave:read"} id="mcp-read-only" class="mt-2 text-xs">
            Read-only access. This app cannot change your library.
          </p>
        </div>
        <.form for={@approval_form} id="mcp-auth-approval-form" phx-submit="authorize">
          <label for={@approval_form[:space_id].id} class="mb-2 block text-xs text-stone-500">Space</label>
          <.dash_select
            field={@approval_form[:space_id]}
            options={Enum.map(@spaces, &{space_label(&1), &1.id})}
          />
          <p :if={@error} id="mcp-auth-error" role="alert" class="mt-4 text-sm text-red-600">
            {@error}
          </p>
          <p class="mt-4 text-xs leading-5 text-stone-400">
            Your API key stays private. You can disconnect this app at any time in <.link
              href={~p"/mcp/connections"}
              class="text-blue-500 hover:underline"
            >Connected apps</.link>.
          </p>
          <div class="mt-6 flex justify-center">
            <.dash_button
              id="mcp-auth-authorize"
              variant="primary"
              icon="link"
              loading_on_submit
              loading_label="Connecting…"
            >Connect to Mave</.dash_button>
          </div>
        </.form>
        <div class="mb-5 mt-3 flex justify-center">
          <.dash_button id="mcp-auth-deny" type="button" phx-click="deny" variant="ghost">Cancel</.dash_button>
        </div>
      <% else %>
        <p
          id="mcp-auth-invalid"
          role="alert"
          class="mb-6 text-center text-sm leading-6 text-stone-500"
        >
          This connection request is invalid or no longer available. Return to your app and connect again.
        </p>
      <% end %>
    </.connection_card>
    """
  end

  defp space_label(%{domains: [%{domain: domain} | _]}), do: domain
  defp space_label(space), do: "Space #{space.hash}"
end
