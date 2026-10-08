defmodule MaveCoreWeb.OAuthController do
  use MaveCoreWeb, :controller

  alias MaveCore.{Accounts, GoogleOAuth}
  alias MaveCoreWeb.DashboardRoutes
  alias MaveCoreWeb.UserAuth

  plug :ensure_google_oauth_enabled when action in [:request, :callback]
  plug Ueberauth

  def request(conn, _params) do
    redirect(conn, to: ~p"/login?error=failed")
  end

  def callback(
        %{
          assigns: %{
            current_user: %{google_uid: nil} = current_user,
            ueberauth_auth: %{provider: :google} = auth
          }
        } = conn,
        %{"provider" => "google"}
      ) do
    case validate_google_identity(auth) do
      {:ok, email, uid} ->
        current_user
        |> Accounts.link_google_account(%{uid: uid, email: email})
        |> handle_google_link_result(conn, current_user)

      {:error, :invalid_email} ->
        redirect_settings_error(conn, current_user, "Please use a verified Google account.")

      {:error, :invalid_uid} ->
        redirect_settings_error(conn, current_user, "We couldn't connect your Google account.")
    end
  end

  def callback(
        %{assigns: %{ueberauth_auth: %{provider: :google} = auth}} = conn,
        %{"provider" => "google"}
      ) do
    case validate_google_identity(auth) do
      {:ok, email, uid} ->
        %{uid: uid, email: email, email_verified: true}
        |> Accounts.login_or_register_with_google()
        |> handle_google_login_result(conn)

      {:error, :invalid_email} ->
        redirect(conn, to: ~p"/login?error=email")

      {:error, :invalid_uid} ->
        redirect(conn, to: ~p"/login?error=failed")
    end
  end

  def callback(conn, _params) do
    redirect(conn, to: ~p"/login?error=failed")
  end

  defp sign_in_google_user(conn, user) do
    login_token = Accounts.generate_user_login_token(user)

    case Accounts.login_user(login_token) do
      {:ok, {logged_in_user, persisted_login_token}} ->
        UserAuth.log_in_user(conn, persisted_login_token, logged_in_user)

      {:error, _reason} ->
        redirect(conn, to: ~p"/login?error=failed")
    end
  end

  defp validate_google_identity(auth) do
    email = auth_email(auth)
    uid = auth_uid(auth)

    cond do
      not google_email_verified?(auth) -> {:error, :invalid_email}
      is_nil(email) or email == "" -> {:error, :invalid_email}
      is_nil(uid) or uid == "" -> {:error, :invalid_uid}
      true -> {:ok, email, uid}
    end
  end

  defp handle_google_link_result({:ok, _user}, conn, current_user) do
    redirect_settings_info(conn, current_user, "Google account connected.")
  end

  defp handle_google_link_result({:error, :google_uid_taken}, conn, current_user) do
    redirect_settings_error(
      conn,
      current_user,
      "This Google account is already connected to another user."
    )
  end

  defp handle_google_link_result({:error, :google_email_mismatch}, conn, current_user) do
    redirect_settings_error(
      conn,
      current_user,
      "Please connect a Google account with the same email address."
    )
  end

  defp handle_google_link_result({:error, :google_link_expired}, conn, current_user) do
    redirect_settings_error(conn, current_user, "Google connection expired. Please try again.")
  end

  defp handle_google_link_result({:error, :google_link_not_pending}, conn, current_user) do
    redirect_settings_error(
      conn,
      current_user,
      "Please start the Google connection from settings."
    )
  end

  defp handle_google_link_result({:error, _reason}, conn, current_user) do
    redirect_settings_error(conn, current_user, "We couldn't connect your Google account.")
  end

  defp handle_google_login_result({:ok, user}, conn), do: sign_in_google_user(conn, user)

  defp handle_google_login_result({:error, :no_match}, conn),
    do: redirect(conn, to: ~p"/login?error=no_match")

  defp handle_google_login_result({:error, :email_unverified}, conn),
    do: redirect(conn, to: ~p"/login?error=email")

  defp handle_google_login_result({:error, _reason}, conn),
    do: redirect(conn, to: ~p"/login?error=failed")

  defp redirect_settings_info(conn, current_user, message) do
    conn
    |> put_flash(:info, message)
    |> redirect(to: DashboardRoutes.settings_path(current_user))
  end

  defp redirect_settings_error(conn, current_user, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: DashboardRoutes.settings_path(current_user))
  end

  defp ensure_google_oauth_enabled(conn, _opts) do
    if GoogleOAuth.enabled?() do
      conn
    else
      conn
      |> send_resp(:not_found, "Not found")
      |> halt()
    end
  end

  defp auth_email(%{info: %{email: email}}) when is_binary(email), do: String.trim(email)
  defp auth_email(_), do: nil

  defp auth_uid(%{uid: uid}) when is_binary(uid), do: String.trim(uid)
  defp auth_uid(_), do: nil

  defp google_email_verified?(%{extra: %{raw_info: %{user: %{"email_verified" => value}}}})
       when value in [true, "true", 1, "1"],
       do: true

  defp google_email_verified?(_), do: false
end
