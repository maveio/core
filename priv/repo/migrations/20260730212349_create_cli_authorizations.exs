defmodule MaveCore.Repo.Migrations.CreateCliAuthorizations do
  use Ecto.Migration

  def change do
    create table(:cli_authorizations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :device_code_hash, :binary, null: false
      add :user_code, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :expires_at, :utc_datetime_usec, null: false
      add :approved_at, :utc_datetime_usec
      add :consumed_at, :utc_datetime_usec

      add :space_id, references(:spaces, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:cli_authorizations, [:device_code_hash])
    create unique_index(:cli_authorizations, [:user_code])
    create index(:cli_authorizations, [:expires_at])
    create index(:cli_authorizations, [:space_id])

    create constraint(:cli_authorizations, :cli_authorizations_status_check,
             check: "status IN ('pending', 'approved', 'denied', 'consumed', 'expired')"
           )
  end
end
