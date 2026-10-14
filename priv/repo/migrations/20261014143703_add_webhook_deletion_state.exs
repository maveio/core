defmodule MaveCore.Repo.Migrations.AddWebhookDeletionState do
  use Ecto.Migration

  def change do
    alter table(:space_webhooks) do
      add :deleted_at, :utc_datetime_usec
    end
  end
end
