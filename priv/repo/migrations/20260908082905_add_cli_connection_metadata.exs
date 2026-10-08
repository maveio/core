defmodule MaveCore.Repo.Migrations.AddCliConnectionMetadata do
  use Ecto.Migration

  def change do
    alter table(:cli_authorizations) do
      add(:client_metadata, :map, null: false, default: %{})
    end

    alter table(:space_keys) do
      # NULL denotes an ordinary key; even an unnamed CLI connection stores {}.
      # Descriptions alone cannot reliably identify older CLI-issued keys.
      add(:cli_metadata, :map)
    end
  end
end
