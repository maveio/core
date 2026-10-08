defmodule MaveCoreWeb.UserAuth do
  @moduledoc false

  import Phoenix.Controller
  import Plug.Conn

  alias MaveCore.Accounts
  alias MaveCore.Spaces
  alias MaveCore.Spaces.Membership
  alias MaveCoreWeb.DashboardRoutes

  @max_age 60 * 60 * 24 * 60
  @remember_me_cookie "_mave_core_cookie"
  # The cookie alone signs a browser in, so keep it off cross-site requests in
  # every browser rather than relying on each browser's SameSite default.
  @remember_me_options [max_age: @max_age, sign: true, same_site: "Lax"]
  @legacy_remember_me_cookie "_mave_cookie"
  @logged_in_marker_cookie "_mave_a"

  def log_in_user(conn, login_token, user, _params \\ %{}) do
    token = Accounts.generate_user_session_token(login_token, user)
    user_return_to = sanitize_return_to(get_session(conn, :user_return_to))

    conn
    |> renew_session()
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, "users_sessions:#{Base.url_encode64(token)}")
    |> put_resp_cookie(@remember_me_cookie, token, @remember_me_options)
    |> put_logged_in_marker_cookie()
    |> redirect(to: user_return_to || signed_in_path(conn, user))
  end

  def log_out_user(conn) do
    user_token = get_session(conn, :user_token) || cookie_user_token(conn)
    user_token && Accounts.delete_session_token(user_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      MaveCoreWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session()
    |> delete_resp_cookie(@remember_me_cookie, @remember_me_options)
    |> delete_resp_cookie(@legacy_remember_me_cookie)
    |> delete_logged_in_marker_cookie()
    |> redirect(to: "/login")
  end

  def fetch_current_user(
        %{method: "GET", params: %{"token" => token}} = conn,
        _opts
      )
      when is_binary(token) and byte_size(token) <= 128 do
    with nil <- stale_invite_redirect_path(conn.params),
         {:ok, {user, login_token}} <- Accounts.login_user(token, ["login", "invite"]),
         true <- valid_token_login?(login_token, user, conn.params) do
      log_in_token_user(conn, user, login_token)
    else
      path when is_binary(path) ->
        conn
        |> redirect(to: path)
        |> halt()

      _other ->
        reject_token_login(conn)
    end
  end

  def fetch_current_user(%{params: %{"token" => _token}} = conn, _opts) do
    reject_token_login(conn)
  end

  def fetch_current_user(conn, _opts) do
    fetch_current_user_from_session(conn, [])
  end

  defp reject_token_login(conn) do
    conn
    |> redirect(to: "/login?error=link")
    |> halt()
  end

  def fetch_current_user_from_session(conn, _opts) do
    {user_token, conn} = ensure_user_token(conn)
    user = user_token && Accounts.get_user_by_session_token(user_token)
    assign(conn, :current_user, user)
  end

  def redirect_if_user_is_authenticated(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
      |> redirect(to: signed_in_path(conn))
      |> halt()
    else
      conn
    end
  end

  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_flash(:error, "Please log in to access this page.")
      |> maybe_store_return_to()
      |> redirect(to: "/login")
      |> halt()
    end
  end

  defp ensure_user_token(conn) do
    if user_token = get_session(conn, :user_token) do
      {user_token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_me_cookie])

      if user_token = conn.cookies[@remember_me_cookie] do
        {user_token, put_session(conn, :user_token, user_token)}
      else
        {nil, conn}
      end
    end
  end

  defp renew_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn

  defp log_in_token_user(conn, user, login_token) do
    user = maybe_set_space_from_param(user, conn.params["space"])
    query_params = Map.delete(conn.query_params || %{}, "token")
    query_string = URI.encode_query(query_params)

    conn
    |> Map.merge(%{
      query_string: query_string,
      query_params: query_params,
      params: Map.delete(conn.params, "token")
    })
    |> assign(:current_user, user)
    |> maybe_store_return_to()
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> log_in_user(login_token, user)
    |> halt()
  end

  defp cookie_user_token(conn) do
    conn
    |> fetch_cookies(signed: [@remember_me_cookie])
    |> then(& &1.cookies[@remember_me_cookie])
  end

  defp put_logged_in_marker_cookie(conn) do
    case logged_in_marker_cookie_options() do
      nil -> conn
      options -> put_resp_cookie(conn, @logged_in_marker_cookie, "true", options)
    end
  end

  defp delete_logged_in_marker_cookie(conn) do
    case logged_in_marker_cookie_options() do
      nil -> delete_resp_cookie(conn, @logged_in_marker_cookie)
      options -> delete_resp_cookie(conn, @logged_in_marker_cookie, options)
    end
  end

  defp logged_in_marker_cookie_options do
    config = Application.get_env(:mave_core, :logged_in_marker_cookie, []) || []

    if Keyword.get(config, :enabled, false) do
      [
        max_age: Keyword.get(config, :max_age, @max_age),
        http_only: false,
        same_site: Keyword.get(config, :same_site, "Lax"),
        secure: Keyword.get(config, :secure, true),
        sign: false
      ]
      |> maybe_put_cookie_option(:domain, Keyword.get(config, :domain))
    end
  end

  defp maybe_put_cookie_option(options, _key, nil), do: options
  defp maybe_put_cookie_option(options, _key, ""), do: options
  defp maybe_put_cookie_option(options, key, value), do: Keyword.put(options, key, value)

  defp sanitize_return_to(nil), do: nil

  defp sanitize_return_to(path) when is_binary(path) do
    path = String.trim(path)
    downcased = String.downcase(path)
    uri = URI.parse(path)

    cond do
      path == "" ->
        nil

      uri.scheme || uri.host ->
        nil

      not String.starts_with?(path, "/") ->
        nil

      String.starts_with?(downcased, "/login") ->
        nil

      String.starts_with?(downcased, "/signup") ->
        nil

      true ->
        path
    end
  end

  defp signed_in_path(conn, fallback_user \\ nil) do
    case conn.assigns[:current_user] || fallback_user do
      %{} = user -> DashboardRoutes.signed_in_path(user)
      _ -> "/videos"
    end
  end

  defp maybe_set_space_from_param(user, space_hash)
       when is_binary(space_hash) and space_hash != "" do
    case Accounts.set_current_space_by_hash(user, space_hash) do
      {:ok, updated_user} -> updated_user
      _ -> user
    end
  end

  defp maybe_set_space_from_param(user, _), do: user

  defp stale_invite_redirect_path(%{"invite" => invite_id}) when is_binary(invite_id) do
    case Spaces.get_membership_invite(invite_id) do
      %Membership{} = membership ->
        if pending_invite?(membership) do
          nil
        else
          stale_invite_path(invite_id)
        end

      nil ->
        stale_invite_path(invite_id)
    end
  end

  defp stale_invite_redirect_path(_params), do: nil

  defp stale_invite_path(invite_id) do
    "/space?" <> URI.encode_query(%{"invite" => invite_id, "stale" => "1"})
  end

  defp valid_token_login?(%{context: "invite"}, user, %{"invite" => invite_id})
       when is_binary(invite_id) do
    case Spaces.get_membership_invite(invite_id) do
      %Membership{} = membership ->
        pending_invite?(membership) and matches_invite_user?(membership, user)

      nil ->
        false
    end
  end

  defp valid_token_login?(%{context: "invite"}, _user, _params), do: false
  defp valid_token_login?(_login_token, _user, _params), do: true

  defp pending_invite?(%Membership{invite: %{accepted_at: nil}}), do: true
  defp pending_invite?(_membership), do: false

  defp matches_invite_user?(%Membership{invite: %{user_id: user_id}}, %{id: current_user_id})
       when is_binary(user_id) do
    user_id == current_user_id
  end

  defp matches_invite_user?(%Membership{invite: %{email: email}}, %{email: current_email})
       when is_binary(email) and is_binary(current_email) do
    String.downcase(email) == String.downcase(current_email)
  end

  defp matches_invite_user?(_membership, _user), do: false
end
