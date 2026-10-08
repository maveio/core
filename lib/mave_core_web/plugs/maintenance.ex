defmodule MaveCoreWeb.Plugs.Maintenance do
  @moduledoc """
  Blocks write-capable web surfaces while the app is in maintenance mode.

  Maintenance can be enabled with `MAVE_MAINTENANCE=1` or by setting
  `MAVE_MAINTENANCE_FILE` to a file that exists on disk.
  """

  import Plug.Conn

  @behaviour Plug

  @truthy_values ~w(1 true TRUE yes YES on ON)
  @default_status_message "Temporarily unavailable"
  @default_detail "This service is temporarily unavailable while maintenance is in progress."

  @impl Plug
  def init(opts) do
    opts
    |> Keyword.put_new(:otp_app, :mave_core)
    |> Keyword.put_new(:allowed_paths, [])
    |> Keyword.put_new(:allowed_path_prefixes, [])
    |> Keyword.put_new(:allowed_hosts, [])
    |> Keyword.put_new(:allowed_host_env_vars, [])
    |> Keyword.put_new(:allow_internal_users, false)
  end

  @impl Plug
  def call(conn, opts) do
    if enabled?(opts) and not allowed_request?(conn, opts) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("retry-after", "300")
      |> send_maintenance_response()
      |> halt()
    else
      conn
    end
  end

  def enabled?(opts \\ []) do
    otp_app = Keyword.get(opts, :otp_app, :mave_core)

    app_config_enabled?(otp_app) or env_enabled?() or file_enabled?()
  end

  defp app_config_enabled?(otp_app) do
    Application.get_env(otp_app, :maintenance_mode, false) in [true, "1", "true", "TRUE"]
  end

  defp env_enabled? do
    System.get_env("MAVE_MAINTENANCE") in @truthy_values
  end

  defp file_enabled? do
    case System.get_env("MAVE_MAINTENANCE_FILE") do
      nil -> false
      "" -> false
      path -> File.exists?(path)
    end
  end

  defp allowed_path?(%{request_path: request_path}, opts) do
    request_path in Keyword.get(opts, :allowed_paths, [])
  end

  defp allowed_request?(conn, opts) do
    allowed_path?(conn, opts) or allowed_path_prefix?(conn, opts) or allowed_host?(conn, opts) or
      allowed_internal_user?(conn, opts)
  end

  defp allowed_path_prefix?(%{request_path: request_path}, opts) do
    Enum.any?(
      Keyword.get(opts, :allowed_path_prefixes, []),
      &String.starts_with?(request_path, &1)
    )
  end

  defp allowed_host?(%{host: host}, opts) when is_binary(host) do
    host = String.downcase(host)

    opts
    |> allowed_hosts()
    |> Enum.member?(host)
  end

  defp allowed_host?(_conn, _opts), do: false

  defp allowed_hosts(opts) do
    explicit_hosts = Keyword.get(opts, :allowed_hosts, []) |> normalize_hosts()

    env_hosts =
      opts
      |> Keyword.get(:allowed_host_env_vars, [])
      |> List.wrap()
      |> Enum.flat_map(&hosts_from_env/1)

    (explicit_hosts ++ env_hosts)
    |> normalize_hosts()
    |> Enum.uniq()
  end

  defp hosts_from_env(env_var) when is_binary(env_var) do
    env_var
    |> System.get_env()
    |> parse_hosts_env()
  end

  defp hosts_from_env(_env_var), do: []

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

  defp normalize_hosts(_hosts), do: []

  def allowed_internal_user?(%{assigns: %{current_user: current_user}}, opts) do
    Keyword.get(opts, :allow_internal_users, false) and internal_user?(current_user)
  end

  def allowed_internal_user?(_conn, _opts), do: false

  def internal_user?(%{email: email}) when is_binary(email) do
    email = normalize_email(email)
    configured_admin_email?(email)
  end

  def internal_user?(_user), do: false

  defp configured_admin_email?(email) do
    email in configured_admin_emails() or email_domain(email) in configured_admin_domains()
  end

  defp configured_admin_emails do
    :mave_core
    |> Application.get_env(:flow_admin, [])
    |> Keyword.get(:emails, [])
    |> normalize_email_list()
  end

  defp configured_admin_domains do
    :mave_core
    |> Application.get_env(:flow_admin, [])
    |> Keyword.get(:email_domains, [])
    |> normalize_email_list()
  end

  defp normalize_email_list(values) when is_list(values) do
    values
    |> Enum.map(&normalize_email/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_email_list(_values), do: []

  defp normalize_email(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_email(_value), do: ""

  defp email_domain(email) do
    email
    |> String.split("@", parts: 2)
    |> case do
      [_local, domain] -> domain
      _ -> ""
    end
  end

  defp send_maintenance_response(conn) do
    if wants_html?(conn) do
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(503, html_body())
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(503, json_body())
    end
  end

  defp wants_html?(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.any?(&String.contains?(&1, "text/html"))
  end

  defp json_body do
    Phoenix.json_library().encode!(%{
      error: "maintenance",
      message: @default_status_message,
      detail: @default_detail
    })
  end

  defp html_body do
    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>#{@default_status_message}</title>
        <style>
          :root {
            color-scheme: light;
            font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            background: #f7f5f0;
            color: #20201d;
          }

          * { box-sizing: border-box; }

          body {
            margin: 0;
            min-height: 100vh;
            display: grid;
            place-items: center;
            padding: 32px;
          }

          main {
            width: min(100%, 560px);
          }

          .brand {
            margin-bottom: 36px;
            font-size: 14px;
            font-weight: 700;
            letter-spacing: 0;
            color: #5f5c53;
          }

          h1 {
            margin: 0;
            font-size: clamp(36px, 7vw, 64px);
            line-height: 1;
            letter-spacing: 0;
            font-weight: 720;
          }

          p {
            margin: 22px 0 0;
            max-width: 440px;
            color: #5f5c53;
            font-size: 18px;
            line-height: 1.55;
          }

          .status {
            margin-top: 36px;
            display: inline-flex;
            align-items: center;
            gap: 10px;
            color: #3f7665;
            font-size: 14px;
            font-weight: 650;
          }

          .status::before {
            content: "";
            width: 9px;
            height: 9px;
            border-radius: 999px;
            background: #3f7665;
          }
        </style>
      </head>
      <body>
        <main>
          <div class="brand">mave</div>
          <h1>#{@default_status_message}</h1>
          <p>#{@default_detail}</p>
          <div class="status">Please check back soon</div>
        </main>
      </body>
    </html>
    """
  end
end
