defmodule MaveCore.Experiments.Experiment do
  @moduledoc false
  use MaveCore.Schema
  import Ecto.Changeset

  alias MaveCore.Embeds.Embed
  alias MaveCore.Experiments.Variant
  alias MaveCore.Spaces.Space

  @metrics [:watch_time, :completion_rate]
  @active_statuses [:running, :needs_decision, :locked]

  schema "experiments" do
    field :status, Ecto.Enum,
      values: [:running, :needs_decision, :locked, :ended],
      default: :running

    field :metric, Ecto.Enum, values: @metrics
    field :duration_days, :integer
    field :min_views, :integer
    field :started_at, :utc_datetime_usec
    field :ends_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :decided_by, Ecto.Enum, values: [:automatic, :manual]

    field :outcome_reason, Ecto.Enum, values: [:insufficient_views, :no_clear_difference]

    # Statistics as they stood when the test was decided or stopped.
    field :results, :map

    belongs_to :space, Space
    belongs_to :embed, Embed
    belongs_to :winner_variant, Variant

    has_many :variants, Variant, preload_order: [asc: :position]

    timestamps()
  end

  def metrics, do: @metrics
  def active_statuses, do: @active_statuses

  @doc "Validates the settings a person chooses when starting a test."
  def settings_changeset(experiment, attrs) do
    experiment
    |> cast(attrs, [:metric, :duration_days, :min_views])
    |> validate_required([:metric, :duration_days, :min_views])
    |> validate_number(:duration_days, greater_than_or_equal_to: 1, less_than_or_equal_to: 90)
    # The significance test relies on a normal approximation.
    |> validate_number(:min_views, greater_than_or_equal_to: 30, less_than_or_equal_to: 1_000_000)
    |> unique_constraint(:embed_id,
      name: :experiments_active_embed_index,
      message: "already has an A/B test"
    )
  end
end
