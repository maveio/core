defmodule MaveCoreWeb.Dashboard.Settings.GeneralTab do
  @moduledoc false

  use MaveCoreWeb, :live_component
  import MaveCoreWeb.DashboardComponents, except: [icon: 1]

  alias MaveCore.{AccountDeletion, Accounts, GoogleOAuth, SharedStorageSpace}
  alias MaveCore.Flow
  alias MaveCore.Spaces
  alias MaveCore.Spaces.Domain
  alias MaveCore.Spaces.Space
  alias Phoenix.LiveView.JS

  @show_flow_settings false
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> MaveCoreWeb.SpaceLiveAuth.attach_component()
     |> assign(:show_flow_settings, @show_flow_settings)
     |> assign_new(:show_link_domain, fn -> false end)
     |> assign_new(:show_delete_account, fn -> false end)
     |> assign_new(:show_confirm_delete, fn -> false end)
     |> assign_new(:delete_confirmation, fn -> "" end)
     |> assign_new(:delete_account_error, fn -> nil end)
     |> reload_state()}
  end

  def render(assigns) do
    ~H"""
    <div>
      <%!-- Domains --%>
      <.subtitle label={gettext("Domains")} icon="domain">
        <%= if @domains != [] do %>
          <.dash_button
            id="settings-link-domain-button"
            variant="ghost"
            phx-click="open_modal"
            phx-value-modal="link_domain"
            phx-target={@myself}
          >
            {gettext("link domain")}
          </.dash_button>
        <% end %>
      </.subtitle>
      <%= if @domains != [] do %>
        <div class="mt-6">
          <.data_table>
            <.data_table_row :for={domain <- @domains}>
              <div class="mr-3.5 w-4 h-4">
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  class="w-4 h-4 text-stone-300"
                  width="24"
                  height="24"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="1.5"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                >
                  <circle cx="12" cy="12" r="10"></circle>
                  <line x1="2" y1="12" x2="22" y2="12"></line>
                  <path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z">
                  </path>
                </svg>
              </div>
              <div>{domain.domain}</div>
              <:actions>
                <div class="mr-2">
                  <.dash_button
                    icon="link"
                    icon_only
                    phx-click="unlink_domain"
                    phx-value-id={domain.id}
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
            <circle cx="12" cy="12" r="10"></circle>
            <line x1="2" y1="12" x2="22" y2="12"></line>
            <path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z">
            </path>
          </svg>
          <div class="text-sm text-stone-300 mt-5 mb-4">{gettext("no linked domain yet")}</div>
          <.dash_button
            id="settings-link-domain-empty-button"
            variant="ghost"
            phx-click="open_modal"
            phx-value-modal="link_domain"
            phx-target={@myself}
          >
            {gettext("link domain")}
          </.dash_button>
        </div>
      <% end %>

      <.divider />

      <%!-- Region --%>
      <.subtitle label={gettext("Region")} icon="cloud">
        <.info_hover :if={@region_help} position="left">
          {@region_help}
        </.info_hover>
      </.subtitle>
      <div class="mt-6 grid grid-cols-2 gap-4">
        <.region_card
          :for={region <- @region_cards}
          name={region.name}
          provider={region.provider}
          location={region.location}
          logo_src={region.logo_src}
          logo_alt={region.logo_alt}
          active={region_active?(@current_region, region.id)}
        />
      </div>

      <.divider />

      <%!-- Features --%>
      <.subtitle label={gettext("Features")} icon="features" />
      <div class="mt-6">
        <.data_table>
          <.data_table_row>
            <div>{gettext("Public sharing")}</div>
            <.info_hover>
              {gettext(
                "You can use a CNAME record to share a link to individual files and folders through your own domain."
              )}
            </.info_hover>
            <:actions>
              <div class="p-4">
                <.toggle
                  enabled={@features.public_sharing}
                  disabled={true}
                />
              </div>
            </:actions>
          </.data_table_row>
          <.data_table_row>
            <div>{gettext("Create spaces")}</div>
            <.info_hover>
              {gettext("Create additional spaces for e.g. your customers or services.")}
            </.info_hover>
            <:actions>
              <div class="p-4"><.toggle enabled={@features.create_spaces} disabled={true} /></div>
            </:actions>
          </.data_table_row>
          <.data_table_row>
            <div>{gettext("Hotlink protection")}</div>
            <.info_hover>
              {gettext(
                "Your videos will only be allowed to be embedded by the domains you have specified."
              )}
            </.info_hover>
            <:actions>
              <div class="p-4">
                <.toggle
                  enabled={@features.hotlink_protection}
                  disabled={@features.hotlink_protection_disabled}
                  phx-click="toggle_hotlink_protection"
                  phx-target={@myself}
                />
              </div>
            </:actions>
          </.data_table_row>
        </.data_table>
      </div>

      <.divider />

      <%= if @show_flow_settings do %>
        <%!-- Processing --%>
        <.subtitle label={gettext("Processing")} icon="video">
          <.info_hover position="left">
            {gettext(
              "Uploads use an explicit template override first, then this space default, then the platform default."
            )}
          </.info_hover>
        </.subtitle>
        <div class="mt-6">
          <.data_table>
            <.data_table_row>
              <div>{gettext("Default upload flow")}</div>
              <.info_hover>
                {gettext(
                  "Choose which flow template new uploads should use for this space when no upload-specific override is provided."
                )}
              </.info_hover>
              <:actions>
                <div class="w-80 py-3 px-4">
                  <.form
                    id="space-processing-form"
                    for={@processing_form}
                    phx-change="change_default_flow_template"
                    phx-target={@myself}
                  >
                    <.dash_select
                      field={@processing_form[:default_flow_template]}
                      options={@flow_template_options}
                    />
                  </.form>
                </div>
              </:actions>
            </.data_table_row>
          </.data_table>
          <div class="px-1 mt-3 text-sm text-stone-400">
            {gettext(
              "Built-in presets can still be used here even if they have not been installed in this environment yet."
            )}
          </div>
        </div>

        <.divider />
      <% end %>

      <%!-- Services --%>
      <%= if @google_oauth_enabled do %>
        <.subtitle label={gettext("Services")} icon="link" />
        <div class="mt-6">
          <.data_table>
            <.data_table_row>
              <div class="mr-3.5 w-4 h-4 mt-[1px]">
                <svg
                  width="15px"
                  height="15px"
                  viewBox="-3 0 262 262"
                  xmlns="http://www.w3.org/2000/svg"
                  preserveAspectRatio="xMidYMid"
                >
                  <path
                    d="M255.878 133.451c0-10.734-.871-18.567-2.756-26.69H130.55v48.448h71.947c-1.45 12.04-9.283 30.172-26.69 42.356l-.244 1.622 38.755 30.023 2.685.268c24.659-22.774 38.875-56.282 38.875-96.027"
                    fill="#4285F4"
                  >
                  </path>
                  <path
                    d="M130.55 261.1c35.248 0 64.839-11.605 86.453-31.622l-41.196-31.913c-11.024 7.688-25.82 13.055-45.257 13.055-34.523 0-63.824-22.773-74.269-54.25l-1.531.13-40.298 31.187-.527 1.465C35.393 231.798 79.49 261.1 130.55 261.1"
                    fill="#34A853"
                  >
                  </path>
                  <path
                    d="M56.281 156.37c-2.756-8.123-4.351-16.827-4.351-25.82 0-8.994 1.595-17.697 4.206-25.82l-.073-1.73L15.26 71.312l-1.335.635C5.077 89.644 0 109.517 0 130.55s5.077 40.905 13.925 58.602l42.356-32.782"
                    fill="#FBBC05"
                  >
                  </path>
                  <path
                    d="M130.55 50.479c24.514 0 41.05 10.589 50.479 19.438l36.844-35.974C195.245 12.91 165.798 0 130.55 0 79.49 0 35.393 29.301 13.925 71.947l42.211 32.783c10.59-31.477 39.891-54.251 74.414-54.251"
                    fill="#EB4335"
                  >
                  </path>
                </svg>
              </div>
              <div>Google</div>
              <:actions>
                <div class="mr-4">
                  <%= if @current_user && @current_user.google_uid do %>
                    <.dash_button
                      id="settings-google-disconnect-button"
                      icon="link"
                      phx-click="unlink_google"
                      phx-target={@myself}
                    >
                      {gettext("disconnect")}
                    </.dash_button>
                  <% else %>
                    <.dash_button
                      id="settings-google-connect-button"
                      icon="link"
                      phx-click="link_google"
                      phx-target={@myself}
                    >
                      {gettext("connect")}
                    </.dash_button>
                  <% end %>
                </div>
              </:actions>
            </.data_table_row>
          </.data_table>
        </div>
      <% end %>

      <%!-- Danger Zone --%>
      <.divider />
      <.subtitle label={gettext("Danger zone")} icon="danger" />
      <div class="mt-6">
        <.data_table>
          <.data_table_row>
            <div>{gettext("Delete Account")}</div>
            <.info_hover color="red">
              {gettext(
                "This will permanently delete your account and all data. This action cannot be undone."
              )}
            </.info_hover>
            <:actions>
              <div class="py-2 px-4 whitespace-nowrap">
                <.dash_button
                  id="settings-delete-account-button"
                  variant="danger"
                  icon="close"
                  phx-click="open_modal"
                  phx-value-modal="delete_account"
                  phx-target={@myself}
                >
                  {gettext("delete account")}
                </.dash_button>
              </div>
            </:actions>
          </.data_table_row>
        </.data_table>
      </div>

      <%!-- Link Domain Modal --%>
      <.modal
        id="link-domain-modal"
        show={@show_link_domain}
        title={gettext("Link domain")}
        on_cancel={JS.push("close_modal", value: %{modal: "link_domain"}, target: @myself)}
      >
        <.form
          id="link-domain-form"
          for={@domain_form}
          phx-submit="submit_link_domain"
          phx-target={@myself}
        >
          <.info_box>
            {gettext(
              "Specify the domain you wish to permit embedding from (necessary for hotlink protection)"
            )}
          </.info_box>
          <div class="mt-8">
            <.dash_input field={@domain_form[:domain]} placeholder="yourdomain.com" />
          </div>
          <div class="flex mt-10">
            <div class="flex-grow" />
            <.dash_button form="link-domain-form" icon="link">{gettext("link")}</.dash_button>
          </div>
        </.form>
      </.modal>

      <%!-- Delete Account Modal --%>
      <.modal
        id="delete-account-modal"
        show={@show_delete_account}
        title={gettext("Delete account")}
        on_cancel={JS.push("close_modal", value: %{modal: "delete_account"}, target: @myself)}
      >
        <div class="px-3 py-2.5 rounded-md bg-red-50 text-red-600 shadow-sm text-sm mb-8 ring-1 ring-inset ring-red-200/70">
          <div class="inline-block mr-0.5 -mb-0.5 text-red-500">
            <svg
              width="24"
              height="24"
              class="w-3.5 h-3.5"
              stroke-width="2"
              viewBox="0 0 24 24"
              fill="none"
              xmlns="http://www.w3.org/2000/svg"
            >
              <path
                d="M12 11.5V16.5"
                stroke="currentColor"
                stroke-linecap="round"
                stroke-linejoin="round"
              />
              <path
                d="M12 7.51L12.01 7.49889"
                stroke="currentColor"
                stroke-linecap="round"
                stroke-linejoin="round"
              />
              <path
                d="M12 22C17.5228 22 22 17.5228 22 12C22 6.47715 17.5228 2 12 2C6.47715 2 2 6.47715 2 12C2 17.5228 6.47715 22 12 22Z"
                stroke="currentColor"
                stroke-linecap="round"
                stroke-linejoin="round"
              />
            </svg>
          </div>
          {gettext("You can only delete your account when:")}
          <ul class="list-disc pl-5 my-2 text-sm">
            <li>{gettext("You are the owner of a single space")}</li>
            <li>{gettext("You are the only team member in the space")}</li>
            <li :for={requirement <- @account_deletion_requirements}>{requirement}</li>
          </ul>
          <p>{gettext("This action cannot be undone and will permanently erase all your data.")}</p>
        </div>
        <.info_box>
          {gettext("To confirm, please type DELETE in the field below")}
        </.info_box>
        <div
          :if={@delete_account_error}
          id="delete-account-error"
          class="mt-5 px-3 py-2.5 rounded-md bg-red-50 text-red-600 shadow-sm text-sm ring-1 ring-inset ring-red-200/70"
        >
          {@delete_account_error}
        </div>
        <div class="mt-8">
          <.dash_input
            name="delete_confirmation"
            placeholder="DELETE"
            value={@delete_confirmation}
            phx-keyup="validate_delete_confirmation"
            phx-target={@myself}
          />
        </div>
        <div class="flex mt-10">
          <div class="flex-grow" />
          <.dash_button
            id="delete-account-submit"
            variant="danger"
            icon="close"
            disabled={@delete_confirmation != "DELETE"}
            phx-click="confirm_delete_account"
            phx-target={@myself}
          >
            {gettext("delete")}
          </.dash_button>
        </div>
      </.modal>

      <%!-- Confirm Delete Account Dialog --%>
      <.dialog
        id="confirm-delete-account-dialog"
        show={@show_confirm_delete}
        on_confirm={JS.push("confirmed_account_deletion", target: @myself)}
        on_cancel={JS.push("cancel_account_deletion", target: @myself)}
      >
        {gettext(
          "Are you absolutely sure you want to delete your account and space? This action cannot be undone and will permanently erase all your data."
        )}
      </.dialog>
    </div>
    """
  end

  def handle_event("open_modal", %{"modal" => modal}, socket) do
    socket =
      case modal do
        "link_domain" -> assign(socket, :domain_form, new_domain_form())
        _ -> socket
      end

    {:noreply, toggle_modal(socket, modal, true)}
  end

  def handle_event("close_modal", %{"modal" => modal}, socket) do
    {:noreply, toggle_modal(socket, modal, false)}
  end

  def handle_event("submit_link_domain", %{"domain" => params}, socket) do
    case Spaces.create_domain(socket.assigns.current_space, params) do
      {:ok, _domain} ->
        {:noreply,
         socket
         |> assign(:show_link_domain, false)
         |> assign(:domain_form, new_domain_form())
         |> reload_state()}

      {:error, changeset} ->
        {:noreply,
         assign(
           socket,
           :domain_form,
           to_form(Map.put(changeset, :action, :validate), as: :domain)
         )}
    end
  end

  def handle_event("unlink_domain", %{"id" => id}, socket) do
    socket =
      case Spaces.get_domain_for_space(socket.assigns.current_space, id) do
        nil ->
          socket

        domain ->
          _ = Spaces.delete_domain(domain)
          reload_state(socket)
      end

    {:noreply, socket}
  end

  def handle_event("toggle_public_sharing", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("toggle_hotlink_protection", _params, socket) do
    attrs = %{
      hotlink_protection_enabled: !socket.assigns.current_space.hotlink_protection_enabled
    }

    case Spaces.update_space_features(socket.assigns.current_space, attrs) do
      {:ok, updated_space} ->
        {:noreply,
         socket
         |> notify_parent(updated_space)
         |> assign(:current_space, updated_space)
         |> reload_state()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not update hotlink protection."))}
    end
  end

  def handle_event("change_default_flow_template", %{"processing" => params}, socket) do
    case Spaces.update_space_processing(socket.assigns.current_space, %{
           default_flow_template: Map.get(params, "default_flow_template")
         }) do
      {:ok, updated_space} ->
        {:noreply,
         socket
         |> notify_parent(updated_space)
         |> assign(:current_space, updated_space)
         |> reload_state()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not update default flow."))}
    end
  end

  def handle_event("link_google", _params, socket) do
    if GoogleOAuth.enabled?() do
      start_google_link(socket)
    else
      {:noreply, put_flash(socket, :error, gettext("Google connection is not configured."))}
    end
  end

  def handle_event("unlink_google", _params, socket) do
    case Accounts.unlink_google(socket.assigns.current_user) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:current_user, user)
         |> put_flash(:info, gettext("Google account disconnected."))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not disconnect Google."))}
    end
  end

  def handle_event("validate_delete_confirmation", %{"value" => value}, socket) do
    {:noreply, assign(socket, :delete_confirmation, value)}
  end

  def handle_event("confirm_delete_account", _params, socket) do
    if socket.assigns.delete_confirmation == "DELETE" do
      case Accounts.can_delete_account_and_space?(
             socket.assigns.current_user,
             socket.assigns.current_space
           ) do
        :ok ->
          {:noreply,
           socket
           |> assign(:delete_account_error, nil)
           |> assign(:show_delete_account, false)
           |> assign(:show_confirm_delete, true)}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:delete_account_error, delete_account_error(reason))
           |> assign(:show_confirm_delete, false)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("confirmed_account_deletion", _params, socket) do
    case Accounts.delete_account_and_space(
           socket.assigns.current_user,
           socket.assigns.current_space
         ) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Your account and space have been deleted."))
         |> redirect(to: "/login")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:show_confirm_delete, false)
         |> assign(:show_delete_account, true)
         |> assign(:delete_account_error, delete_account_error(reason))
         |> assign(:delete_confirmation, "")}
    end
  end

  def handle_event("cancel_account_deletion", _params, socket) do
    {:noreply, assign(socket, :show_confirm_delete, false)}
  end

  defp start_google_link(socket) do
    case Accounts.mark_google_link_pending(socket.assigns.current_user) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:current_user, user)
         |> redirect(to: ~p"/auth/google")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not start Google connection."))}
    end
  end

  defp reload_state(socket) do
    current_space = socket.assigns.current_space

    socket
    |> assign(:domains, Spaces.list_domains(current_space))
    |> assign(:domain_form, Map.get(socket.assigns, :domain_form, new_domain_form()))
    |> assign_flow_settings(current_space)
    |> assign(:current_region, current_space.region)
    |> assign(:region_cards, dashboard_region_cards(current_space))
    |> assign(:region_help, dashboard_region_help(current_space))
    |> assign(:account_deletion_requirements, AccountDeletion.requirements())
    |> assign(:google_oauth_enabled, GoogleOAuth.enabled?())
    |> assign(:features, %{
      public_sharing: current_space.public_sharing_enabled,
      create_spaces: false,
      hotlink_protection: hotlink_protection_enabled?(current_space),
      hotlink_protection_disabled: SharedStorageSpace.shared?(current_space)
    })
  end

  defp notify_parent(socket, updated_space) do
    send(self(), {:settings_space_updated, updated_space})
    socket
  end

  defp new_domain_form do
    to_form(Spaces.change_domain(%Domain{}, %{}), as: :domain)
  end

  defp toggle_modal(socket, "link_domain", visible),
    do: assign(socket, :show_link_domain, visible)

  defp toggle_modal(socket, "delete_account", true) do
    socket
    |> assign(:show_delete_account, true)
    |> assign(:delete_account_error, nil)
  end

  defp toggle_modal(socket, "delete_account", false) do
    socket
    |> assign(:show_delete_account, false)
    |> assign(:delete_account_error, nil)
    |> assign(:delete_confirmation, "")
  end

  defp toggle_modal(socket, "confirm_delete", visible),
    do: assign(socket, :show_confirm_delete, visible)

  defp toggle_modal(socket, _modal, _visible), do: socket

  defp delete_account_error("Memberships exist"),
    do:
      gettext("You can only delete your account when you are the only team member in the space.")

  defp delete_account_error("Part of other space"),
    do: gettext("You can only delete your account when you own a single space.")

  defp delete_account_error(reason) do
    AccountDeletion.error_message(reason) || gettext("Could not delete your account.")
  end

  defp assign_flow_settings(socket, current_space) do
    if @show_flow_settings do
      socket
      |> assign(:processing_form, processing_form(current_space))
      |> assign(:flow_template_options, flow_template_options())
    else
      socket
    end
  end

  defp processing_form(space) do
    to_form(
      %{"default_flow_template" => space.default_flow_template || ""},
      as: :processing
    )
  end

  defp flow_template_options do
    [{"Platform default (#{platform_default_template()})", ""}] ++
      Enum.map(Flow.list_templates(), fn template ->
        {flow_template_label(template), template.slug}
      end)
  end

  defp flow_template_label(template) do
    suffix =
      cond do
        template.builtin and not template.installed -> " [preset]"
        template.builtin -> " [built-in]"
        true -> " [custom]"
      end

    "#{template.name} (#{template.slug})#{suffix}"
  end

  defp platform_default_template do
    :mave_core
    |> Application.get_env(:upload, [])
    |> Keyword.get(:default_template, "publish_default")
  end

  defp hotlink_protection_enabled?(%Space{} = space) do
    not SharedStorageSpace.shared?(space) and space.hotlink_protection_enabled
  end

  defp dashboard_region_cards(%Space{} = current_space) do
    static_region_cards = Application.get_env(:mave_core, :extra_dashboard_regions, [])
    provider_region_cards = provider_region_cards(current_space)
    current_region = normalize_region(current_space.region)

    cards =
      (region_cards_from_config(static_region_cards) ++
         region_cards_from_config(provider_region_cards))
      |> Enum.map(&normalize_region_card/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.id)

    if Enum.any?(cards, &(normalize_region(&1.id) == current_region)) do
      cards
    else
      cards ++ [default_region_card(current_region)]
    end
  end

  defp region_cards_from_config([]), do: []

  defp region_cards_from_config(region_cards) when is_list(region_cards) do
    if Keyword.keyword?(region_cards), do: [region_cards], else: region_cards
  end

  defp region_cards_from_config(nil), do: []
  defp region_cards_from_config(region_card), do: [region_card]

  defp provider_region_cards(%Space{} = current_space) do
    case Application.get_env(:mave_core, :dashboard_region_provider) do
      {module, function} when is_atom(module) and is_atom(function) ->
        apply_region_provider(module, function, current_space)

      module when is_atom(module) ->
        apply_region_provider(module, :regions_for_space, current_space)

      _provider ->
        []
    end
  end

  defp dashboard_region_help(%Space{} = current_space) do
    case Application.get_env(:mave_core, :dashboard_region_provider) do
      module when is_atom(module) -> apply_region_provider_help(module, current_space)
      _provider -> nil
    end
  end

  defp apply_region_provider_help(module, %Space{} = current_space) do
    if Code.ensure_loaded?(module) and function_exported?(module, :region_help, 1) do
      case module.region_help(current_space) do
        value when is_binary(value) and value != "" -> value
        _value -> nil
      end
    end
  end

  defp apply_region_provider(module, function, %Space{} = current_space) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, 1) do
      module
      |> apply(function, [current_space])
      |> List.wrap()
    else
      []
    end
  end

  defp normalize_region_card(region) when is_list(region) do
    region
    |> Map.new()
    |> normalize_region_card()
  end

  defp normalize_region_card(region) when is_map(region) do
    case config_string(region, :id) do
      id when is_binary(id) ->
        %{
          id: id,
          name: config_string(region, :name, String.upcase(id)),
          provider: config_string(region, :provider, gettext("S3-compatible storage")),
          location: config_string(region, :location, gettext("Configured storage profile")),
          logo_src: config_string(region, :logo_src),
          logo_alt: config_string(region, :logo_alt, "")
        }

      _ ->
        nil
    end
  end

  defp normalize_region_card(_region), do: nil

  defp default_region_card(region) do
    id = region || "default"

    %{
      id: id,
      name: String.upcase(id),
      provider: gettext("S3-compatible storage"),
      location: gettext("Configured storage profile"),
      logo_src: nil,
      logo_alt: ""
    }
  end

  defp config_string(config, key, default \\ nil) do
    value =
      case Map.fetch(config, key) do
        {:ok, value} -> value
        :error -> Map.get(config, Atom.to_string(key))
      end

    normalize_region(value) || default
  end

  defp region_active?(current_region, expected_region) do
    normalize_region(current_region) == normalize_region(expected_region)
  end

  defp normalize_region(nil), do: nil
  defp normalize_region(region) when is_atom(region), do: Atom.to_string(region)

  defp normalize_region(region) when is_binary(region) do
    case String.trim(region) do
      "" -> nil
      region -> region
    end
  end

  defp normalize_region(_region), do: nil
end
