defmodule MaveCore.Repo.Migrations.IndexFlowRunsByMedia do
  use Ecto.Migration

  def up do
    execute("""
    CREATE INDEX flow_runs_input_space_embed_inserted_at_index
    ON flow_runs ((input->>'space_hash'), (input->>'embed_hash'), inserted_at DESC)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS flow_runs_input_space_embed_inserted_at_index")
  end
end
