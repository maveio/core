defmodule MaveCoreWeb.Dashboard.Settings.Index do
  @moduledoc false

  use MaveCoreWeb, :live_view
  import MaveCoreWeb.DashboardComponents, except: [icon: 1]
  import Ecto.Query, only: [from: 2]

  alias MaveCore.Accounts
  alias MaveCore.Repo
  alias MaveCore.Spaces.Domain
  alias MaveCore.Spaces.Events, as: SpaceEvents
  alias MaveCore.Spaces.Space
  alias MaveCoreWeb.Dashboard.Settings.{DeveloperTab, GeneralTab, TeamTab}
  alias MaveCoreWeb.DashboardRoutes

  def mount(_params, _session, socket) do
    extra_tabs = Application.get_env(:mave_core, :extra_settings_tabs, [])

    if connected?(socket) and match?(%Space{id: _}, socket.assigns[:current_space]) do
      SpaceEvents.subscribe(socket.assigns.current_space.id)
    end

    {:ok,
     socket
     |> assign(:page_title, gettext("Settings"))
     |> assign(:settings_open, false)
     |> assign(:route_scope, :unscoped)
     |> assign(:extra_tabs, extra_tabs)
     |> assign(:active_custom_tab, nil)
     |> assign(:settings_refresh_key, 0)
     |> assign(:custom_tab_refresh, 0)}
  end

  def handle_params(%{"tab" => tab_slug} = params, _url, socket) do
    socket = assign(socket, :route_scope, route_scope(params))

    case Enum.find(socket.assigns.extra_tabs, &(Atom.to_string(&1.id) == tab_slug)) do
      nil ->
        {:noreply,
         push_navigate(
           socket,
           to:
             DashboardRoutes.settings_path(
               socket.assigns.current_space,
               nil,
               scope: socket.assigns.route_scope
             )
         )}

      tab ->
        {:noreply, assign(socket, :active_custom_tab, tab)}
    end
  end

  def handle_params(params, _url, socket) do
    {:noreply,
     socket
     |> assign(:route_scope, route_scope(params))
     |> assign(:active_custom_tab, nil)}
  end

  def handle_info({:settings_space_updated, space}, socket) do
    {:noreply, refresh_space_assigns(socket, space.id)}
  end

  def handle_info({:settings_component_update, module, component_id, update_assigns}, socket)
      when is_atom(module) and is_binary(component_id) and is_map(update_assigns) do
    send_update(module, [id: component_id] ++ Map.to_list(update_assigns))
    {:noreply, socket}
  end

  def handle_info(
        {:space_updated, space_id},
        %{assigns: %{current_space: %{id: space_id}}} = socket
      ) do
    refresh_key = System.unique_integer([:positive])

    {:noreply,
     socket
     |> refresh_space_assigns(space_id)
     |> assign(:settings_refresh_key, refresh_key)
     |> assign(:custom_tab_refresh, refresh_key)}
  end

  def handle_info(_message, socket) do
    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="h-full flex flex-col">
      <div class="h-16 flex-none"></div>
      <div class="flex-none">
        <.menubar>
          <.menubar_item
            icon="general"
            path={DashboardRoutes.settings_path(@current_space, nil, scope: @route_scope)}
            active={@live_action == :general}
          >
            {gettext("General")}
          </.menubar_item>
          <.menubar_item
            icon="developer"
            path={DashboardRoutes.settings_path(@current_space, :developer, scope: @route_scope)}
            active={@live_action == :developer}
          >
            {gettext("Developer")}
          </.menubar_item>
          <.menubar_item
            icon="team"
            path={DashboardRoutes.settings_path(@current_space, :team, scope: @route_scope)}
            active={@live_action == :team}
          >
            {gettext("Team")}
          </.menubar_item>
          <.menubar_item
            :for={tab <- @extra_tabs}
            icon={tab.icon}
            path={DashboardRoutes.settings_path(@current_space, tab.id, scope: @route_scope)}
            active={
              @live_action == :custom_tab && @active_custom_tab && @active_custom_tab.id == tab.id
            }
          >
            {Gettext.gettext(MaveCoreWeb.Gettext, tab.label)}
          </.menubar_item>
        </.menubar>
      </div>

      <div class="flex-1 overflow-y-auto">
        <div class="max-w-screen-xl px-16 mx-auto pt-10 pb-24">
          <%= case @live_action do %>
            <% :developer -> %>
              <.live_component
                module={DeveloperTab}
                id="developer-tab"
                current_space={@current_space}
                current_user={@current_user}
                space_access_context={@space_access_context}
                refresh_key={@settings_refresh_key}
              />
            <% :team -> %>
              <.live_component
                module={TeamTab}
                id="team-tab"
                current_space={@current_space}
                current_user={@current_user}
                space_access_context={@space_access_context}
                refresh_key={@settings_refresh_key}
              />
            <% :custom_tab -> %>
              <.live_component
                :if={@active_custom_tab}
                module={@active_custom_tab.module}
                id={"#{@active_custom_tab.id}-tab"}
                current_space={@current_space}
                current_user={@current_user}
                space_access_context={@space_access_context}
                refresh_key={@custom_tab_refresh}
              />
            <% _ -> %>
              <.live_component
                module={GeneralTab}
                id="general-tab"
                current_space={@current_space}
                current_user={@current_user}
                space_access_context={@space_access_context}
                refresh_key={@settings_refresh_key}
              />
          <% end %>
        </div>
      </div>

      <.footer />
    </div>
    """
  end

  defp route_scope(%{"space_id" => space_id}) when is_binary(space_id) and space_id != "",
    do: :scoped

  defp route_scope(_params), do: :unscoped

  defp refresh_space_assigns(socket, space_id) do
    domains_query = from(d in Domain, order_by: [asc: d.inserted_at])
    current_space = Repo.get!(Space, space_id) |> Repo.preload(domains: domains_query)

    socket
    |> assign(:current_space, current_space)
    |> assign(:spaces, Accounts.list_user_spaces(socket.assigns.current_user))
  end
end
