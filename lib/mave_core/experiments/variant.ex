defmodule MaveCore.Experiments.Variant do
  @moduledoc false
  use MaveCore.Schema

  alias MaveCore.Embeds.Embed
  alias MaveCore.Experiments.Experiment

  schema "experiment_variants" do
    # Position 0 is the embed's own video, the original.
    field :position, :integer

    belongs_to :experiment, Experiment
    belongs_to :embed, Embed

    timestamps()
  end

  @doc "A, B, C or D."
  def label(%__MODULE__{position: position}), do: label(position)
  def label(position) when is_integer(position) and position >= 0, do: <<?A + position>>
end
