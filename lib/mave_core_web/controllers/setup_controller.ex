defmodule MaveCoreWeb.SetupController do
  use MaveCoreWeb, :controller

  alias MaveCore.Installation
  alias MaveCoreWeb.Plugs.InstallationSetup
  alias MaveCoreWeb.UserAuth

  plug :require_setup
  plug :put_root_layout, html: {MaveCoreWeb.Layouts, :auth}

  def show(conn, _params), do: render_form(conn, %{})

  def create(conn, %{"setup" => params}) when is_map(params) do
    case Installation.complete(params) do
      {:ok, {user, login_token}} ->
        conn
        |> delete_session(:user_return_to)
        |> put_flash(:info, "Your workspace is ready. Upload your first video to get started.")
        |> UserAuth.log_in_user(login_token, user)

      {:error, :invalid_code} ->
        render_form(conn, params, code: {"Check the setup code and try again.", []})

      {:error, :already_completed} ->
        redirect(conn, to: "/login")

      {:error, %Ecto.Changeset{} = changeset} ->
        render_form(conn, params, changeset.errors)
    end
  end

  def create(conn, _params), do: render_form(conn, %{})

  defp require_setup(conn, _opts) do
    cond do
      not InstallationSetup.standalone?(conn) or not Installation.enabled?() ->
        conn |> send_resp(404, "Not found") |> halt()

      not Installation.pending?() ->
        conn |> redirect(to: "/login") |> halt()

      true ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_header("referrer-policy", "no-referrer")
    end
  end

  defp render_form(conn, params, errors \\ []) do
    # Never echo a submitted setup code into HTML or a cookie.
    form =
      Phoenix.Component.to_form(Map.put(Map.take(params, ["email"]), "code", ""),
        as: :setup,
        errors: errors
      )

    adapter = Application.get_env(:mave_core, MaveCore.Mailer, [])[:adapter]

    conn
    |> put_status(if(errors == [], do: 200, else: 422))
    |> render(:show,
      form: form,
      local_mail?: adapter == Swoosh.Adapters.Local,
      compose_command:
        if(adapter == Swoosh.Adapters.Local,
          do: "docker compose -f compose.dev.yaml",
          else: "docker compose"
        ),
      mail_enabled?: not is_nil(adapter),
      origin: Application.get_env(:mave_core, :domain, MaveCoreWeb.Endpoint.url())
    )
  end
end
