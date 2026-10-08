defmodule MaveCore.Repo.Migrations.AddPurposeToSpaceKeys do
  use Ecto.Migration

  def up do
    alter table(:space_keys) do
      add :purpose, :string
    end

    create constraint(:space_keys, :space_keys_purpose_check,
             check: "purpose IS NULL OR purpose IN ('dashboard_uploads')"
           )

    execute("""
    WITH dashboard_upload_keys AS (
      SELECT DISTINCT ON (space_id) id
      FROM space_keys
      WHERE description = 'Dashboard uploads'
      ORDER BY space_id, last_used_at DESC NULLS LAST, inserted_at ASC, id ASC
    )
    UPDATE space_keys AS keys
    SET purpose = 'dashboard_uploads', access_level = 'read_write'
    FROM dashboard_upload_keys
    WHERE keys.id = dashboard_upload_keys.id
    """)

    create unique_index(:space_keys, [:space_id, :purpose], where: "purpose IS NOT NULL")
  end

  def down do
    drop index(:space_keys, [:space_id, :purpose])
    drop constraint(:space_keys, :space_keys_purpose_check)

    alter table(:space_keys) do
      remove :purpose
    end
  end
end
