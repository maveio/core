defmodule MaveCoreWeb.Dashboard.Videos.ListUploadTest do
  use MaveCore.DataCase, async: true

  alias MaveCore.{Accounts, Embeds, Spaces}
  alias MaveCore.Embeds.SettingsSerializer
  alias MaveCoreWeb.Dashboard.Videos.ListUpload
  alias MaveCoreWeb.DashboardRoutes

  test "the upload credential is scoped to the newly created video and links preserve space routing" do
    {:ok, user} =
      Accounts.create_user("drop-upload-#{System.unique_integer([:positive])}@example.com")

    login_token = Accounts.generate_user_login_token(user)
    {:ok, {user, _token}} = Accounts.login_user(login_token)
    space = user.current_space_membership.space

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        current_space: space,
        current_user: user,
        current_tab: :all,
        route_scope: :scoped
      }
    }

    assert {:ok, upload} =
             ListUpload.prepare(socket, %{
               "name" => "My video.mp4",
               "size" => 1024,
               "file_count" => 1
             })

    assert %{videos: [%{uuid: id}]} = Embeds.list_root_items(space)
    {:ok, embed} = Embeds.resolve_dashboard_embed(space, id)
    assert {:ok, %{claims: claims, key: key}} = Spaces.validate_api_jwt(upload.token, false)
    assert claims["sub"] == SettingsSerializer.public_embed_id(space, embed)
    assert key.purpose == :dashboard_uploads

    assert upload.href ==
             DashboardRoutes.video_path(space, Embeds.dashboard_embed_id(embed), :all,
               scope: :scoped
             )
  end
end
