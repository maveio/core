defmodule MaveCore.Experiments.Stats do
  @moduledoc """
  Decides whether an A/B test has a winner.

  The decision is made once, at the end of the configured period. A variant
  wins only when every variant reached the minimum number of views and the
  leader beats each other variant at 95% confidence. Comparing more than two
  variants divides the allowed error across the comparisons (Bonferroni).

  Watch time uses Welch's test on seconds watched per view; completion uses a
  pooled two-proportion test. Both use a normal approximation, which is why a
  test needs at least 30 views per variant.
  """

  @confidence 0.95

  @type variant :: %{
          required(:id) => term(),
          required(:views) => non_neg_integer(),
          required(:watch_seconds) => float(),
          required(:watch_variance) => float(),
          required(:completions) => non_neg_integer()
        }

  @type outcome ::
          {:winner, term()}
          | {:inconclusive, :insufficient_views | :no_clear_difference}

  @type evaluation :: %{
          outcome: outcome(),
          leader_id: term() | nil,
          confidence: float() | nil,
          required_confidence: float()
        }

  @doc "The value a variant scores on `metric`: seconds per view, or a share between 0 and 1."
  @spec value(variant(), :watch_time | :completion_rate) :: float()
  def value(%{views: 0}, _metric), do: 0.0
  def value(%{watch_seconds: seconds}, :watch_time), do: seconds * 1.0
  def value(%{views: views, completions: completions}, :completion_rate), do: completions / views

  @spec evaluate([variant()], :watch_time | :completion_rate, pos_integer()) :: evaluation()
  def evaluate(variants, metric, min_views) when is_list(variants) do
    required = required_confidence(length(variants))
    leader = leader(variants, metric)
    confidence = leader && confidence(leader, variants, metric)

    outcome =
      cond do
        Enum.any?(variants, &(&1.views < min_views)) -> {:inconclusive, :insufficient_views}
        is_nil(leader) or confidence < required -> {:inconclusive, :no_clear_difference}
        true -> {:winner, leader.id}
      end

    %{
      outcome: outcome,
      leader_id: leader && leader.id,
      confidence: confidence,
      required_confidence: required
    }
  end

  @doc "Confidence each comparison must reach so the whole test stays at 95%."
  @spec required_confidence(non_neg_integer()) :: float()
  def required_confidence(variant_count) when variant_count > 2,
    do: 1 - (1 - @confidence) / (variant_count - 1)

  def required_confidence(_variant_count), do: @confidence

  # A tie for first place has no leader.
  defp leader(variants, metric) do
    case Enum.sort_by(variants, &value(&1, metric), :desc) do
      [first, second | _] ->
        if first.views > 0 and value(first, metric) > value(second, metric), do: first

      _ ->
        nil
    end
  end

  # The weakest comparison decides: the leader must beat every other variant.
  defp confidence(leader, variants, metric) do
    variants
    |> Enum.reject(&(&1.id == leader.id))
    |> Enum.map(&(1 - p_value(leader, &1, metric)))
    |> Enum.min()
  end

  @doc "Two-sided p-value for the difference between two variants."
  @spec p_value(variant(), variant(), :watch_time | :completion_rate) :: float()
  def p_value(%{views: a}, %{views: b}, _metric) when a < 2 or b < 2, do: 1.0

  def p_value(a, b, :watch_time) do
    standard_error = :math.sqrt(a.watch_variance / a.views + b.watch_variance / b.views)
    two_sided(a.watch_seconds - b.watch_seconds, standard_error)
  end

  def p_value(a, b, :completion_rate) do
    pooled = (a.completions + b.completions) / (a.views + b.views)
    standard_error = :math.sqrt(pooled * (1 - pooled) * (1 / a.views + 1 / b.views))
    two_sided(a.completions / a.views - b.completions / b.views, standard_error)
  end

  # Without any spread there is nothing to test: identical samples differ by
  # nothing, and constant samples that differ are treated as certain.
  defp two_sided(difference, standard_error) when standard_error <= 0.0,
    do: if(difference == 0, do: 1.0, else: 0.0)

  defp two_sided(difference, standard_error),
    do: :math.erfc(abs(difference / standard_error) / :math.sqrt(2))
end
