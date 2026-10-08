defmodule MaveCore.Repo.Migrations.CreateSupportTicketReplies do
  use Ecto.Migration

  def change do
    create table(:support_ticket_replies, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :ticket_id,
          references(:support_tickets, type: :binary_id, on_delete: :delete_all),
          null: false

      add :author_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :body, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:support_ticket_replies, [:ticket_id, :inserted_at])
  end
end
