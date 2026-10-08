defmodule MaveCoreWeb.Dashboard.Settings.DeveloperTab do
  @moduledoc false

  use MaveCoreWeb, :live_component
  import MaveCoreWeb.DashboardComponents, except: [icon: 1]

  alias MaveCore.Spaces
  alias MaveCore.Spaces.{Key, Webhook}
  alias Phoenix.LiveView.JS

  @show_recent_deliveries false

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> MaveCoreWeb.SpaceLiveAuth.attach_component()
     |> assign(:show_recent_deliveries, @show_recent_deliveries)
     |> assign_new(:show_api_key_modal, fn -> false end)
     |> assign_new(:show_create_webhook, fn -> false end)
     |> assign_new(:editing_key_id, fn -> nil end)
     |> assign_new(:api_key_form, &new_key_form/0)
     |> assign_new(:revealed_key_ids, fn -> MapSet.new() end)
     |> assign_new(:revealed_webhook_secret_ids, fn -> MapSet.new() end)
     |> assign_new(:confirmation_needed, fn -> false end)
     |> assign_new(:wants_to_delete_key, fn -> nil end)
     |> assign_new(:wants_to_delete_webhook, fn -> nil end)
     |> reload_state()}
  end

  def render(assigns) do
    ~H"""
    <div>
      <%!-- Space ID --%>
      <.subtitle label={gettext("Space")} icon="list" />
      <div class="mt-6">
        <.data_table>
          <div class="w-full p-3.5">
            <.copyable_field id="space-id" value={@space_id} />
          </div>
        </.data_table>
      </div>

      <div class="w-12 mt-12 mb-4 mx-auto border-t border-stone-100"></div>

      <%!-- API Keys --%>
      <.subtitle label={gettext("API Keys")} icon="key">
        <%= if @keys != [] do %>
          <.dash_button
            id="settings-generate-key-button"
            variant="ghost"
            phx-click="open_modal"
            phx-value-modal="api_key"
            phx-target={@myself}
          >
            {gettext("generate key")}
          </.dash_button>
        <% end %>
      </.subtitle>
      <%= if @keys != [] do %>
        <div class="mt-6">
          <.data_table>
            <.data_table_row :for={key <- @keys} id={"api-key-#{key.id}"}>
              <div class="grid w-full min-w-0 grid-cols-[minmax(8rem,0.65fr)_minmax(16rem,1fr)] items-center gap-4">
                <div class="min-w-0">
                  <div
                    class={[
                      "flex min-w-0 items-center gap-2 truncate text-sm",
                      key_description?(key) && "text-stone-500",
                      !key_description?(key) && "text-stone-300"
                    ]}
                    title={key_description(key)}
                  >
                    <span class="truncate">{key_description(key)}</span>
                    <span
                      id={"key-access-level-#{key.id}"}
                      aria-label={
                        gettext("API key access level: %{access_level}",
                          access_level: key_access_level_label(key)
                        )
                      }
                      class="inline-flex shrink-0 items-center rounded-full border border-stone-200/60 bg-stone-50 px-2 py-0.5 text-[0.68rem] font-medium text-stone-400"
                    >
                      {key_access_level_label(key)}
                    </span>
                  </div>
                  <p
                    :if={Key.cli_connection?(key)}
                    id={"cli-key-details-#{key.id}"}
                    title={cli_key_details(key)}
                    class="mt-1 truncate text-xs text-stone-400"
                  >
                    {cli_key_details(key)}
                  </p>
                </div>
                <.secret_field
                  id={"key-#{key.id}"}
                  value={key.display_key}
                  revealed={MapSet.member?(@revealed_key_ids, key.id)}
                  on_toggle={JS.push("toggle_key_reveal", value: %{id: key.id}, target: @myself)}
                />
              </div>
              <:actions>
                <div class="mr-2">
                  <.dash_button
                    id={"edit-key-#{key.id}"}
                    icon="edit"
                    icon_only
                    type="button"
                    title={gettext("Edit API key")}
                    aria-label={gettext("Edit API key")}
                    phx-click="edit_key"
                    phx-value-id={key.id}
                    phx-target={@myself}
                  />
                </div>
                <div class="mr-3.5">
                  <.dash_button
                    icon="delete"
                    icon_only
                    type="button"
                    title={gettext("Delete API key")}
                    aria-label={gettext("Delete API key")}
                    phx-click="delete_key"
                    phx-value-id={key.id}
                    phx-target={@myself}
                  />
                </div>
              </:actions>
            </.data_table_row>
          </.data_table>
        </div>
      <% else %>
        <div class="flex items-center flex-col">
          <svg
            xmlns="http://www.w3.org/2000/svg"
            class="w-16 h-16 mt-4 text-stone-200"
            width="24"
            height="24"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="0.6"
            stroke-linecap="round"
            stroke-linejoin="round"
          >
            <path d="M21 2l-2 2m-7.61 7.61a5.5 5.5 0 1 1-7.778 7.778 5.5 5.5 0 0 1 7.777-7.777zm0 0L15.5 7.5m0 0l3 3L22 7l-3-3m-3.5 3.5L19 4">
            </path>
          </svg>
          <div class="text-sm text-stone-300 mt-5 mb-4">{gettext("no keys yet")}</div>
          <.dash_button
            id="settings-generate-key-empty-button"
            variant="ghost"
            phx-click="open_modal"
            phx-value-modal="api_key"
            phx-target={@myself}
          >
            {gettext("generate key")}
          </.dash_button>
        </div>
      <% end %>

      <div class="w-12 mt-12 mb-4 mx-auto border-t border-stone-100"></div>

      <%!-- Webhooks --%>
      <.subtitle label={gettext("Webhooks")} icon="webhook">
        <%= if @webhooks != [] do %>
          <.dash_button
            id="settings-create-webhook-button"
            variant="ghost"
            phx-click="open_modal"
            phx-value-modal="create_webhook"
            phx-target={@myself}
          >
            {gettext("create webhook")}
          </.dash_button>
        <% end %>
      </.subtitle>
      <%= if @webhooks != [] do %>
        <div class="mt-6">
          <.data_table>
            <.data_table_row :for={webhook <- @webhooks} id={"webhook-#{webhook.id}"}>
              <div class="flex w-full items-center">
                <div class="flex h-11 flex-grow items-center bg-stone-50 rounded-l border-r border-stone-200/70 text-sm text-stone-400 p-2.5 select-text">
                  <div class="flex-grow font-mono text-xs">{webhook.url}</div>
                </div>
                <.secret_field
                  id={"webhook-secret-#{webhook.id}"}
                  value={webhook.secret}
                  secret_name={gettext("Webhook secret")}
                  rounded="rounded-r"
                  class="w-80 shrink-0"
                  revealed={MapSet.member?(@revealed_webhook_secret_ids, webhook.id)}
                  on_toggle={
                    JS.push("toggle_webhook_secret_reveal",
                      value: %{id: webhook.id},
                      target: @myself
                    )
                  }
                />
              </div>
              <:actions>
                <div class="flex-grow mx-5">
                  <.toggle
                    enabled={webhook.enabled}
                    phx-click="toggle_webhook"
                    phx-value-id={webhook.id}
                    phx-target={@myself}
                  />
                </div>
                <div class="mr-4">
                  <.dash_button
                    icon="delete"
                    icon_only
                    phx-click="delete_webhook"
                    phx-value-id={webhook.id}
                    phx-target={@myself}
                  />
                </div>
              </:actions>
            </.data_table_row>
          </.data_table>
        </div>
      <% else %>
        <div class="flex items-center flex-col">
          <svg
            class="w-16 h-16 mt-4 text-stone-200"
            width="24"
            height="24"
            stroke-width="0.6"
            viewBox="0 0 24 24"
            fill="none"
            xmlns="http://www.w3.org/2000/svg"
          >
            <path
              d="M17.5 8C17.5 8 19 9.5 19 12C19 14.5 17.5 16 17.5 16"
              stroke="currentColor"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
            <path
              d="M20.5 5C20.5 5 23 7.5 23 12C23 16.5 20.5 19 20.5 19"
              stroke="currentColor"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
            <path
              d="M6.5 8C6.5 8 5 9.5 5 12C5 14.5 6.5 16 6.5 16"
              stroke="currentColor"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
            <path
              d="M3.5 5C3.5 5 1 7.5 1 12C1 16.5 3.5 19 3.5 19"
              stroke="currentColor"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
            <path
              d="M12 13C12.5523 13 13 12.5523 13 12C13 11.4477 12.5523 11 12 11C11.4477 11 11 11.4477 11 12C11 12.5523 11.4477 13 12 13Z"
              fill="currentColor"
              stroke="currentColor"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
          </svg>
          <div class="text-sm text-stone-300 mt-5 mb-4">{gettext("no webhooks yet")}</div>
          <.dash_button
            id="settings-create-webhook-empty-button"
            variant="ghost"
            phx-click="open_modal"
            phx-value-modal="create_webhook"
            phx-target={@myself}
          >
            {gettext("create webhook")}
          </.dash_button>
        </div>
      <% end %>

      <%= if @show_recent_deliveries do %>
        <div class="w-12 mt-12 mb-4 mx-auto border-t border-stone-100"></div>

        <%!-- Recent Deliveries --%>
        <.subtitle label={gettext("Recent deliveries")} icon="list" />
        <%= if @deliveries != [] do %>
          <div class="mt-6">
            <.data_table>
              <.data_table_row :for={delivery <- @deliveries}>
                <div class="w-full text-xs text-stone-400 font-mono">
                  <div>{display_event_type(delivery.event_type)}</div>
                  <div class="mt-1 truncate">{delivery.webhook && delivery.webhook.url}</div>
                </div>
                <:actions>
                  <div class="mr-4 text-right">
                    <div class="text-sm text-stone-500">
                      {display_delivery_state(delivery.state)}
                    </div>
                    <div class="text-xs text-stone-300 mt-0.5">
                      {display_delivery_meta(delivery)}
                    </div>
                  </div>
                </:actions>
              </.data_table_row>
            </.data_table>
          </div>
        <% else %>
          <div class="text-sm text-stone-300 text-center mt-8">{gettext("no deliveries yet")}</div>
        <% end %>
      <% end %>

      <%!-- Create or edit API key modal --%>
      <.modal
        id="api-key-modal"
        show={@show_api_key_modal}
        title={
          if @editing_key_id,
            do: gettext("Edit API key"),
            else: gettext("Create API key")
        }
        on_cancel={JS.push("close_modal", value: %{modal: "api_key"}, target: @myself)}
      >
        <.form
          id="api-key-form"
          for={@api_key_form}
          phx-submit="submit_api_key"
          phx-target={@myself}
        >
          <.info_box>
            <%= if @editing_key_id do %>
              {gettext(
                "Changes to access apply immediately to every existing JWT signed by this key."
              )}
            <% else %>
              {gettext("Add an optional description and choose what JWTs signed by this key may do.")}
            <% end %>
          </.info_box>
          <div class="mt-8">
            <label for={@api_key_form[:description].id} class="mb-2 block text-xs text-stone-400">
              {gettext("Description")}
            </label>
            <.dash_input
              field={@api_key_form[:description]}
              placeholder={gettext("description (optional)")}
            />
          </div>
          <div class="mt-5">
            <label for={@api_key_form[:access_level].id} class="mb-2 block text-xs text-stone-400">
              {gettext("Access")}
            </label>
            <div class="relative">
              <.dash_select
                field={@api_key_form[:access_level]}
                options={key_access_level_options()}
              />
              <MaveCoreWeb.DashboardComponents.Buttons.icon
                name="hero-chevron-down"
                class="pointer-events-none absolute right-4 top-1/2 size-4 -translate-y-1/2 text-stone-400"
              />
            </div>
            <div class="mt-2 px-1 text-xs leading-relaxed text-stone-400">
              {gettext(
                "Read-only keys can read collections. Read/write keys can also upload and modify content."
              )}
            </div>
          </div>
          <div class="flex mt-10">
            <div class="flex-grow" />
            <.dash_button
              form="api-key-form"
              icon={if @editing_key_id, do: nil, else: "create"}
            >
              {if @editing_key_id, do: gettext("save"), else: gettext("create")}
            </.dash_button>
          </div>
        </.form>
      </.modal>

      <%!-- Create Webhook Modal --%>
      <.modal
        id="create-webhook-modal"
        show={@show_create_webhook}
        title={gettext("Create webhook")}
        on_cancel={JS.push("close_modal", value: %{modal: "create_webhook"}, target: @myself)}
      >
        <.form
          id="create-webhook-form"
          for={@webhook_form}
          phx-submit="submit_create_webhook"
          phx-target={@myself}
        >
          <.info_box>
            {gettext(
              "This webhook will receive: video.created video.uploaded video.processing video.ready video.deleted"
            )}
          </.info_box>
          <div class="mt-8">
            <.dash_input field={@webhook_form[:url]} placeholder="https://domain.com/webhook" />
          </div>
          <div class="mt-4">
            <.dash_input
              field={@webhook_form[:description]}
              placeholder={gettext("description (optional)")}
            />
          </div>
          <div class="flex mt-10">
            <div class="flex-grow" />
            <.dash_button form="create-webhook-form" icon="create">{gettext("create")}</.dash_button>
          </div>
        </.form>
      </.modal>

      <.dialog
        id="developer-delete-dialog"
        show={@confirmation_needed}
        on_confirm={JS.push("confirmed_deletion", target: @myself)}
        on_cancel={JS.push("cancel_modal", target: @myself)}
      />
    </div>
    """
  end

  def handle_event("open_modal", %{"modal" => modal}, socket) do
    socket =
      case modal do
        "api_key" ->
          socket
          |> assign(:editing_key_id, nil)
          |> assign(:api_key_form, new_key_form())

        "create_webhook" ->
          assign(socket, :webhook_form, new_webhook_form())

        _ ->
          socket
      end

    {:noreply, toggle_modal(socket, modal, true)}
  end

  def handle_event("close_modal", %{"modal" => modal}, socket) do
    {:noreply, toggle_modal(socket, modal, false)}
  end

  def handle_event("submit_create_webhook", %{"webhook" => params}, socket) do
    attrs = Map.put(params, "enabled_events", Webhook.mave_events())

    case Spaces.create_webhook(socket.assigns.current_space, attrs) do
      {:ok, _webhook} ->
        {:noreply,
         socket
         |> assign(:show_create_webhook, false)
         |> assign(:webhook_form, new_webhook_form())
         |> reload_state()}

      {:error, changeset} ->
        {:noreply,
         assign(
           socket,
           :webhook_form,
           to_form(Map.put(changeset, :action, :validate), as: :webhook)
         )}
    end
  end

  def handle_event("submit_api_key", %{"api_key" => params}, socket) do
    case socket.assigns.editing_key_id do
      nil ->
        create_api_key(socket, params)

      key_id ->
        update_api_key(socket, key_id, params)
    end
  end

  def handle_event("edit_key", %{"id" => id}, socket) do
    case Spaces.get_user_managed_key_for_space(socket.assigns.current_space, id) do
      %Key{} = key ->
        {:noreply,
         socket
         |> assign(:editing_key_id, key.id)
         |> assign(:api_key_form, key_form(key))
         |> assign(:show_api_key_modal, true)}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_key_reveal", %{"id" => id}, socket) do
    case Spaces.get_user_managed_key_for_space(socket.assigns.current_space, id) do
      %Key{} ->
        revealed_key_ids =
          if MapSet.member?(socket.assigns.revealed_key_ids, id) do
            MapSet.delete(socket.assigns.revealed_key_ids, id)
          else
            MapSet.put(socket.assigns.revealed_key_ids, id)
          end

        {:noreply, assign(socket, :revealed_key_ids, revealed_key_ids)}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_webhook_secret_reveal", %{"id" => id}, socket) do
    case Spaces.get_webhook_for_space(socket.assigns.current_space, id) do
      %Webhook{} ->
        revealed_webhook_secret_ids =
          if MapSet.member?(socket.assigns.revealed_webhook_secret_ids, id) do
            MapSet.delete(socket.assigns.revealed_webhook_secret_ids, id)
          else
            MapSet.put(socket.assigns.revealed_webhook_secret_ids, id)
          end

        {:noreply, assign(socket, :revealed_webhook_secret_ids, revealed_webhook_secret_ids)}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_key", %{"id" => id}, socket) do
    if Spaces.get_user_managed_key_for_space(socket.assigns.current_space, id) do
      {:noreply,
       socket
       |> assign(:wants_to_delete_key, id)
       |> assign(:wants_to_delete_webhook, nil)
       |> assign(:confirmation_needed, true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_webhook", %{"id" => id}, socket) do
    socket =
      case Spaces.get_webhook_for_space(socket.assigns.current_space, id) do
        nil ->
          socket

        webhook ->
          _ = Spaces.toggle_webhook(webhook)
          reload_state(socket)
      end

    {:noreply, socket}
  end

  def handle_event("delete_webhook", %{"id" => id}, socket) do
    if Spaces.get_webhook_for_space(socket.assigns.current_space, id) do
      {:noreply,
       socket
       |> assign(:wants_to_delete_webhook, id)
       |> assign(:wants_to_delete_key, nil)
       |> assign(:confirmation_needed, true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:wants_to_delete_key, nil)
     |> assign(:wants_to_delete_webhook, nil)
     |> assign(:confirmation_needed, false)}
  end

  def handle_event(
        "confirmed_deletion",
        _params,
        %{assigns: %{wants_to_delete_key: key_id}} = socket
      )
      when is_binary(key_id) do
    socket =
      case Spaces.get_user_managed_key_for_space(socket.assigns.current_space, key_id) do
        nil ->
          socket

        key ->
          _ = Spaces.delete_key(key)
          reload_state(socket)
      end

    {:noreply,
     socket
     |> assign(:wants_to_delete_key, nil)
     |> assign(:wants_to_delete_webhook, nil)
     |> assign(:confirmation_needed, false)
     |> put_flash(:info, gettext("The key has been deleted."))}
  end

  def handle_event(
        "confirmed_deletion",
        _params,
        %{assigns: %{wants_to_delete_webhook: webhook_id}} = socket
      )
      when is_binary(webhook_id) do
    socket =
      case Spaces.get_webhook_for_space(socket.assigns.current_space, webhook_id) do
        nil ->
          socket

        webhook ->
          _ = Spaces.delete_webhook(webhook)
          reload_state(socket)
      end

    {:noreply,
     socket
     |> assign(:wants_to_delete_key, nil)
     |> assign(:wants_to_delete_webhook, nil)
     |> assign(:confirmation_needed, false)
     |> put_flash(:info, gettext("The webhook has been deleted."))}
  end

  def handle_event("confirmed_deletion", _params, socket) do
    {:noreply, assign(socket, :confirmation_needed, false)}
  end

  defp create_api_key(socket, params) do
    case Spaces.create_key(socket.assigns.current_space, params) do
      {:ok, _key} ->
        {:noreply,
         socket
         |> assign(:show_api_key_modal, false)
         |> assign(:editing_key_id, nil)
         |> assign(:api_key_form, new_key_form())
         |> reload_state()}

      {:error, changeset} ->
        {:noreply, assign(socket, :api_key_form, key_form_with_errors(changeset))}
    end
  end

  defp update_api_key(socket, key_id, params) do
    case Spaces.get_user_managed_key_for_space(socket.assigns.current_space, key_id) do
      %Key{} = key ->
        case Spaces.update_key(key, params) do
          {:ok, _key} ->
            {:noreply,
             socket
             |> assign(:show_api_key_modal, false)
             |> assign(:editing_key_id, nil)
             |> assign(:api_key_form, new_key_form())
             |> reload_state()}

          {:error, changeset} ->
            {:noreply, assign(socket, :api_key_form, key_form_with_errors(changeset))}
        end

      nil ->
        {:noreply,
         socket
         |> assign(:show_api_key_modal, false)
         |> assign(:editing_key_id, nil)
         |> put_flash(:error, gettext("Could not update this API key."))}
    end
  end

  defp key_access_level_label(%Key{access_level: :read_only}), do: gettext("read only")
  defp key_access_level_label(%Key{access_level: :read_write}), do: gettext("read/write")

  defp key_access_level_options do
    [
      {gettext("read/write"), "read_write"},
      {gettext("read only"), "read_only"}
    ]
  end

  defp key_description?(%Key{description: description}) when is_binary(description),
    do: String.trim(description) != ""

  defp key_description?(_key), do: false

  defp key_description(%Key{} = key) do
    if key_description?(key) do
      key.description
    else
      gettext("No description")
    end
  end

  defp cli_key_details(%Key{cli_metadata: metadata}) do
    name = metadata["device_name"] || gettext("Device name unavailable")
    version = metadata["version"]
    if version, do: "#{name} · v#{version}", else: name
  end

  defp reload_state(socket) do
    keys =
      socket.assigns.current_space
      |> Spaces.list_user_managed_keys()
      |> Enum.map(fn key ->
        Map.put(key, :display_key, Spaces.display_api_key(key.key, key.secret))
      end)

    webhooks = Spaces.list_webhooks(socket.assigns.current_space)

    deliveries =
      if @show_recent_deliveries do
        Spaces.list_webhook_deliveries(socket.assigns.current_space, limit: 25)
      else
        []
      end

    socket
    |> assign(:space_id, socket.assigns.current_space.id)
    |> assign(:keys, keys)
    |> assign(:webhooks, webhooks)
    |> assign(:deliveries, deliveries)
    |> assign_new(:webhook_form, fn -> new_webhook_form() end)
  end

  defp new_webhook_form do
    to_form(Spaces.change_webhook(%Webhook{}, %{"enabled_events" => Webhook.mave_events()}),
      as: :webhook
    )
  end

  defp new_key_form do
    to_form(%{"description" => "", "access_level" => "read_write"}, as: :api_key)
  end

  defp key_form(%Key{} = key) do
    key
    |> Spaces.change_key()
    |> to_form(as: :api_key)
  end

  defp key_form_with_errors(changeset) do
    changeset
    |> Map.put(:action, :validate)
    |> to_form(as: :api_key)
  end

  defp toggle_modal(socket, "api_key", visible),
    do: assign(socket, :show_api_key_modal, visible)

  defp toggle_modal(socket, "create_webhook", visible),
    do: assign(socket, :show_create_webhook, visible)

  defp toggle_modal(socket, _modal, _visible), do: socket

  defp display_event_type(event_type) when is_atom(event_type) do
    event_type
    |> Atom.to_string()
    |> String.replace("_", ".")
  end

  defp display_event_type(_), do: "unknown"

  defp display_delivery_state(state) when is_atom(state) do
    state
    |> Atom.to_string()
    |> String.replace("_", " ")
  end

  defp display_delivery_state(_), do: "unknown"

  defp display_delivery_meta(delivery) do
    code =
      case delivery.response_code do
        nil -> "-"
        value -> Integer.to_string(value)
      end

    "#{delivery.attempts} attempts · #{code}"
  end
end
