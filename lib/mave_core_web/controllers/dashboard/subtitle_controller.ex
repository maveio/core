defmodule MaveCoreWeb.Dashboard.SubtitleController do
  @moduledoc false

  use MaveCoreWeb, :controller

  alias MaveCore.Accounts
  alias MaveCore.Assets
  alias MaveCore.Assets.Subtitle
  alias MaveCore.Assets.Video
  alias MaveCore.Embeds
  alias MaveCore.Embeds.Embed
  alias MaveCore.Media.Storage
  alias MaveCore.Spaces.Space

  def download(conn, %{"id" => embed_id, "subtitle_id" => subtitle_id} = params) do
    with {:ok, %Space{} = space} <- resolve_space(conn.assigns.current_user, params),
         {:ok, %Embed{} = embed} <- Embeds.resolve_dashboard_embed(space, embed_id),
         %Subtitle{} = subtitle <- Assets.get_subtitle(subtitle_id),
         true <- subtitle_for_current_video?(subtitle, embed),
         {:ok, body} <- fetch_subtitle_body(space, embed, subtitle) do
      conn
      |> put_resp_content_type("text/vtt")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_download(
        {:binary, body},
        filename: subtitle_filename(subtitle),
        disposition: :attachment
      )
    else
      _ ->
        conn
        |> put_status(:not_found)
        |> text("Subtitle not found")
    end
  end

  defp resolve_space(current_user, %{"space_id" => space_id}) when is_binary(space_id) do
    case Accounts.set_current_space_by_id(current_user, space_id) do
      {:ok, user} -> current_space(user)
      {:error, _reason} = error -> error
    end
  end

  defp resolve_space(current_user, _params) do
    case Accounts.ensure_default_space(current_user) do
      {:ok, user} -> current_space(user)
      {:error, _reason} = error -> error
    end
  end

  defp current_space(%{current_space_membership: %{space: %Space{} = space}}), do: {:ok, space}
  defp current_space(_user), do: {:error, :missing_space}

  defp subtitle_for_current_video?(
         %Subtitle{video_id: subtitle_video_id},
         %Embed{asset: %{current_video: %Video{id: subtitle_video_id}}}
       ),
       do: true

  defp subtitle_for_current_video?(_subtitle, _embed), do: false

  defp fetch_subtitle_body(%Space{} = space, %Embed{} = embed, %Subtitle{} = subtitle) do
    bucket = Storage.bucket_for_space(space.hash, space.region)
    storage = storage_adapter()

    Enum.find_value(subtitle_storage_keys(embed, subtitle), fn key ->
      case storage.get(bucket, key, space.region) do
        {:ok, body} -> {:ok, body}
        _ -> nil
      end
    end) || {:error, :not_found}
  end

  defp subtitle_storage_keys(%Embed{} = embed, %Subtitle{} = subtitle) do
    version = Embeds.current_video_version(embed)
    language = subtitle.language || "en"

    [
      local_subtitle_path(subtitle.path),
      versioned_subtitle_key(embed.hash, version, language),
      "#{embed.hash}/subtitle_#{language}.vtt"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp local_subtitle_path(path) when is_binary(path) and path != "" do
    if String.starts_with?(path, ["http://", "https://"]) do
      nil
    else
      String.trim_leading(path, "/")
    end
  end

  defp local_subtitle_path(_path), do: nil

  defp versioned_subtitle_key(embed_hash, version, language) when version > 0 do
    "#{embed_hash}/v#{version}/subtitle_#{language}.vtt"
  end

  defp versioned_subtitle_key(embed_hash, _version, language) do
    "#{embed_hash}/subtitle_#{language}.vtt"
  end

  defp subtitle_filename(%Subtitle{language: language}) when is_binary(language) do
    filename =
      language
      |> String.trim()
      |> String.replace(~r/[^A-Za-z0-9_-]/, "_")

    case filename do
      "" -> "subtitle.vtt"
      value -> "#{value}.vtt"
    end
  end

  defp subtitle_filename(_subtitle), do: "subtitle.vtt"

  defp storage_adapter do
    Application.get_env(:mave_core, :flow_storage_adapter, Storage)
  end
end
