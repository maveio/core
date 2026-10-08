defmodule MaveCore.Repo.Migrations.AddDefaultFlowTemplateToSpaces do
  use Ecto.Migration

  def change do
    alter table(:spaces) do
      add :default_flow_template, :string
    end
  end
end
