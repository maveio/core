defmodule MaveCoreWeb.Auth.Index do
  @moduledoc false

  use MaveCoreWeb, :live_view
  import MaveCoreWeb.DashboardComponents

  alias MaveCore.{Accounts, GoogleOAuth}

  def mount(params, session, socket) do
    signup_country_options = signup_country_options()
    signup_policy = signup_policy()
    public_registration_enabled? = Accounts.public_registration_enabled?()

    path =
      case params["return_to"] do
        value when is_binary(value) and value != "" ->
          value

        _ ->
          session["user_return_to"] || "/videos"
      end
      |> safe_internal_path()

    form =
      if socket.assigns.live_action == :signup do
        signup_form(%{"email" => "", "terms" => false, "country" => ""})
      else
        to_form(%{"email" => ""}, as: "user")
      end

    socket =
      socket
      |> assign(:message, nil)
      |> assign(:path, path)
      |> assign(:form, form)
      |> assign(:signup_country_options, signup_country_options)
      |> assign(:signup_policy, signup_policy)
      |> assign(:public_registration_enabled, public_registration_enabled?)
      |> assign(:google_oauth_enabled, GoogleOAuth.enabled?())
      |> assign(:request_base_url, nil)
      |> assign(:local_mailbox?, local_mailbox?(socket))

    if socket.assigns.live_action == :signup and not public_registration_enabled? do
      {:ok, redirect(socket, to: ~p"/login")}
    else
      {:ok, socket}
    end
  end

  def handle_params(%{"error" => "no_match"}, uri, socket) do
    socket = assign_request_base_url(socket, uri)

    {:noreply,
     assign(
       socket,
       :message,
       "This Google account could not be linked automatically. Please continue with your email magic link."
     )}
  end

  def handle_params(%{"error" => "email"}, uri, socket) do
    socket = assign_request_base_url(socket, uri)

    {:noreply,
     assign(
       socket,
       :message,
       "We could not verify your Google email. Please try another account or use your email magic link."
     )}
  end

  def handle_params(%{"error" => "link"}, uri, socket) do
    socket = assign_request_base_url(socket, uri)

    {:noreply,
     put_flash(
       socket,
       :error,
       "This login link is invalid or has expired. Enter your email to request a new link."
     )}
  end

  def handle_params(%{"error" => _error}, uri, socket) do
    socket = assign_request_base_url(socket, uri)
    {:noreply, assign(socket, :message, "Something went wrong. Please try again.")}
  end

  def handle_params(_params, uri, socket), do: {:noreply, assign_request_base_url(socket, uri)}

  def handle_event("login", %{"user" => user_params}, socket) do
    changeset =
      Accounts.change_login_user(user_params)
      |> Map.put(:action, :validate)

    email = Ecto.Changeset.get_field(changeset, :email)

    if changeset.valid? do
      maybe_send_login_link(email, socket.assigns.path, socket.assigns.request_base_url)

      message =
        "If #{email} is in our system, you'll receive a magic link shortly. " <>
          "Please check that the email address is correct."

      {:noreply, socket |> assign(:message, message)}
    else
      {:noreply, socket |> assign(:form, to_form(changeset, as: "user"))}
    end
  end

  def handle_event("signup", %{"signup" => signup_params}, socket) do
    email = signup_params["email"] |> to_string() |> String.trim()
    terms_accepted? = signup_params["terms"] in ["true", "1", "on", true]
    country = signup_params["country"] |> to_string() |> String.trim()

    changeset =
      Accounts.change_registration_user(%{"email" => email})
      |> Map.put(:action, :validate)

    case signup_errors(
           changeset,
           terms_accepted?,
           country,
           socket.assigns.signup_country_options,
           socket.assigns.signup_policy
         ) do
      [] ->
        case maybe_send_signup_link(email, socket.assigns.path, socket.assigns.request_base_url) do
          :ok ->
            message =
              "Thank you for signing up. Check your email for a magic link to get started."

            {:noreply, socket |> assign(:message, message)}

          {:error, errors} ->
            {:noreply, socket |> assign(:form, signup_form(signup_params, errors))}
        end

      errors ->
        {:noreply, socket |> assign(:form, signup_form(signup_params, errors))}
    end
  end

  defp local_mailbox?(socket) do
    socket.endpoint == MaveCoreWeb.Endpoint and
      MaveCore.Installation.enabled?() and
      Application.get_env(:mave_core, :dev_routes, false) and
      Application.get_env(:mave_core, MaveCore.Mailer, [])[:adapter] == Swoosh.Adapters.Local
  end

  defp signup_form(params, errors \\ []) do
    to_form(
      %{
        "email" => Map.get(params, "email", ""),
        "terms" => Map.get(params, "terms", false),
        "country" => Map.get(params, "country", "")
      },
      as: "signup",
      action: :validate,
      errors: errors
    )
  end

  defp maybe_send_login_link(email, path, request_base_url) do
    with %{} = user <- Accounts.get_user_by_email(email),
         true <- Accounts.can_create_new_login_token(email) do
      Accounts.deliver_user_login_instructions(
        user,
        &build_login_link(path, &1, request_base_url)
      )
    else
      _ -> :ok
    end
  end

  defp signup_errors(changeset, terms_accepted?, country, country_options, policy) do
    terms_valid? = terms_accepted? or not policy.terms_required

    changeset
    |> email_errors(terms_valid?)
    |> maybe_put_terms_error(terms_valid?)
    |> maybe_put_country_error(country, country_options, policy)
  end

  defp email_errors(changeset, true) do
    if changeset.valid? or existing_user_error?(changeset), do: [], else: changeset.errors
  end

  defp email_errors(changeset, _terms_accepted?), do: changeset.errors

  defp maybe_put_terms_error(errors, true), do: errors

  defp maybe_put_terms_error(errors, _terms_accepted?) do
    Keyword.put_new(
      errors,
      :terms,
      {"Please accept the terms and conditions", []}
    )
  end

  defp maybe_put_country_error(errors, _country, [], _policy), do: errors

  defp maybe_put_country_error(errors, country, country_options, policy) do
    case country_error(country, country_options, policy) do
      nil -> errors
      error -> Keyword.put_new(errors, :country, error)
    end
  end

  defp country_error("", _country_options, policy), do: {policy.choose_country_message, []}

  defp country_error(country, country_options, policy) do
    allowed_country_codes = Enum.map(country_options, fn {_label, value} -> value end)

    if country in allowed_country_codes do
      nil
    else
      {policy.unsupported_country_message, []}
    end
  end

  defp signup_policy do
    config = Application.get_env(:mave_core, :signup_policy, [])

    %{
      terms_required: config_value(config, :terms_required, false) == true,
      terms_url: config_url(config, :terms_url),
      privacy_url: config_url(config, :privacy_url),
      product_name: config_string(config, :product_name, "Mave Core"),
      country_description: config_string(config, :country_description),
      choose_country_message:
        config_string(config, :choose_country_message, "Select your location"),
      unsupported_country_message:
        config_string(config, :unsupported_country_message, "This location is not supported.")
    }
  end

  defp config_url(config, key) do
    case config_string(config, key) do
      value when is_binary(value) ->
        case URI.parse(value) do
          %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
            value

          _uri ->
            nil
        end

      _value ->
        nil
    end
  end

  defp config_string(config, key, default \\ nil) do
    case config_value(config, key, default) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> default
          normalized -> normalized
        end

      _value ->
        default
    end
  end

  defp config_value(config, key, default) when is_list(config),
    do: Keyword.get(config, key, default)

  defp config_value(config, key, default) when is_map(config),
    do: Map.get(config, key, Map.get(config, Atom.to_string(key), default))

  defp config_value(_config, _key, default), do: default

  defp signup_country_options do
    :mave_core
    |> Application.get_env(:signup_country_options, [])
    |> Enum.filter(fn
      {label, value} when is_binary(label) and is_binary(value) -> true
      _other -> false
    end)
  end

  defp existing_user_error?(%Ecto.Changeset{errors: [email: {_message, opts}]}) do
    Keyword.get(opts, :validation) == :unsafe_unique
  end

  defp existing_user_error?(_changeset), do: false

  defp maybe_send_signup_link(email, path, request_base_url) do
    case Accounts.get_user_by_email(email) do
      nil ->
        register_public_user(email, path, request_base_url)

      user ->
        maybe_send_existing_user_link(user, path, request_base_url)
    end
  end

  defp register_public_user(email, path, request_base_url) do
    Accounts.register_public_user(
      email,
      &build_login_link(path, &1, request_base_url)
    )
    |> case do
      {:ok, _user} ->
        :ok

      {:error, :already_registered} ->
        email
        |> Accounts.get_user_by_email()
        |> maybe_send_existing_user_link(path, request_base_url)

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset.errors}

      {:error, _reason} ->
        signup_delivery_error()
    end
  end

  defp maybe_send_existing_user_link(nil, _path, _request_base_url), do: :ok

  defp maybe_send_existing_user_link(user, path, request_base_url) do
    if Accounts.can_create_new_login_token(user.email) do
      user
      |> Accounts.deliver_user_login_instructions(&build_login_link(path, &1, request_base_url))
      |> normalize_signup_delivery_result()
    else
      :ok
    end
  end

  defp normalize_signup_delivery_result({:ok, _metadata}), do: :ok
  defp normalize_signup_delivery_result({:error, _reason}), do: signup_delivery_error()

  defp signup_delivery_error,
    do: {:error, email: {"Could not send a login link. Please try again later.", []}}

  defp build_login_link(path, token, request_base_url) do
    uri = URI.parse(path)
    params = URI.decode_query(uri.query || "") |> Map.put("token", token)
    relative = %{uri | query: URI.encode_query(params)} |> URI.to_string()

    case request_base_url do
      base when is_binary(base) and base != "" ->
        URI.merge(base, relative) |> URI.to_string()

      _ ->
        relative
    end
  end

  defp safe_internal_path(path) when is_binary(path) do
    path = String.trim(path)
    uri = URI.parse(path)

    cond do
      path == "" -> "/videos"
      uri.scheme || uri.host -> "/videos"
      String.starts_with?(path, "/") -> path
      true -> "/videos"
    end
  end

  defp safe_internal_path(_), do: "/videos"

  defp assign_request_base_url(socket, uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: scheme, host: host} = parsed
      when is_binary(scheme) and scheme != "" and is_binary(host) and host != "" ->
        assign(socket, :request_base_url, "#{scheme}://#{host}#{port_suffix(parsed)}")

      _ ->
        socket
    end
  end

  defp assign_request_base_url(socket, _), do: socket

  defp port_suffix(%URI{port: nil}), do: ""
  defp port_suffix(%URI{scheme: "http", port: 80}), do: ""
  defp port_suffix(%URI{scheme: "https", port: 443}), do: ""
  defp port_suffix(%URI{port: port}), do: ":#{port}"
end
