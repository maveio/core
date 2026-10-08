defmodule MaveCoreWeb.Plugs.RequireHost do
  @moduledoc false

  alias MaveCoreWeb.ErrorHTML
  alias Phoenix.HTML.Safe

  import Plug.Conn

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    hosts = allowed_hosts(opts)

    cond do
      hosts == [] ->
        conn

      conn.host in hosts ->
        conn

      true ->
        not_found(conn)
    end
  end

  defp not_found(conn) do
    if browser_request?(conn) do
      body =
        "404.html"
        |> ErrorHTML.render(%{})
        |> Safe.to_iodata()

      conn
      |> put_resp_content_type("text/html")
      |> send_resp(404, body)
      |> halt()
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(404, "Not found")
      |> halt()
    end
  end

  defp browser_request?(conn) do
    conn.private[:phoenix_format] == "html" ||
      Enum.any?(get_req_header(conn, "accept"), &String.contains?(&1, "text/html"))
  end

  defp allowed_hosts(opts) do
    # Supports either:
    # - hosts: ["api.staging.mave.io"]
    # - env_var: "MAVE_API_HOST" (string)
    # - env_var: "MAVE_API_HOSTS" (comma-separated)
    explicit_hosts = Keyword.get(opts, :hosts, []) |> normalize_hosts()

    env_hosts =
      case Keyword.get(opts, :env_var) do
        nil ->
          []

        var_name when is_binary(var_name) ->
          var_name
          |> System.get_env()
          |> parse_hosts_env()
      end

    (explicit_hosts ++ env_hosts)
    |> normalize_hosts()
    |> Enum.uniq()
  end

  defp parse_hosts_env(nil), do: []
  defp parse_hosts_env(""), do: []

  defp parse_hosts_env(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_hosts(hosts) when is_list(hosts) do
    hosts
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.downcase/1)
  end

  defp normalize_hosts(_), do: []
end
