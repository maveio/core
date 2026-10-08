defmodule MaveCore.Repo.Migrations.CreateImageVariants do
  use Ecto.Migration

  def change do
    create table(:image_variants, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :space_id, references(:spaces, type: :binary_id, on_delete: :delete_all), null: false
      add :embed_id, references(:embeds, type: :binary_id, on_delete: :delete_all), null: false
      add :output_path, :text, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:image_variants, [:embed_id, :output_path])
    create index(:image_variants, [:space_id])
  end
end
