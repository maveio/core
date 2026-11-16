defmodule MaveCore.Experiments.StatsTest do
  use ExUnit.Case, async: true

  alias MaveCore.Experiments.Stats

  defp variant(id, views, watch_seconds, completions, variance \\ 400.0) do
    %{
      id: id,
      views: views,
      watch_seconds: watch_seconds,
      watch_variance: variance,
      completions: completions
    }
  end

  test "a clear difference with enough views names the winner" do
    variants = [variant(:a, 500, 30.0, 150), variant(:b, 500, 38.0, 210)]

    assert %{outcome: {:winner, :b}, leader_id: :b, confidence: confidence} =
             Stats.evaluate(variants, :watch_time, 100)

    assert confidence > 0.99
    assert %{outcome: {:winner, :b}} = Stats.evaluate(variants, :completion_rate, 100)
  end

  test "too few views never produce a winner, however large the difference" do
    variants = [variant(:a, 500, 10.0, 50), variant(:b, 99, 60.0, 90)]

    assert %{outcome: {:inconclusive, :insufficient_views}, leader_id: :b} =
             Stats.evaluate(variants, :watch_time, 100)
  end

  test "a difference that chance could explain stays inconclusive" do
    variants = [variant(:a, 200, 30.0, 60), variant(:b, 200, 31.0, 64)]

    assert %{outcome: {:inconclusive, :no_clear_difference}, confidence: confidence} =
             Stats.evaluate(variants, :watch_time, 100)

    assert confidence < 0.95

    assert %{outcome: {:inconclusive, :no_clear_difference}} =
             Stats.evaluate(variants, :completion_rate, 100)
  end

  test "a tie has no leader" do
    variants = [variant(:a, 200, 30.0, 60), variant(:b, 200, 30.0, 60)]

    assert %{outcome: {:inconclusive, :no_clear_difference}, leader_id: nil, confidence: nil} =
             Stats.evaluate(variants, :watch_time, 100)
  end

  test "the leader must beat every other variant" do
    variants = [
      variant(:a, 500, 30.0, 150),
      variant(:b, 500, 40.0, 150),
      variant(:c, 500, 39.5, 150)
    ]

    assert %{outcome: {:inconclusive, :no_clear_difference}, leader_id: :b} =
             Stats.evaluate(variants, :watch_time, 100)
  end

  test "more variants require more confidence per comparison" do
    assert Stats.required_confidence(2) == 0.95
    assert_in_delta Stats.required_confidence(3), 0.975, 1.0e-9
    assert_in_delta Stats.required_confidence(4), 0.98333, 1.0e-5

    # 96.5% is enough between two variants, but not among three.
    a = variant(:a, 400, 30.0, 100)
    b = variant(:b, 400, 33.0, 100)
    assert_in_delta 1 - Stats.p_value(b, a, :watch_time), 0.966, 0.001

    assert %{outcome: {:winner, :b}} = Stats.evaluate([a, b], :watch_time, 100)

    assert %{outcome: {:inconclusive, :no_clear_difference}} =
             Stats.evaluate([a, b, variant(:c, 400, 20.0, 100)], :watch_time, 100)
  end

  test "p-values match the reference tests" do
    # Welch: (38 - 30) / sqrt(400/500 + 400/500) = 6.32
    assert Stats.p_value(variant(:b, 500, 38.0, 0), variant(:a, 500, 30.0, 0), :watch_time) <
             1.0e-9

    # Pooled proportions 60/200 vs 80/200: z = 2.097, p = 0.036
    assert_in_delta Stats.p_value(
                      variant(:b, 200, 0.0, 80),
                      variant(:a, 200, 0.0, 60),
                      :completion_rate
                    ),
                    0.036,
                    0.001
  end

  test "variants without spread or views do not crash" do
    assert Stats.p_value(variant(:a, 1, 5.0, 0), variant(:b, 50, 9.0, 0), :watch_time) == 1.0

    assert Stats.p_value(variant(:a, 50, 5.0, 0), variant(:b, 50, 5.0, 0), :completion_rate) ==
             1.0

    assert Stats.p_value(variant(:a, 50, 5.0, 0, 0.0), variant(:b, 50, 9.0, 0, 0.0), :watch_time) ==
             0.0

    assert Stats.value(variant(:a, 0, 0.0, 0), :completion_rate) == 0.0

    assert %{outcome: {:inconclusive, :insufficient_views}} =
             Stats.evaluate([variant(:a, 0, 0.0, 0), variant(:b, 0, 0.0, 0)], :watch_time, 30)
  end
end
