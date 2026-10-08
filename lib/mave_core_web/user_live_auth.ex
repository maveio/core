defmodule MaveCoreWeb.UserLiveAuth do
  @moduledoc false

  use MaveCoreWeb, :live_view

  import MaveCoreWeb.DashboardComponents

  alias MaveCore.Accounts
  alias MaveCore.Embeds
  alias MaveCore.LegacyShortUUID
  alias MaveCore.SpaceCreation
  alias MaveCore.Spaces.Space
  alias MaveCoreWeb.DashboardRoutes
  alias MaveCoreWeb.Plugs.Maintenance
  alias Phoenix.LiveView.JS

  def render(assigns) do
    ~H"""
    """
  end

  attr :show, :boolean, required: true
  attr :form, :map, required: true
  attr :owner_space_options, :list, required: true

  def create_space_modal(assigns) do
    assigns =
      assigns
      |> assign(:owner_space_count, length(assigns.owner_space_options))
      |> assign(:single_owner_space_option, List.first(assigns.owner_space_options))
      |> assign(:standalone_space_description, SpaceCreation.standalone_description())

    ~H"""
    <.modal
      id="create-space-modal"
      show={@show}
      title={gettext("Add new space")}
      on_cancel={JS.push("discard_create_space")}
    >
      <.form id="create-space-form" for={@form} phx-submit="confirm_create_space">
        <div class="px-3 py-2.5 rounded-md bg-stone-50 text-stone-400 shadow-sm text-sm mb-8 ring-1 ring-inset ring-stone-200 ring-opacity-70">
          <%= cond do %>
            <% @owner_space_count == 1 -> %>
              {gettext("This new space will be managed by")}
              <strong>{elem(@single_owner_space_option, 0)}</strong> {gettext(
                "and all of its members will be automatically added to this team."
              )}
            <% @owner_space_count > 1 -> %>
              {gettext(
                "Select a space that will manage this new space from the list. All of its members will be automatically added to this team."
              )}
            <% true -> %>
              {@standalone_space_description}
          <% end %>
        </div>

        <input
          :if={@owner_space_count == 1}
          type="hidden"
          name={@form[:owner_space_id].name}
          id={@form[:owner_space_id].id}
          value={elem(@single_owner_space_option, 1)}
        />

        <div :if={@owner_space_count > 1} class="mb-4">
          <.dash_select
            field={@form[:owner_space_id]}
            options={@owner_space_options}
            prompt={gettext("Select owner space")}
          />
        </div>

        <div class="mb-4">
          <.dash_input field={@form[:domain]} placeholder="domain of your new space" />
        </div>

        <div class="flex mt-10">
          <div class="flex-grow" />
          <.dash_button form="create-space-form" icon="create">{gettext("add")}</.dash_button>
        </div>
      </.form>
    </.modal>
    """
  end

  def on_mount(:authenticated, params, session, socket) do
    mount_authenticated(params, session, socket)
  end

  def on_mount(:redirect_if_authenticated, _params, session, socket) do
    with user_token when is_binary(user_token) <- session["user_token"],
         %{} = user <- Accounts.get_user_by_session_token(user_token),
         {:ok, user_with_space} <- Accounts.ensure_default_space(user),
         %{} <- current_space(user_with_space) do
      {:halt, redirect(socket, to: DashboardRoutes.signed_in_path(user_with_space))}
    else
      _ ->
        {:cont, assign_new(socket, :current_user, fn -> nil end)}
    end
  end

  def on_mount(:authenticated_no_default_space, _params, session, socket) do
    mount_authenticated_no_default_space(session, socket)
  end

  def on_mount(:optional_no_default_space, _params, session, socket) do
    mount_optional_no_default_space(session, socket)
  end

  defp mount_authenticated(params, session, socket) do
    with user_token when is_binary(user_token) <- session["user_token"],
         %{} = user <- Accounts.get_user_by_session_token(user_token),
         {:ok, user_with_space} <- Accounts.ensure_default_space(user) do
      user_with_space
      |> maybe_set_space_from_param(params["space_id"])
      |> mount_authenticated_space(socket)
    else
      _ ->
        {:halt, redirect(socket, to: ~p"/login")}
    end
  end

  defp mount_authenticated_space(user_with_space, socket) do
    case current_space(user_with_space) do
      %{} = current_space ->
        user_with_space
        |> assign_authenticated_space(socket, current_space)
        |> continue_if_maintenance_allows(user_with_space)

      _ ->
        {:halt, redirect(socket, to: ~p"/login")}
    end
  end

  defp assign_authenticated_space(user_with_space, socket, current_space) do
    spaces = Accounts.list_user_spaces(user_with_space)

    socket
    |> MaveCoreWeb.SpaceLiveAuth.attach_view()
    |> attach_dashboard_space_hooks()
    |> assign(:current_user, user_with_space)
    |> assign(:current_space, current_space)
    |> assign(:space_access_context, nil)
    |> assign(:sidebar_usage, resolve_sidebar_usage(current_space))
    |> assign(:suggests, [])
    |> assign(:spaces, spaces)
    |> assign_can_create_space()
    |> assign(:show_create_space_modal, false)
    |> assign(:create_space_form, to_form(SpaceCreation.change_form(%{}), as: :space))
    |> assign(:create_space_owner_space_options, [])
  end

  defp continue_if_maintenance_allows(socket, user_with_space) do
    if maintenance_allows_user?(user_with_space) do
      {:cont, socket}
    else
      {:halt, redirect(socket, to: ~p"/")}
    end
  end

  defp mount_authenticated_no_default_space(session, socket) do
    with user_token when is_binary(user_token) <- session["user_token"],
         %{} = user <- Accounts.get_user_by_session_token(user_token) do
      socket =
        socket
        |> assign(:user_token, user_token)
        |> assign(:current_user, user)
        |> assign(:current_space, current_space(user))
        |> assign(:spaces, Accounts.list_user_spaces(user))

      if maintenance_allows_user?(user) do
        {:cont, socket}
      else
        {:halt, redirect(socket, to: ~p"/")}
      end
    else
      _ ->
        {:halt, redirect(socket, to: ~p"/login")}
    end
  end

  defp mount_optional_no_default_space(session, socket) do
    with user_token when is_binary(user_token) <- session["user_token"],
         %{} = user <- Accounts.get_user_by_session_token(user_token) do
      socket =
        socket
        |> assign(:user_token, user_token)
        |> assign(:current_user, user)
        |> assign(:current_space, current_space(user))
        |> assign(:spaces, Accounts.list_user_spaces(user))

      if maintenance_allows_user?(user) do
        {:cont, socket}
      else
        {:halt, redirect(socket, to: ~p"/")}
      end
    else
      _ ->
        {:cont,
         socket
         |> assign(:user_token, nil)
         |> assign(:current_user, nil)
         |> assign(:current_space, nil)
         |> assign(:spaces, [])}
    end
  end

  defp current_space(%{current_space_membership: %{space: %Space{} = space}}), do: space
  defp current_space(_), do: nil

  defp maintenance_allows_user?(user) do
    not Maintenance.enabled?() or Maintenance.internal_user?(user)
  end

  defp attach_dashboard_space_hooks(socket) do
    attach_hook(socket, :dashboard_space_picker, :handle_event, fn
      "switch_space", %{"id" => space_id}, socket ->
        case Accounts.set_current_space_by_id(socket.assigns.current_user, space_id) do
          {:ok, user} ->
            {:halt,
             socket
             |> assign(:current_user, user)
             |> assign(:current_space, current_space(user))
             |> assign(:sidebar_usage, resolve_sidebar_usage(current_space(user)))
             |> assign(:suggests, [])
             |> assign(:spaces, Accounts.list_user_spaces(user))
             |> assign_can_create_space()
             |> redirect(to: DashboardRoutes.signed_in_path(user))}

          {:error, _reason} ->
            {:halt, put_flash(socket, :error, gettext("Could not switch space"))}
        end

      "create_space", _params, socket ->
        if socket.assigns.can_create_space do
          owner_space_options =
            SpaceCreation.owner_space_options_for_user(socket.assigns.current_user)

          changeset =
            SpaceCreation.change_form(%{},
              require_owner_space?: owner_space_options != []
            )

          {:halt,
           socket
           |> assign(:show_create_space_modal, true)
           |> assign(:create_space_form, to_form(changeset, as: :space))
           |> assign(:create_space_owner_space_options, owner_space_options)}
        else
          {:halt, put_flash(socket, :error, gettext("Could not create space"))}
        end

      "discard_create_space", _params, socket ->
        {:halt, reset_create_space_modal(socket)}

      "confirm_create_space", %{"space" => attrs}, socket ->
        if socket.assigns.can_create_space do
          changeset =
            SpaceCreation.change_form(attrs,
              require_owner_space?: create_space_requires_owner_space?(socket)
            )

          handle_confirm_create_space(socket, changeset)
        else
          {:halt, put_flash(socket, :error, gettext("Could not create space"))}
        end

      "search", %{"value" => query}, socket ->
        archived = Map.get(socket.assigns, :current_tab) == :archive

        {:halt,
         assign(
           socket,
           :suggests,
           Embeds.search_video_suggestions(socket.assigns.current_space, query || "",
             archived: archived
           )
         )}

      "search_embed", %{"id" => id}, socket ->
        {:halt,
         socket
         |> assign(:suggests, [])
         |> push_navigate(
           to:
             DashboardRoutes.video_path(
               socket.assigns.current_space,
               id,
               Map.get(socket.assigns, :current_tab, :all)
             )
         )}

      _event, _params, socket ->
        {:cont, socket}
    end)
  end

  defp resolve_sidebar_usage(%Space{} = space) do
    case Application.get_env(:mave_core, :dashboard_sidebar_usage_provider) do
      {module, function} when is_atom(module) and is_atom(function) ->
        with true <- Code.ensure_loaded?(module),
             true <- function_exported?(module, function, 1) do
          module
          |> apply(function, [space])
          |> normalize_sidebar_usage()
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp resolve_sidebar_usage(_), do: nil

  defp normalize_sidebar_usage(%{usage: usage}) when is_map(usage), do: usage
  defp normalize_sidebar_usage(usage) when is_map(usage), do: usage
  defp normalize_sidebar_usage(_), do: nil

  defp maybe_set_space_from_param(%{} = user, space_id)
       when is_binary(space_id) and space_id != "" do
    with {:ok, id} <- LegacyShortUUID.cast(space_id),
         {:ok, updated_user} <- Accounts.set_current_space_by_id(user, id) do
      updated_user
    else
      _ -> user
    end
  end

  defp maybe_set_space_from_param(user, _), do: user

  defp reset_create_space_modal(socket) do
    socket
    |> assign(:show_create_space_modal, false)
    |> assign(:create_space_form, to_form(SpaceCreation.change_form(%{}), as: :space))
    |> assign(:create_space_owner_space_options, [])
  end

  defp create_space_requires_owner_space?(socket) do
    Map.get(socket.assigns, :create_space_owner_space_options, []) != []
  end

  defp handle_confirm_create_space(socket, changeset) do
    if changeset.valid? do
      handle_valid_create_space(socket, changeset)
    else
      {:halt,
       assign(
         socket,
         :create_space_form,
         to_form(Map.put(changeset, :action, :validate), as: :space)
       )}
    end
  end

  defp handle_valid_create_space(socket, changeset) do
    socket.assigns.current_user
    |> SpaceCreation.create_space_for_user(Ecto.Changeset.apply_changes(changeset))
    |> handle_create_space_result(socket, changeset)
  end

  defp handle_create_space_result({:ok, user}, socket, _changeset) do
    {:halt,
     socket
     |> reset_create_space_modal()
     |> assign(:current_user, user)
     |> assign(:current_space, current_space(user))
     |> assign(:sidebar_usage, resolve_sidebar_usage(current_space(user)))
     |> assign(:suggests, [])
     |> assign(:spaces, Accounts.list_user_spaces(user))
     |> assign_can_create_space()
     |> redirect(to: DashboardRoutes.signed_in_path(user))}
  end

  defp handle_create_space_result({:error, :invalid_owner_space}, socket, changeset) do
    {:halt,
     assign(
       socket,
       :create_space_form,
       changeset
       |> SpaceCreation.add_owner_space_error()
       |> Map.put(:action, :validate)
       |> to_form(as: :space)
     )}
  end

  defp handle_create_space_result(
         {:error, %Ecto.Changeset{} = changeset},
         socket,
         _original_changeset
       ) do
    {:halt, assign(socket, :create_space_form, to_form(changeset, as: :space))}
  end

  defp handle_create_space_result({:error, _reason}, socket, _changeset) do
    {:halt, put_flash(socket, :error, gettext("Could not create space"))}
  end

  defp assign_can_create_space(socket) do
    assign(
      socket,
      :can_create_space,
      SpaceCreation.can_create_space_for_user?(
        socket.assigns.current_user,
        socket.assigns.current_space
      )
    )
  end
end
