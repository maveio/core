defmodule MaveCore.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :mave_core

  import Ecto.Query, warn: false

  alias Ecto.Adapters.SQL
  alias MaveCore.Accounts
  alias MaveCore.Accounts.User
  alias MaveCore.Repo

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Fails when either application database is unavailable.

  This is intentionally cheap enough to use as the container readiness probe.
  Schema migrations are enforced by the one-shot migration service before the
  application container starts.
  """
  def ready! do
    Enum.each(repos(), fn repo ->
      case SQL.query(repo, "SELECT 1", []) do
        {:ok, _result} -> :ok
        {:error, error} -> raise "#{inspect(repo)} is unavailable: #{Exception.message(error)}"
      end
    end)

    :ok
  end

  @doc """
  Creates the first owner, or returns a fresh login link for the same owner.

  Once another active account exists, bootstrap refuses to create a different
  owner. This makes rerunning the installer safe without turning the release
  command into a general-purpose account provisioning backdoor.
  """
  def bootstrap_owner(email) when is_binary(email) do
    load_app()
    {:ok, _started} = Application.ensure_all_started(@app)

    email = String.trim(email)

    Repo.transaction(fn ->
      MaveCore.Installation.lock_accounts!()

      with {:ok, user, created?} <- find_or_create_bootstrap_owner(email),
           {:ok, user} <- confirm_and_prepare_owner(user) do
        MaveCore.Installation.mark_completed!()
        token = Accounts.generate_user_login_token(user)

        {:ok,
         %{
           created?: created?,
           email: user.email,
           login_url: bootstrap_login_url(token)
         }}
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  def bootstrap_owner_from_env! do
    email =
      System.get_env("MAVE_BOOTSTRAP_EMAIL") ||
        raise "MAVE_BOOTSTRAP_EMAIL is required"

    case bootstrap_owner(email) do
      {:ok, result} ->
        action = if result.created?, do: "created", else: "already existed"

        IO.puts("Owner #{result.email} #{action}.")
        IO.puts("Use this 15-minute login link:")
        IO.puts(result.login_url)

      {:error, :already_bootstrapped} ->
        raise "an owner already exists; rerun bootstrap with that owner's email"

      {:error, %Ecto.Changeset{} = changeset} ->
        raise "could not create the owner: #{inspect(changeset.errors)}"

      {:error, reason} ->
        raise "could not create the owner: #{inspect(reason)}"
    end
  end

  defp find_or_create_bootstrap_owner(email) do
    case first_active_user() do
      nil ->
        create_bootstrap_owner(email)

      %User{} = user ->
        if String.downcase(user.email) == String.downcase(email),
          do: {:ok, user, false},
          else: {:error, :already_bootstrapped}
    end
  end

  defp create_bootstrap_owner(email) do
    email
    |> Accounts.create_user(%{skip_email_validation: true})
    |> mark_owner_created()
  end

  defp mark_owner_created({:ok, user}), do: {:ok, user, true}
  defp mark_owner_created({:error, reason}), do: {:error, reason}

  defp confirm_and_prepare_owner(%User{} = user) do
    with {:ok, user} <- maybe_confirm_owner(user) do
      Accounts.ensure_default_space(user)
    end
  end

  defp maybe_confirm_owner(%User{confirmed_at: nil} = user) do
    user
    |> User.confirm_changeset()
    |> Repo.update()
  end

  defp maybe_confirm_owner(%User{} = user), do: {:ok, user}

  defp first_active_user do
    User
    |> where([user], is_nil(user.deleted_at))
    |> order_by([user], asc: user.inserted_at, asc: user.id)
    |> limit(1)
    |> Repo.one()
  end

  defp bootstrap_login_url(token) do
    base_url =
      @app
      |> Application.get_env(:domain, MaveCoreWeb.Endpoint.url())
      |> String.trim_trailing("/")

    "#{base_url}/videos?#{URI.encode_query(%{"token" => token})}"
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
