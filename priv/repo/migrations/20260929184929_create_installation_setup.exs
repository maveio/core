defmodule MaveCore.Repo.Migrations.CreateInstallationSetup do
  use Ecto.Migration

  def change do
    create table(:installation_setup, primary_key: false) do
      add :id, :integer, primary_key: true
      add :completed_at, :utc_datetime_usec, null: false
    end

    # Existing installations must stay closed even if all accounts are later removed.
    execute(
      "INSERT INTO installation_setup (id, completed_at) SELECT 1, NOW() WHERE EXISTS (SELECT 1 FROM users)",
      "SELECT 1"
    )

    create constraint(:installation_setup, :installation_setup_singleton, check: "id = 1")
  end
end
