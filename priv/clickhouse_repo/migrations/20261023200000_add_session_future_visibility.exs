defmodule MaveCore.ClickHouseRepo.Migrations.AddSessionFutureVisibility do
  use Ecto.Migration

  def up do
    # A compact predicate avoids loading every event array when only a few
    # sessions have crossed a visibility deadline. Existing writers remain valid.
    execute("""
    ALTER TABLE analytics_sessions ADD COLUMN future_at Nullable(DateTime64(6))
    MATERIALIZED arrayReduce('minOrNull',
      arrayMap(e -> e.2, arrayFilter(e -> e.2 >= created_at, events)))
    """)
  end

  def down do
    execute("ALTER TABLE analytics_sessions DROP COLUMN future_at")
  end
end
