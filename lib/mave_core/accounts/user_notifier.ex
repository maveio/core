defmodule MaveCore.Accounts.UserNotifier do
  @moduledoc false

  import Swoosh.Email
  require Logger

  alias MaveCore.Accounts.User
  alias MaveCore.{Mailer, Spaces}

  @default_from_address {"Mave Core", "noreply@localhost"}

  def deliver_signup_instructions(user, url) do
    signup_url = resolve_url(url)

    deliver(
      user.email,
      "#{product_name()} signup verification",
      """
      To get started with #{product_name()} and verify your email, please use the following link: #{signup_url}

      Thanks for trying out #{product_name()}!

      - #{signature()}
      """,
      """
      <td
      style="box-sizing: border-box; font-family: 'Helvetica Neue' , Helvetica, Arial, 'Lucida Grande' , sans-serif; font-size: 16px; vertical-align: top;"
      valign="top">
        <h2
          style="color: #151A2D; font-family: 'Helvetica Neue' , Helvetica, Arial, 'Lucida Grande' , sans-serif; font-weight: bold; line-height: 1.4em; margin: 0; margin-bottom: 40px; margin-top: 56px; font-size: 24px; font-weight: 400;">
          Get started with #{escaped_product_name()}</h2>
        <p></p>
        <p
          style="color: #333; font-family: 'Asap', 'Helvetica Neue', Helvetica, Arial, 'Lucida Grande', sans-serif; font-size: 16px; font-weight: normal; margin: 0; margin-bottom: 15px;">
          You're almost there and ready to start using #{escaped_product_name()}:
          <br>
        </p>
        <p
          style="color: #333; font-family: 'Asap', 'Helvetica Neue', Helvetica, Arial, 'Lucida Grande', sans-serif; font-size: 16px; font-weight: normal; margin: 0; margin-bottom: 15px;">
          <a href="#{signup_url}" target="_blank">Click here to verify</a>
          <br><br>
        </p>
        <p
          style="color: #333; font-family: 'Asap', 'Helvetica Neue', Helvetica, Arial, 'Lucida Grande', sans-serif; font-size: 16px; font-weight: normal; margin: 0; margin-bottom: 15px;">
          Thank you for trying out #{escaped_product_name()}!
        </p>
      </td>
      """
    )
  end

  def deliver_login_instructions(user, url) do
    login_url = resolve_url(url)

    deliver(
      user.email,
      "#{product_name()} login verification",
      """
      Hi,

      To get access to your account go to: #{login_url}

      - #{signature()}
      """,
      """
      <td
      style="box-sizing: border-box; font-family: 'Helvetica Neue' , Helvetica, Arial, 'Lucida Grande' , sans-serif; font-size: 16px; vertical-align: top;"
      valign="top">
        <h2
          style="color: #151A2D; font-family: 'Helvetica Neue' , Helvetica, Arial, 'Lucida Grande' , sans-serif; font-weight: bold; line-height: 1.4em; margin: 0; margin-bottom: 40px; margin-top: 56px; font-size: 24px; font-weight: 400;">
          Access your account on #{escaped_product_name()}</h2>
        <p></p>
        <p
          style="color: #333; font-family: 'Asap', 'Helvetica Neue', Helvetica, Arial, 'Lucida Grande', sans-serif; font-size: 16px; font-weight: normal; margin: 0; margin-bottom: 15px;">
          Use the following link to access your #{escaped_product_name()} account:
          <br>
        </p>
        <p
          style="color: #333; font-family: 'Asap', 'Helvetica Neue', Helvetica, Arial, 'Lucida Grande', sans-serif; font-size: 16px; font-weight: normal; margin: 0; margin-bottom: 15px;">
          <a href="#{login_url}" target="_blank">Click here to login</a>
          <br><br>
        </p>
      </td>
      """
    )
  end

  def deliver_space_invite_instructions(user, space, url) do
    deliver_space_invite_instructions(user, space, nil, url)
  end

  def deliver_space_invite_instructions(user, space, inviter, url) do
    invite_url = resolve_url(url)
    inviter_label = invite_sender(inviter)
    space_name = space_invite_name(space)

    deliver(
      user.email,
      "#{product_name()} invite from #{inviter_label}",
      """
      Hi,

      You have been invited to #{product_name()} by #{inviter_label}: #{invite_url}#{space_invite_text_note(space_name)}

      Thanks for trying out #{product_name()}!

      - #{signature()}
      """,
      """
      <td
      style="box-sizing: border-box; font-family: 'Helvetica Neue' , Helvetica, Arial, 'Lucida Grande' , sans-serif; font-size: 16px; vertical-align: top;"
      valign="top">
        <h2
          style="color: #151A2D; font-family: 'Helvetica Neue' , Helvetica, Arial, 'Lucida Grande' , sans-serif; font-weight: bold; line-height: 1.4em; margin: 0; margin-bottom: 40px; margin-top: 56px; font-size: 24px; font-weight: 400;">
          You have been invited to #{escaped_product_name()} by #{html_escape(inviter_label)}</h2>
        <p
          style="color: #333; font-family: 'Asap', 'Helvetica Neue', Helvetica, Arial, 'Lucida Grande', sans-serif; font-size: 16px; font-weight: normal; margin: 0; margin-bottom: 15px;">
          Use the following link to access your #{escaped_product_name()} account:
          <br>
        </p>
        #{space_invite_html_note(space_name)}
        <p
          style="color: #333; font-family: 'Asap', 'Helvetica Neue', Helvetica, Arial, 'Lucida Grande', sans-serif; font-size: 16px; font-weight: normal; margin: 0; margin-bottom: 15px;">
          <a href="#{invite_url}" target="_blank">Click here to accept</a>
          <br><br>
        </p>
      </td>
      """
    )
  end

  # A host may supply a module exporting render/1; Core keeps a neutral default.
  def email_layout(inner_content) when is_binary(inner_content) do
    case branding_value(:layout) do
      module when is_atom(module) and module not in [nil, false, true] ->
        module.render(inner_content)

      _layout ->
        generic_layout(inner_content)
    end
  end

  defp deliver(recipient, subject, text_body, html_body) do
    email =
      new()
      |> to(String.trim(recipient))
      |> from(from_address())
      |> subject(subject)
      |> text_body(text_body)
      |> html_body(email_layout(html_body))

    opts = Application.get_env(:mave_core, MaveCore.Mailer, [])

    if is_list(opts) and Keyword.get(opts, :adapter) not in [nil, false] do
      Mailer.deliver(email)
    else
      Logger.warning("MaveCore.Mailer adapter missing; skipping email delivery")
      {:error, :mailer_not_configured}
    end
  rescue
    error ->
      Logger.error("Failed to deliver email: #{Exception.message(error)}")
      {:error, :mailer_delivery_failed}
  end

  defp from_address do
    Application.get_env(:mave_core, :email_from, @default_from_address)
  end

  defp product_name, do: branding_value(:product_name, "Mave Core")
  defp signature, do: branding_value(:signature, product_name())
  defp escaped_product_name, do: html_escape(product_name())

  defp branding_value(key, default \\ nil) do
    case Application.get_env(:mave_core, :email_branding, []) do
      config when is_list(config) ->
        Keyword.get(config, key, default)

      config when is_map(config) ->
        Map.get(config, key, Map.get(config, Atom.to_string(key), default))

      _config ->
        default
    end
  end

  defp generic_layout(inner_content) do
    """
    <!doctype html>
    <html>
      <head>
        <meta name="viewport" content="width=device-width">
        <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
        <title>#{escaped_product_name()}</title>
      </head>
      <body style="font-family: Helvetica, Arial, sans-serif; color: #333; background: #f7f8fb;">
        <table width="100%" cellpadding="0" cellspacing="0" border="0" role="presentation">
          <tr>
            <td style="padding: 32px;">
              <table width="100%" cellpadding="0" cellspacing="0" border="0" role="presentation" style="max-width: 600px; margin: 0 auto; background: #fff;">
                <tr><td style="padding: 32px 40px; font-size: 16px; line-height: 1.6;">#{inner_content}</td></tr>
                <tr><td style="padding: 0 40px 32px; color: #8a8fa3; font-size: 12px;">Sent automatically by #{escaped_product_name()}.</td></tr>
              </table>
            </td>
          </tr>
        </table>
      </body>
    </html>
    """
  end

  defp base_domain do
    case Application.get_env(:mave_core, :domain) do
      domain when is_binary(domain) and domain != "" ->
        String.trim_trailing(domain, "/")

      _ ->
        endpoint_config = Application.get_env(:mave_core, MaveCoreWeb.Endpoint, [])
        url_config = Keyword.get(endpoint_config, :url, [])

        scheme = Keyword.get(url_config, :scheme, "http")
        host = Keyword.get(url_config, :host, "localhost")

        port =
          normalize_port(Keyword.get(url_config, :port) || endpoint_http_port(endpoint_config))

        case {port, scheme} do
          {nil, _} -> "#{scheme}://#{host}"
          {80, "http"} -> "#{scheme}://#{host}"
          {443, "https"} -> "#{scheme}://#{host}"
          {value, _} -> "#{scheme}://#{host}:#{value}"
        end
    end
  end

  defp endpoint_http_port(endpoint_config) when is_list(endpoint_config) do
    case Keyword.get(endpoint_config, :http) do
      http_config when is_list(http_config) -> Keyword.get(http_config, :port)
      _ -> nil
    end
  end

  defp endpoint_http_port(_), do: nil

  defp normalize_port(nil), do: nil
  defp normalize_port(port) when is_integer(port), do: port

  defp normalize_port(port) when is_binary(port) do
    case Integer.parse(port) do
      {value, ""} -> value
      _ -> nil
    end
  end

  defp normalize_port(_), do: nil

  defp resolve_url(url) when is_binary(url) do
    case String.trim(url) do
      "" ->
        base_domain()

      normalized ->
        uri = URI.parse(normalized)

        relative =
          %URI{
            path: canonical_url_path(uri.path),
            query: uri.query,
            fragment: uri.fragment
          }
          |> URI.to_string()

        base_domain() <> relative
    end
  end

  defp resolve_url(_), do: base_domain()

  defp canonical_url_path(path) when is_binary(path) do
    if String.starts_with?(path, "/"), do: path, else: "/" <> path
  end

  defp canonical_url_path(_path), do: "/"

  defp invite_sender(%User{email: email}) when is_binary(email), do: email
  defp invite_sender(%{email: email}) when is_binary(email), do: email
  defp invite_sender(_inviter), do: signature()

  defp space_invite_name(%{id: id} = space) when is_binary(id) do
    case first_domain(space) do
      domain when is_binary(domain) and domain != "" -> domain
      _ -> nil
    end
  end

  defp space_invite_name(_space), do: nil

  defp space_invite_text_note(space_name) when is_binary(space_name) do
    "\n\nThis invite is for #{space_name}."
  end

  defp space_invite_text_note(_space_name), do: ""

  defp space_invite_html_note(space_name) when is_binary(space_name) do
    """
        <p
          style="color: #333; font-family: 'Asap', 'Helvetica Neue', Helvetica, Arial, 'Lucida Grande', sans-serif; font-size: 16px; font-weight: normal; margin: 0; margin-bottom: 15px;">
          This invite is for <strong>#{html_escape(space_name)}</strong>.
        </p>
    """
  end

  defp space_invite_html_note(_space_name), do: ""

  defp html_escape(value) do
    value
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp first_domain(%{domains: [%{domain: domain} | _]}) when is_binary(domain) and domain != "",
    do: domain

  defp first_domain(space) do
    space
    |> Spaces.list_domains()
    |> case do
      [%{domain: domain} | _] when is_binary(domain) and domain != "" -> domain
      _ -> nil
    end
  end
end
