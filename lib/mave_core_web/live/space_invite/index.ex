defmodule MaveCoreWeb.SpaceInvite.Index do
  @moduledoc false

  use MaveCoreWeb, :live_view
  import MaveCoreWeb.DashboardComponents, except: [icon: 1]

  alias MaveCore.Accounts
  alias MaveCore.Spaces
  alias MaveCore.Spaces.Membership
  alias MaveCoreWeb.DashboardRoutes

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Space invite"))
     |> assign(:membership, nil)
     |> assign(:invite_email, nil)
     |> assign(:invite_status, :pending)
     |> assign(:invite_destination, nil)
     |> assign(:invite_destination_label, nil)}
  end

  @impl true
  def handle_params(%{"invite" => invite_id}, _uri, socket) do
    case load_invite(socket.assigns.current_user, invite_id) do
      {:ok, membership} ->
        {:noreply,
         socket
         |> assign(:membership, membership)
         |> assign(:invite_email, invite_email(membership))
         |> assign(:invite_status, :pending)
         |> assign(:invite_destination, nil)
         |> assign(:invite_destination_label, nil)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:membership, nil)
         |> assign(:invite_email, nil)
         |> assign(:invite_status, :gone)
         |> assign_unavailable_invite_destination()}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:membership, nil)
     |> assign(:invite_email, nil)
     |> assign(:invite_status, :gone)
     |> assign_unavailable_invite_destination()}
  end

  @impl true
  def handle_event(
        "accept_invite",
        _,
        %{assigns: %{membership: %Membership{} = membership}} = socket
      ) do
    case Spaces.accept_membership_invite(membership, socket.assigns.current_user) do
      {:ok, accepted_membership} ->
        :ok = Accounts.invalidate_login_token_for_session(socket.assigns.user_token)

        {:ok, updated_user} =
          Accounts.set_current_space_by_hash(
            socket.assigns.current_user,
            accepted_membership.space.hash
          )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Invitation accepted."))
         |> push_navigate(to: DashboardRoutes.signed_in_path(updated_user))}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:membership, nil)
         |> assign(:invite_status, :gone)
         |> assign_unavailable_invite_destination()}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="fixed top-0 left-0 w-screen h-screen bg-stone-100 z-40 flex items-center justify-center px-6">
      <section
        id="space-invite-panel"
        class="w-full max-w-sm bg-stone-50 ring-1 ring-stone-300 border border-white border-opacity-50 ring-opacity-50 rounded-md shadow-sm shadow-stone-200 flex flex-col items-center px-8 py-8"
      >
        <div class="mx-auto my-6 w-28 h-28 bg-white ring-1 ring-stone-300 ring-opacity-40 rounded-full transition hover:scale-105 hover:shadow-md hover:shadow-stone-200 flex items-center justify-center">
          <.animated_icon
            name="envelope"
            class="w-16 h-16 opacity-60"
            speed="1.1"
          />
        </div>

        <h1 class="text-xl font-medium text-stone-700 mt-4">
          <%= if @invite_status == :gone do %>
            {gettext("Invite no longer available")}
          <% else %>
            {gettext("Space invite")}
          <% end %>
        </h1>

        <p class="text-stone-400 text-sm mt-4 max-w-[16rem] mx-auto text-center leading-6">
          <%= if @invite_status == :gone do %>
            {gettext(
              "This invite was removed or has already been used. Ask the space owner to send a new invite."
            )}
          <% else %>
            {gettext("You've been invited to join this space as %{email}.",
              email: @invite_email || gettext("a team member")
            )}
          <% end %>
        </p>

        <div class="mt-14 mb-2 flex w-full justify-end">
          <.dash_button
            :if={@invite_status == :pending}
            id="accept-space-invite-button"
            phx-click="accept_invite"
          >
            {gettext("continue")}
          </.dash_button>
          <.link
            :if={@invite_status == :gone}
            id="space-invite-unavailable-link"
            navigate={@invite_destination}
            class="text-sm text-blue-500 hover:text-blue-700 transition-colors px-3 py-2"
          >
            {@invite_destination_label}
          </.link>
        </div>
      </section>
    </div>
    """
  end

  defp load_invite(current_user, invite_id) do
    with %Membership{} = membership <- Spaces.get_membership_invite(invite_id),
         true <- pending_invite?(membership),
         true <- matches_user?(membership, current_user) do
      {:ok, membership}
    else
      _ -> {:error, :not_found}
    end
  end

  defp pending_invite?(%Membership{invite: %{accepted_at: nil}}), do: true
  defp pending_invite?(_membership), do: false

  defp matches_user?(%Membership{invite: %{user_id: user_id}}, %{id: current_user_id})
       when is_binary(user_id) do
    user_id == current_user_id
  end

  defp matches_user?(%Membership{invite: %{email: email}}, %{email: current_email})
       when is_binary(email) and is_binary(current_email) do
    String.downcase(email) == String.downcase(current_email)
  end

  defp matches_user?(_membership, _user), do: false

  defp invite_email(%Membership{invite: %{email: email}}) when is_binary(email), do: email

  defp invite_email(%Membership{invite: %{user: %{email: email}}}) when is_binary(email),
    do: email

  defp invite_email(_membership), do: nil

  defp assign_unavailable_invite_destination(socket) do
    case socket.assigns.current_user do
      %{current_space_membership: %{space: %{}}} = user ->
        socket
        |> assign(:invite_destination, DashboardRoutes.signed_in_path(user))
        |> assign(:invite_destination_label, gettext("back to dashboard"))

      _user ->
        if connected?(socket) and is_binary(socket.assigns.user_token) do
          :ok = Accounts.delete_session_token(socket.assigns.user_token)
        end

        socket
        |> assign(:invite_destination, ~p"/login")
        |> assign(:invite_destination_label, gettext("back to login"))
    end
  end
end
