defmodule MaveCore.Repo.Migrations.RepairMalformedDurableSourceFlowInputs do
  use Ecto.Migration

  def change do
    execute(
      """
      UPDATE flow_runs
      SET input = (input->0) || ((input->>1)::jsonb)
      WHERE jsonb_typeof(input) = 'array'
        AND jsonb_array_length(input) = 2
        AND jsonb_typeof(input->0) = 'object'
        AND jsonb_typeof(input->1) = 'string'
        AND input->>1 = '{"durable_source_required":true}'
      """,
      "SELECT 1"
    )
  end
end
