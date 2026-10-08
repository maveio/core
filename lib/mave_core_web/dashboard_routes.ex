defmodule MaveCoreWeb.DashboardRoutes do
  @moduledoc false

  alias MaveCore.Spaces.Space

  def videos_path(space_or_user, tab \\ :all, opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    params = build_params(tab, page)
    path_for(space_or_user, "/videos", params, opts)
  end

  def video_path(space_or_user, id, tab \\ :all, opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    params = build_params(tab, page)
    path_for(space_or_user, "/videos/#{id}", params, opts)
  end

  def subtitle_download_path(space_or_user, video_id, subtitle_id, opts \\ []) do
    path_for(space_or_user, "/videos/#{video_id}/subtitles/#{subtitle_id}/download", [], opts)
  end

  def data_path(space_or_user, opts \\ []) do
    path_for(space_or_user, "/data", [], opts)
  end

  def settings_path(space_or_user, tab \\ nil, opts \\ []) do
    suffix =
      case tab do
        nil -> ""
        :general -> ""
        value when is_binary(value) -> "/#{value}"
        value -> "/#{value}"
      end

    path_for(space_or_user, "/settings#{suffix}", [], opts)
  end

  def signed_in_path(space_or_user) do
    videos_path(space_or_user)
  end

  def space_shortuuid(%Space{id: id}), do: id
  def space_shortuuid(%{id: id}) when is_binary(id), do: id

  def space_shortuuid(%{current_space_membership: %{space: %Space{} = space}}),
    do: space_shortuuid(space)

  def space_shortuuid(%{current_space_membership: %{space_id: id}}) when is_binary(id),
    do: id

  defp build_params(tab, page) do
    []
    |> maybe_put_param(:tab, tab == :archive, "archive")
    |> maybe_put_param(:page, page > 1, page)
  end

  defp maybe_put_param(params, _key, false, _value), do: params
  defp maybe_put_param(params, key, true, value), do: Keyword.put(params, key, value)

  defp path_for(space_or_user, suffix, params, opts) do
    case Keyword.get(opts, :scope, :scoped) do
      :unscoped -> unscoped_path(suffix, params)
      _ -> scoped_path(space_or_user, suffix, params)
    end
  end

  defp scoped_path(space_or_user, suffix, params) do
    base = "/#{space_shortuuid(space_or_user)}#{suffix}"

    case URI.encode_query(params) do
      "" -> base
      query -> base <> "?" <> query
    end
  end

  defp unscoped_path(suffix, params) do
    case URI.encode_query(params) do
      "" -> suffix
      query -> suffix <> "?" <> query
    end
  end
end
