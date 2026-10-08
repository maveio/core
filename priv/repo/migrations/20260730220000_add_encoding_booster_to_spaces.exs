defmodule MaveCore.Repo.Migrations.AddEncodingBoosterToSpaces do
  use Ecto.Migration

  def up do
    alter table(:spaces) do
      add :encoding_booster_enabled, :boolean, null: false, default: false
    end

    flush()

    execute("""
    UPDATE spaces
    SET encoding_booster_enabled = TRUE
    WHERE hash IN ('ubg50', 'rbp63')
    """)
  end

  def down do
    alter table(:spaces) do
      remove :encoding_booster_enabled
    end
  end
end
