defmodule MaveCoreWeb.Dashboard.Videos.ListUpload do
  @moduledoc false

  use Gettext, backend: MaveCoreWeb.Gettext

  alias MaveCore.Embeds
  alias MaveCore.Embeds.{Embed, SettingsSerializer}
  alias MaveCore.Spaces
  alias MaveCore.Uploads.Token
  alias MaveCore.UsageLimits
  alias MaveCoreWeb.DashboardRoutes
  alias MaveCoreWeb.Plugs.Maintenance

  def prepare(socket, params, default_folder_id \\ nil) do
    space = socket.assigns.current_space

    with {:ok, name, size} <- file_details(params),
         {:ok, folder} <- folder(space, Map.get(params, "folder_id", default_folder_id)),
         :ok <- UsageLimits.can_upload_file?(space, size),
         {:ok, key} <- Spaces.ensure_internal_key(space, :dashboard_uploads),
         {:ok, embed} <-
           Embeds.create_video_embed(space, %{
             name: name,
             parent_folder_id: folder && folder.id,
             archived:
               if(folder, do: folder.archived, else: socket.assigns.current_tab == :archive)
           }) do
      {:ok,
       %{
         token:
           Token.sign_api_key(key, SettingsSerializer.public_embed_id(space, embed),
             admin_maintenance_bypass: Maintenance.internal_user?(socket.assigns.current_user)
           ),
         href:
           DashboardRoutes.video_path(
             space,
             Embeds.dashboard_embed_id(embed),
             socket.assigns.current_tab,
             scope: socket.assigns.route_scope
           )
       }}
    else
      {:error, reason} -> {:error, error_message(reason)}
    end
  end

  defp file_details(%{"name" => name, "size" => size, "file_count" => 1})
       when is_binary(name) and byte_size(name) in 1..1024 and is_integer(size) and size > 0 do
    name =
      name |> String.replace("\\", "/") |> Path.basename() |> Path.rootname() |> String.trim()

    if name == "", do: {:error, :invalid_file}, else: {:ok, name, size}
  end

  defp file_details(_params), do: {:error, :invalid_file}

  defp folder(_space, id) when id in [nil, ""], do: {:ok, nil}

  defp folder(space, id) when is_binary(id) do
    case Embeds.resolve_dashboard_embed(space, id) do
      {:ok, %Embed{type: :collection} = folder} -> {:ok, folder}
      _ -> {:error, :invalid_folder}
    end
  end

  defp folder(_space, _id), do: {:error, :invalid_folder}

  defp error_message(:invalid_file),
    do: gettext("Choose a non-empty video or audio file.")

  defp error_message(:invalid_folder), do: gettext("This folder is no longer available.")

  defp error_message(:upload_file_size_limit_exceeded),
    do: gettext("This file exceeds the upload size limit.")

  defp error_message(reason) do
    copy =
      Map.merge(
        UsageLimits.restriction_copy(:create_video, reason),
        UsageLimits.restriction_copy(:upload_file, reason)
      )

    Map.get(copy, :error, gettext("Could not start the upload. Please try again."))
  end
end
