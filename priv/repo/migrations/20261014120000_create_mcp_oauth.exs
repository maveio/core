defmodule MaveCore.Repo.Migrations.CreateMcpOauth do
  use Ecto.Migration

  def change do
    create table(:mcp_clients, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :redirect_uris, {:array, :text}, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create table(:mcp_grants, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :client_id, references(:mcp_clients, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :space_id, references(:spaces, type: :binary_id, on_delete: :delete_all), null: false
      add :resource, :text, null: false
      add :scope, :string, null: false
      add :redirect_uri, :text, null: false
      add :code_hash, :binary, null: false
      add :code_challenge, :string, null: false
      add :code_expires_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mcp_grants, [:code_hash])
    create index(:mcp_grants, [:user_id])
    create index(:mcp_grants, [:client_id])
    create index(:mcp_grants, [:space_id])
    create index(:mcp_grants, [:code_expires_at])

    create table(:mcp_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :grant_id, references(:mcp_grants, type: :binary_id, on_delete: :delete_all),
        null: false

      add :access_hash, :binary, null: false
      add :refresh_hash, :binary, null: false
      add :access_expires_at, :utc_datetime_usec, null: false
      add :refresh_expires_at, :utc_datetime_usec, null: false
      add :refreshed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mcp_tokens, [:access_hash])
    create unique_index(:mcp_tokens, [:refresh_hash])
    create index(:mcp_tokens, [:grant_id])
    create index(:mcp_tokens, [:refresh_expires_at])
  end
end
