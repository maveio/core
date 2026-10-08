defmodule MaveCore.Repo.Migrations.AddAccessLevelToSpaceKeys do
  use Ecto.Migration

  def change do
    alter table(:space_keys) do
      add :access_level, :string, null: false, default: "read_write"
    end

    create constraint(:space_keys, :space_keys_access_level_check,
             check: "access_level IN ('read_write', 'read_only')"
           )
  end
end
