defmodule MaveCore.Repo.Migrations.RemoveUploadJwtsFromFlowRuns do
  use Ecto.Migration

  def change do
    execute(
      """
      UPDATE flow_runs
      SET input = jsonb_set(
        input,
        '{upload_metadata}',
        (input->'upload_metadata') - 'token' - 'Token',
        true
      )
      WHERE jsonb_typeof(input->'upload_metadata') = 'object'
        AND (input->'upload_metadata' ? 'token' OR input->'upload_metadata' ? 'Token')
      """,
      "SELECT 1"
    )
  end
end
