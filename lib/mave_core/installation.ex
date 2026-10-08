defmodule MaveCore.Installation do
  @moduledoc """
  One-time setup for explicitly enabled standalone installations.

  Completion survives account deletion. The users table lock also serializes
  setup against CLI bootstrap and other account creation paths.
  """
  alias MaveCore.Accounts
  alias MaveCore.Accounts.User
  alias MaveCore.Repo

  def enabled?, do: config()[:enabled] == true

  def pending? do
    enabled?() and not Repo.exists?("installation_setup") and not Repo.exists?(User)
  end

  def authorize(code) when is_binary(code) and byte_size(code) <= 256 do
    with true <- enabled?(),
         expected when is_binary(expected) and byte_size(expected) >= 32 <- setup_code(),
         true <- Plug.Crypto.secure_compare(String.trim(code), expected) do
      :ok
    else
      _ -> {:error, :invalid_code}
    end
  end

  def authorize(_), do: {:error, :invalid_code}

  def complete(params) when is_map(params) do
    with :ok <- authorize(params["code"]),
         {:ok, input} <-
           %User{}
           |> User.login_changeset(Map.take(params, ["email"]))
           |> Ecto.Changeset.apply_action(:insert) do
      Repo.transaction(fn -> provision_owner(input.email) end)
    end
  end

  defp provision_owner(email) do
    lock_accounts!()
    unless pending?(), do: Repo.rollback(:already_completed)

    case Accounts.create_user(email, %{skip_email_validation: true}) do
      {:ok, user} ->
        mark_completed!()
        token = Accounts.generate_user_login_token(user)
        {:ok, {user, login_token}} = Accounts.login_user(token)
        {user, login_token}

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  def mark_completed! do
    Repo.insert_all("installation_setup", [%{id: 1, completed_at: DateTime.utc_now()}],
      on_conflict: :nothing
    )

    :ok
  end

  def lock_accounts! do
    Repo.query!("LOCK TABLE users IN SHARE ROW EXCLUSIVE MODE")
  end

  defp setup_code do
    case config()[:code_file] do
      path when is_binary(path) and path != "" ->
        case File.read(path) do
          {:ok, value} -> String.trim(value)
          _ -> nil
        end

      _ ->
        config()[:code]
    end
  end

  defp config, do: Application.get_env(:mave_core, :installation_setup, [])
end
