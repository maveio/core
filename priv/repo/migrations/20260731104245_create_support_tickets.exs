defmodule MaveCore.Repo.Migrations.CreateSupportTickets do
  use Ecto.Migration

  def change do
    create table(:support_tickets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :space_id, references(:spaces, type: :binary_id, on_delete: :delete_all), null: false

      add :created_by_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false

      add :subject, :string, null: false
      add :description, :text, null: false
      add :status, :string, null: false, default: "open"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:support_tickets, [:space_id, :inserted_at])
    create index(:support_tickets, [:space_id, :status])

    create constraint(:support_tickets, :support_tickets_valid_status,
             check: "status IN ('open', 'closed')"
           )
  end
end
