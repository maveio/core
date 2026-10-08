defmodule MaveCoreWeb.Dashboard.Settings.TeamTab do
  @moduledoc false

  use MaveCoreWeb, :live_component
  import MaveCoreWeb.DashboardComponents, except: [icon: 1]

  alias MaveCore.Accounts
  alias MaveCore.Accounts.User
  alias MaveCore.Spaces
  alias MaveCore.UsageLimits
  alias MaveCoreWeb.DashboardRoutes
  alias Phoenix.LiveView.JS

  @avatar_colors [
    "red",
    "orange",
    "amber",
    "yellow",
    "lime",
    "green",
    "emerald",
    "teal",
    "cyan",
    "sky",
    "blue",
    "indigo",
    "violet",
    "purple",
    "fuchsia",
    "pink",
    "rose",
    "stone"
  ]

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> MaveCoreWeb.SpaceLiveAuth.attach_component()
     |> assign_new(:show_add_member, fn -> false end)
     |> assign_new(:member_form, fn -> new_member_form() end)
     |> assign_new(:add_member_error, fn -> nil end)
     |> reload_state()}
  end

  def render(assigns) do
    ~H"""
    <div>
      <.subtitle label={gettext("Team")} icon="team">
        <div
          :if={@add_member_notice}
          id="settings-add-member-limit-notice"
          class="flex-none mr-6 text-stone-400 text-opacity-70 text-sm cursor-default flex items-center"
        >
          <div>{@add_member_notice}</div>
          <.info_hover position="left">
            {@add_member_help}
          </.info_hover>
        </div>
        <.dash_button
          id="settings-add-member-button"
          variant="ghost"
          disabled={!@can_manage_team or !@can_add_member}
          title={@add_member_help}
          phx-click="open_modal"
          phx-value-modal="add_member"
          phx-target={@myself}
        >
          {gettext("add member")}
        </.dash_button>
      </.subtitle>

      <div class="mt-6">
        <.data_table>
          <.data_table_row :for={member <- @members}>
            <.data_avatar initials={member_initials(member.email)} color={member_color(member.id)} />
            <div>
              {String.downcase(member.email)}
              <svg
                :if={member.pending}
                xmlns="http://www.w3.org/2000/svg"
                viewBox="0 0 16 16"
                fill="currentColor"
                class="w-3.5 opacity-30 inline align-middle ml-1.5 mb-0.5"
              >
                <path d="M2.5 3A1.5 1.5 0 0 0 1 4.5v.793c.026.009.051.02.076.032L7.674 8.51c.206.1.446.1.652 0l6.598-3.185A.755.755 0 0 1 15 5.293V4.5A1.5 1.5 0 0 0 13.5 3h-11Z" />
                <path d="M15 6.954 8.978 9.86a2.25 2.25 0 0 1-1.956 0L1 6.954V11.5A1.5 1.5 0 0 0 2.5 13h11a1.5 1.5 0 0 0 1.5-1.5V6.954Z" />
              </svg>
            </div>
            <:actions>
              <div :if={can_remove_member?(@can_manage_team, member)} class="mr-2">
                <.dash_button
                  icon="delete"
                  icon_only
                  phx-click="remove_member"
                  phx-value-id={member.id}
                  phx-target={@myself}
                />
              </div>
            </:actions>
          </.data_table_row>
        </.data_table>
      </div>

      <%!-- Add Member Modal --%>
      <.modal
        id="add-member-modal"
        show={@show_add_member}
        title={gettext("Add member")}
        on_cancel={JS.push("close_modal", value: %{modal: "add_member"}, target: @myself)}
      >
        <.form
          id="add-member-form"
          for={@member_form}
          phx-submit="submit_add_member"
          phx-target={@myself}
        >
          <div class="mb-8">
            <.dash_input field={@member_form[:email]} placeholder="j.doe@example.com" />
            <div :if={@add_member_error} class="text-red-400 text-sm mt-3">
              {@add_member_error}
            </div>
          </div>
          <div class="flex mt-10">
            <div class="flex-grow" />
            <.dash_button
              form="add-member-form"
              icon="create"
              disabled={!@can_add_member}
              title={@add_member_help}
            >
              {gettext("add")}
            </.dash_button>
          </div>
        </.form>
      </.modal>
    </div>
    """
  end

  # Hidden controls do not stop a client from pushing these events, so only
  # accounts that may manage this team can change its members.
  def handle_event(event, _params, %{assigns: %{can_manage_team: false}} = socket)
      when event in ["submit_add_member", "remove_member"] do
    {:noreply, socket}
  end

  def handle_event("open_modal", %{"modal" => "add_member"}, socket) do
    if socket.assigns.can_manage_team and socket.assigns.can_add_member do
      socket =
        socket
        |> assign(:member_form, new_member_form())
        |> assign(:add_member_error, nil)

      {:noreply, toggle_modal(socket, "add_member", true)}
    else
      {:noreply, assign_add_member_status(socket)}
    end
  end

  def handle_event("open_modal", %{"modal" => modal}, socket) do
    {:noreply, toggle_modal(socket, modal, true)}
  end

  def handle_event("close_modal", %{"modal" => modal}, socket) do
    {:noreply, toggle_modal(socket, modal, false)}
  end

  def handle_event("submit_add_member", %{"member" => %{"email" => email}}, socket) do
    email_changeset = Accounts.change_login_user(%{"email" => email})

    if email_changeset.valid? do
      case invite_member_to_space(
             socket.assigns.current_space,
             socket.assigns.current_user,
             email
           ) do
        {:ok, _membership} ->
          {:noreply,
           socket
           |> assign(:show_add_member, false)
           |> assign(:member_form, new_member_form())
           |> assign(:add_member_error, nil)
           |> reload_state()
           |> put_flash(:info, gettext("Invitation sent."))}

        {:error, :already_member} ->
          {:noreply,
           assign(socket, :add_member_error, gettext("This user is already in the team."))}

        {:error, :invalid_email} ->
          {:noreply, assign(socket, :add_member_error, gettext("Doesn't seem right"))}

        {:error, reason} ->
          copy = UsageLimits.restriction_copy(:add_space_member, reason)

          {:noreply,
           socket
           |> assign(:add_member_error, Map.get(copy, :error, gettext("Could not add member.")))
           |> assign_add_member_status()}
      end
    else
      {:noreply,
       assign(
         socket,
         :member_form,
         to_form(Map.put(email_changeset, :action, :validate), as: :member)
       )}
    end
  end

  def handle_event("remove_member", %{"id" => membership_id}, socket) do
    current_user_id = socket.assigns.current_user.id

    case Spaces.remove_member(socket.assigns.current_space, membership_id) do
      {:ok, %{user_id: ^current_user_id}} ->
        case Accounts.ensure_default_space(socket.assigns.current_user) do
          {:ok, user} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("You left the team."))
             |> push_navigate(to: DashboardRoutes.signed_in_path(user))}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Could not leave team."))}
        end

      {:ok, _membership} ->
        {:noreply, reload_state(socket)}

      {:error, :cannot_remove_owner} ->
        {:noreply, put_flash(socket, :error, gettext("The owner cannot be removed."))}

      {:error, :not_found} ->
        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not remove member."))}
    end
  end

  defp reload_state(socket) do
    members =
      socket.assigns.current_space
      |> Spaces.list_memberships()
      |> Enum.map(fn membership ->
        invite = membership.invite

        %{
          id: membership.id,
          email: member_email(membership),
          role: membership.role,
          pending: invite && is_nil(invite.accepted_at),
          kind: membership_kind(membership)
        }
      end)
      |> sort_members()

    socket
    |> assign(:members, members)
    |> assign(
      :can_manage_team,
      can_manage_team?(socket.assigns.current_user, socket.assigns.current_space)
    )
    |> assign_add_member_status()
  end

  defp assign_add_member_status(socket) do
    case UsageLimits.can_add_space_member?(socket.assigns.current_space, "member") do
      :ok ->
        socket
        |> assign(:can_add_member, true)
        |> assign(:add_member_notice, nil)
        |> assign(:add_member_help, nil)

      {:error, reason} ->
        copy = UsageLimits.restriction_copy(:add_space_member, reason)

        socket
        |> assign(:can_add_member, false)
        |> assign(
          :add_member_notice,
          Map.get(copy, :notice, gettext("Team member invites are unavailable"))
        )
        |> assign(
          :add_member_help,
          Map.get(copy, :help, gettext("This space cannot add more team members right now."))
        )
    end
  end

  defp can_manage_team?(%{current_space_membership: %{space_id: space_id}}, %{
         id: space_id
       }),
       do: true

  defp can_manage_team?(_, _), do: false

  defp can_remove_member?(false, _member), do: false

  defp can_remove_member?(_can_manage_team, %{kind: :manager_space}), do: false

  defp can_remove_member?(_can_manage_team, %{role: role}) when role in ["owner", :owner],
    do: false

  defp can_remove_member?(_, _), do: true

  defp new_member_form do
    to_form(Accounts.change_login_user(%{}), as: :member)
  end

  defp toggle_modal(socket, "add_member", visible), do: assign(socket, :show_add_member, visible)
  defp toggle_modal(socket, _modal, _visible), do: socket

  defp member_initials(email) when is_binary(email) do
    email
    |> String.slice(0, 2)
    |> String.upcase()
  end

  defp member_initials(_), do: "NA"

  defp member_color(id) when is_binary(id) do
    number =
      id
      |> to_string()
      |> String.to_charlist()
      |> Enum.join()
      |> Integer.parse()
      |> case do
        {value, _rest} ->
          value

        :error ->
          id
          |> to_string()
          |> String.replace(~r/\D/, "")
          |> Integer.parse()
          |> case do
            {value, _rest} -> value
            :error -> 0
          end
      end

    size = length(@avatar_colors) - 1
    Enum.at(@avatar_colors, rem(number, size))
  end

  defp member_color(_), do: "blue"

  defp invite_member_to_space(space, inviter, email) do
    normalized_email = email |> String.trim() |> String.downcase()

    with {:ok, user} <- ensure_member_user(normalized_email),
         {:ok, membership} <- Spaces.create_membership_invite(space, inviter, normalized_email) do
      maybe_send_space_invite_email(user, space, inviter, membership)
      {:ok, membership}
    end
  end

  defp ensure_member_user(email) do
    case Accounts.get_user_by_email(email) do
      %User{} = user -> {:ok, user}
      nil -> Accounts.create_invited_user(email)
    end
  end

  defp maybe_send_space_invite_email(%User{} = user, space, inviter, %{invite: %{id: invite_id}})
       when is_binary(invite_id) do
    if Accounts.can_create_new_invite_token(user.email) do
      _ =
        Accounts.deliver_space_invite_instructions(user, space, inviter, fn token ->
          "/space?invite=#{invite_id}&token=#{token}"
        end)
    end

    :ok
  end

  defp maybe_send_space_invite_email(%User{}, _space, _inviter, _membership), do: :ok

  defp member_email(%{user: %User{email: email}}) when is_binary(email), do: email

  defp member_email(%{invite: %{email: email}}) when is_binary(email), do: email

  defp member_email(%{invite: %{user: %User{email: email}}}) when is_binary(email), do: email

  defp member_email(%{owner_space: %{domains: [%{domain: domain} | _]}})
       when is_binary(domain) and domain != "",
       do: domain

  defp member_email(%{owner_space: %{}}), do: gettext("Managed by other space")

  defp member_email(_membership), do: ""

  defp membership_kind(%{owner_space_id: owner_space_id}) when is_binary(owner_space_id),
    do: :manager_space

  defp membership_kind(_membership), do: :member

  defp sort_members(members) do
    Enum.sort_by(members, fn member ->
      {member.kind != :manager_space, member.pending, member.email}
    end)
  end
end
