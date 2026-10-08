defmodule MaveCore.Repo.Migrations.AllowDefaultStorageProfileForSpaces do
  use Ecto.Migration

  def up do
    execute "ALTER TYPE region ADD VALUE IF NOT EXISTS 'default'"
  end
end
