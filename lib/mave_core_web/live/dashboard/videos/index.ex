defmodule MaveCoreWeb.Dashboard.Videos.Index do
  @moduledoc false

  use MaveCoreWeb, :live_view
  import MaveCoreWeb.DashboardComponents, except: [icon: 1]

  alias MaveCore.Embeds
  alias MaveCore.Embeds.Events, as: EmbedEvents
  alias MaveCore.UsageLimits
  alias MaveCoreWeb.DashboardComponents
  alias MaveCoreWeb.DashboardRoutes
  alias Phoenix.LiveView.JS

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Videos"))
     |> assign(:settings_open, false)
     |> assign(:current_tab, :all)
     |> assign(:route_scope, :unscoped)
     |> assign(:page, 1)
     |> assign(:total_pages, 0)
     |> assign(:folders, [])
     |> assign(:videos, [])
     |> assign(:can_create_video, true)
     |> assign(:video_creation_notice, nil)
     |> assign(:video_creation_help, nil)
     |> assign(:embed_list_subscription, nil)
     |> assign(:embed_list_subscription_active, false)}
  end

  def handle_params(params, _url, socket) do
    tab =
      case params["tab"] do
        "archive" -> :archive
        _ -> :all
      end

    page = parse_page(params["page"])

    {:noreply,
     socket
     |> assign(:current_tab, tab)
     |> assign(:route_scope, route_scope(params))
     |> assign(:page, page)
     |> maybe_track_embed_list_subscription()
     |> assign_dashboard_items(tab, page)}
  end

  def handle_info(
        {:space_embeds_updated, %{"space_id" => space_id}},
        %{assigns: %{current_space: %{id: space_id}}} = socket
      ) do
    {:noreply, assign_dashboard_items(socket, socket.assigns.current_tab, socket.assigns.page)}
  end

  def handle_event("create", _params, socket) do
    handle_event("create_video", %{}, socket)
  end

  def handle_event("create_video", _params, socket) do
    attrs =
      case socket.assigns.current_tab do
        :archive -> %{archived: true}
        _ -> %{}
      end

    case Embeds.create_video_embed(socket.assigns.current_space, attrs) do
      {:ok, embed} ->
        {:noreply,
         push_navigate(
           socket,
           to:
             video_path(
               socket.assigns.current_space,
               Embeds.dashboard_embed_id(embed),
               socket.assigns.current_tab,
               socket.assigns.route_scope
             )
         )}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign_video_creation_status()
         |> put_flash(:error, video_creation_error(reason))}
    end
  end

  def handle_event("create_folder", _params, socket) do
    attrs =
      case socket.assigns.current_tab do
        :archive -> %{archived: true}
        _ -> %{}
      end

    case Embeds.create_folder_embed(socket.assigns.current_space, attrs) do
      {:ok, embed} ->
        {:noreply,
         push_navigate(
           socket,
           to:
             video_path(
               socket.assigns.current_space,
               Embeds.dashboard_embed_id(embed),
               socket.assigns.current_tab,
               socket.assigns.route_scope
             )
         )}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Could not create folder"))}
    end
  end

  def handle_event("drop_embed", %{"id" => id} = params, socket) do
    with {:ok, embed} <- Embeds.resolve_dashboard_embed(socket.assigns.current_space, id),
         {:ok, target_folder} <- resolve_drop_target(socket.assigns.current_space, params),
         {:ok, _moved} <- Embeds.move_embed(embed, target_folder) do
      {:noreply,
       socket
       |> assign_dashboard_items(socket.assigns.current_tab, socket.assigns.page)
       |> put_flash(:info, gettext("Item moved"))}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not move item"))}
    end
  end

  def handle_event("previous_page", _params, socket) do
    {:noreply,
     push_patch(
       socket,
       to:
         tab_path(
           socket.assigns.current_space,
           socket.assigns.route_scope,
           socket.assigns.current_tab,
           max(socket.assigns.page - 1, 1)
         )
     )}
  end

  def handle_event("next_page", _params, socket) do
    next_page = min(socket.assigns.page + 1, max(socket.assigns.total_pages, 1))

    {:noreply,
     push_patch(
       socket,
       to:
         tab_path(
           socket.assigns.current_space,
           socket.assigns.route_scope,
           socket.assigns.current_tab,
           next_page
         )
     )}
  end

  def render(assigns) do
    ~H"""
    <div class="h-full flex flex-col">
      <.title title={gettext("Videos")}>
        <div class="flex items-center gap-3">
          <div
            :if={@video_creation_notice}
            id="videos-create-video-limit-notice"
            class="flex-none mr-6 text-stone-400 text-opacity-70 text-sm cursor-default flex items-center"
          >
            <div>{@video_creation_notice}</div>
            <.info_hover position="left">
              {@video_creation_help}
            </.info_hover>
          </div>

          <div class="flex items-center rounded-full bg-stone-100 ring-1 ring-inset ring-stone-200 overflow-hidden text-sm">
            <.tab_link
              id="videos-tab-all"
              patch={tab_path(@current_space, @route_scope, :all)}
              active={@current_tab == :all}
              label={gettext("all")}
            />
            <.tab_link
              id="videos-tab-archive"
              patch={tab_path(@current_space, @route_scope, :archive)}
              active={@current_tab == :archive}
              label={gettext("archive")}
            />
          </div>

          <.create_menu_button
            id="videos-create-button"
            video_disabled={!@can_create_video}
            video_disabled_title={@video_creation_help}
          />
        </div>
      </.title>

      <div class="flex-1 overflow-y-auto">
        <div class={[
          "max-w-screen-xl mx-auto px-16 w-full relative",
          (@folders == [] and @videos == []) && "h-full"
        ]}>
          <%= if @folders == [] and @videos == [] do %>
            <div id="videos-empty-state" class="flex min-h-full flex-col items-center justify-center">
              <div class="w-24 h-24 mt-16">
                <.animated_icon
                  name="upload"
                  class="w-24 h-24 opacity-30 invert grayscale"
                  speed="1"
                />
              </div>
              <div class="text-stone-300 text-2xl mt-5 select-none cursor-default">
                {if @current_tab == :archive,
                  do: gettext("Your archive is empty"),
                  else: gettext("Create your first video")}
              </div>
              <%= if @current_tab != :archive do %>
                <.create_menu_button
                  id="videos-empty-create-button"
                  class="mt-8 ml-0"
                  video_disabled={!@can_create_video}
                  video_disabled_title={@video_creation_help}
                />
              <% end %>
              <div class="w-12 mt-16 mb-12 mx-auto border-t border-stone-100"></div>
            </div>
          <% else %>
            <div class="mt-8">
              <div id="folders" phx-update="replace">
                <%= for folder <- @folders do %>
                  <DashboardComponents.media_item
                    id={"folder-row-#{folder.uuid}"}
                    type={:folder}
                    name={folder.name}
                    navigate={video_path(@current_space, folder.id, @current_tab, @route_scope)}
                    draggable
                    class="_folder"
                    phx-hook="folder"
                    data-embed-id={folder.uuid}
                    data-target-folder-id={folder.uuid}
                  >
                    <:badges>
                      <DashboardComponents.media_badge>
                        {folder.video_count} {ngettext("video", "videos", folder.video_count)}
                      </DashboardComponents.media_badge>
                    </:badges>
                  </DashboardComponents.media_item>
                <% end %>
              </div>

              <div id="videos" phx-update="replace">
                <%= for video <- @videos do %>
                  <DashboardComponents.media_item
                    id={"video-row-#{video.uuid}"}
                    type={:video}
                    name={video.name}
                    thumbnail={video.thumb}
                    empty={video.empty}
                    date={video.inserted_at}
                    navigate={video_path(@current_space, video.id, @current_tab, @route_scope)}
                    draggable
                    phx-hook="draggable"
                    data-embed-id={video.uuid}
                  >
                    <:badges>
                      <%= if video.state do %>
                        <DashboardComponents.media_badge>
                          {video_state_label(video.state)}
                        </DashboardComponents.media_badge>
                      <% end %>
                      <%= if is_nil(video.state) && video.resolution do %>
                        <DashboardComponents.media_badge>
                          {video.resolution}
                        </DashboardComponents.media_badge>
                      <% end %>
                      <%= if is_nil(video.state) && video.fps do %>
                        <DashboardComponents.media_badge>
                          {video.fps}fps
                        </DashboardComponents.media_badge>
                      <% end %>
                    </:badges>
                  </DashboardComponents.media_item>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      </div>

      <%= if @folders != [] or @videos != [] do %>
        <.footer page={@page} total_pages={@total_pages} />
      <% else %>
        <.footer />
      <% end %>
    </div>
    """
  end

  attr :patch, :string, required: true
  attr :active, :boolean, required: true
  attr :label, :string, required: true
  attr :id, :string, default: nil

  defp tab_link(assigns) do
    ~H"""
    <.link
      id={@id}
      patch={@patch}
      class={[
        "px-3 py-1.5 text-stone-400 transition-colors",
        @active && "bg-white text-blue-500 shadow-sm"
      ]}
    >
      {@label}
    </.link>
    """
  end

  attr :id, :string, required: true
  attr :class, :string, default: nil
  attr :video_disabled, :boolean, default: false
  attr :video_disabled_title, :string, default: nil

  defp create_menu_button(assigns) do
    ~H"""
    <DashboardComponents.dropdown_button id={"#{@id}-menu"} class={@class}>
      <:trigger>
        <button
          id={@id}
          type="button"
          phx-click={JS.toggle_class("opacity-0 scale-95 pointer-events-none", to: "##{@id}-menu")}
          class="flex items-center ring-inset ring-1 ring-stone-200 rounded-md cursor-pointer bg-white hover:ring-blue-500 active:bg-blue-500 active:text-white transform-gpu transition ease-out duration-150 hover:scale-110 hover:shadow text-stone-500 select-none font-medium text-sm"
        >
          <div class="pl-3.5 pr-2 pt-2 pb-2.5">{gettext("create")}</div>
          <div class="pr-2.5 py-2 text-stone-400">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="w-4 h-4"
              width="24"
              height="24"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.5"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <path d="M6 9l6 6 6-6"></path>
            </svg>
          </div>
        </button>
      </:trigger>
      <:item
        id={"#{@id}-video"}
        icon="video"
        phx-click="create_video"
        disabled={@video_disabled}
        title={@video_disabled_title}
      >
        {gettext("video") |> String.capitalize()}
      </:item>
      <:item id={"#{@id}-folder"} icon="folder" phx-click="create_folder">
        {gettext("folder") |> String.capitalize()}
      </:item>
    </DashboardComponents.dropdown_button>
    """
  end

  defp assign_dashboard_items(socket, tab, page) do
    %{folders: folders, videos: videos, page: current_page, total_pages: total_pages} =
      Embeds.list_root_items(socket.assigns.current_space, tab, page: page)

    socket
    |> assign(:folders, folders)
    |> assign(:videos, videos)
    |> assign(:page, current_page)
    |> assign(:total_pages, total_pages)
    |> assign_video_creation_status()
  end

  defp maybe_track_embed_list_subscription(socket) do
    next = socket.assigns.current_space.id
    current = socket.assigns[:embed_list_subscription]
    active? = socket.assigns[:embed_list_subscription_active]

    cond do
      not connected?(socket) ->
        socket

      current == next and active? ->
        socket

      current == next ->
        subscribe_embed_list(socket, next)

      true ->
        socket
        |> unsubscribe_embed_list(current)
        |> subscribe_embed_list(next)
    end
  end

  defp subscribe_embed_list(socket, space_id) do
    EmbedEvents.subscribe_space(space_id)

    socket
    |> assign(:embed_list_subscription, space_id)
    |> assign(:embed_list_subscription_active, true)
  end

  defp unsubscribe_embed_list(socket, space_id) when is_binary(space_id) do
    EmbedEvents.unsubscribe_space(space_id)

    assign(socket, :embed_list_subscription_active, false)
  end

  defp unsubscribe_embed_list(socket, _space_id), do: socket

  defp assign_video_creation_status(socket) do
    case UsageLimits.can_create_video_embed?(socket.assigns.current_space) do
      :ok ->
        socket
        |> assign(:can_create_video, true)
        |> assign(:video_creation_notice, nil)
        |> assign(:video_creation_help, nil)

      {:error, reason} ->
        copy = UsageLimits.restriction_copy(:create_video, reason)

        socket
        |> assign(:can_create_video, false)
        |> assign(
          :video_creation_notice,
          Map.get(copy, :notice, gettext("Video creation is unavailable"))
        )
        |> assign(
          :video_creation_help,
          Map.get(copy, :help, gettext("This space cannot create more videos right now."))
        )
    end
  end

  defp video_creation_error(reason) do
    :create_video
    |> UsageLimits.restriction_copy(reason)
    |> Map.get(:error, gettext("Could not create video"))
  end

  defp video_state_label(:queued), do: gettext("Queued")
  defp video_state_label(:processing), do: gettext("Processing")
  defp video_state_label(:failed), do: gettext("Failed")
  defp video_state_label(_state), do: gettext("Processing")

  defp resolve_drop_target(space, %{"to" => target_id}) do
    case String.trim(target_id || "") do
      "" -> {:ok, nil}
      value -> Embeds.resolve_dashboard_embed(space, value)
    end
  end

  defp resolve_drop_target(_space, _params), do: {:ok, nil}

  defp tab_path(space, scope, tab, page \\ 1),
    do: DashboardRoutes.videos_path(space, tab, page: page, scope: scope)

  defp parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {parsed, _rest} when parsed > 0 -> parsed
      _ -> 1
    end
  end

  defp parse_page(_page), do: 1

  defp route_scope(%{"space_id" => space_id}) when is_binary(space_id) and space_id != "",
    do: :scoped

  defp route_scope(_params), do: :unscoped

  defp video_path(space, id, tab, scope),
    do: DashboardRoutes.video_path(space, id, tab, scope: scope)
end
