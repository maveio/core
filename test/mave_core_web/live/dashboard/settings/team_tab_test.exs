defmodule MaveCoreWeb.Dashboard.Settings.TeamTabTest do
  use MaveCore.DataCase, async: true

  alias MaveCore.{Accounts, Repo, Spaces}
  alias MaveCore.Spaces.{Membership, MembershipInvite}
  alias MaveCoreWeb.Dashboard.Settings.TeamTab
  alias Phoenix.LiveView.{Lifecycle, Socket}

  # A deployment's dashboard access provider can show this tab to an account
  # outside the team. Its hidden controls must not be reachable through events.
  test "accounts that cannot manage the team cannot add or remove members" do
    suffix = System.unique_integer([:positive])
    {:ok, owner} = Accounts.create_user("team-owner-#{suffix}@example.com")
    {:ok, member} = Accounts.create_user("team-member-#{suffix}@example.com")
    {:ok, outsider} = Accounts.create_user("team-outsider-#{suffix}@example.com")
    space = owner.current_space_membership.space
    {:ok, invite} = Spaces.create_membership_invite(space, owner, member.email)
    {:ok, membership} = Spaces.accept_membership_invite(invite, member)

    {:ok, socket} =
      TeamTab.update(
        %{id: "team-tab", current_space: space, current_user: outsider},
        %Socket{private: %{lifecycle: %Lifecycle{}}}
      )

    refute socket.assigns.can_manage_team

    assert {:noreply, _socket} =
             TeamTab.handle_event("remove_member", %{"id" => membership.id}, socket)

    assert Repo.get(Membership, membership.id)

    email = "team-invitee-#{suffix}@example.com"

    assert {:noreply, _socket} =
             TeamTab.handle_event("submit_add_member", %{"member" => %{"email" => email}}, socket)

    refute Repo.get_by(MembershipInvite, email: email)
  end
end
