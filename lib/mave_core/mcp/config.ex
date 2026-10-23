defmodule MaveCore.MCP.Config do
  @moduledoc false

  def resource_url do
    Keyword.get(config(), :resource_url) || api_origin() <> "/mcp"
  end

  def issuer, do: resource_url() |> URI.parse() |> Map.put(:path, nil) |> URI.to_string()
  def authorization_url, do: dashboard_origin() <> "/oauth/mcp/authorize"

  def allowed_origins,
    do: Enum.uniq([issuer(), dashboard_origin() | Keyword.get(config(), :allowed_origins, [])])

  def scopes, do: ["mave:read", "mave:write"]

  defp config, do: Application.get_env(:mave_core, :mcp, [])

  defp dashboard_origin do
    String.trim_trailing(
      Application.get_env(:mave_core, :domain) || MaveCoreWeb.Endpoint.url(),
      "/"
    )
  end

  defp api_origin do
    case System.get_env("MAVE_API_HOST") do
      value when is_binary(value) and value != "" ->
        host = value |> String.split(",") |> List.first() |> String.trim()
        scheme = URI.parse(dashboard_origin()).scheme
        "#{scheme}://#{host}"

      _ ->
        dashboard_origin()
    end
  end
end
