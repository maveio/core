defmodule MaveCore.Media.ImageGenerationBudgetTest do
  use ExUnit.Case

  alias MaveCore.Media.ImageGenerationBudget

  setup do
    original_config = Application.get_env(:mave_core, :image_generation_budget)

    Application.put_env(:mave_core, :image_generation_budget,
      per_minute: 2,
      per_day: 3
    )

    on_exit(fn -> restore_env(:image_generation_budget, original_config) end)

    unique = System.unique_integer([:positive])

    %{
      space_hash: "space-#{unique}",
      embed_hash: "embed-#{unique}",
      now_ms: :timer.minutes(2)
    }
  end

  test "limits actual generation reservations per embed across short and daily windows",
       context do
    one_minute_ms = :timer.minutes(1)

    assert :ok =
             ImageGenerationBudget.reserve(
               context.space_hash,
               context.embed_hash,
               context.now_ms
             )

    assert :ok =
             ImageGenerationBudget.reserve(
               context.space_hash,
               context.embed_hash,
               context.now_ms
             )

    assert {:error, {:rate_limited, ^one_minute_ms}} =
             ImageGenerationBudget.reserve(
               context.space_hash,
               context.embed_hash,
               context.now_ms
             )

    assert :ok =
             ImageGenerationBudget.reserve(
               context.space_hash,
               context.embed_hash,
               context.now_ms + :timer.minutes(1)
             )

    assert {:error, {:rate_limited, retry_after_ms}} =
             ImageGenerationBudget.reserve(
               context.space_hash,
               context.embed_hash,
               context.now_ms + :timer.minutes(2)
             )

    assert retry_after_ms > :timer.hours(23)
  end

  test "keeps budgets independent between embeds", context do
    assert :ok =
             ImageGenerationBudget.reserve(
               context.space_hash,
               context.embed_hash,
               context.now_ms
             )

    assert :ok =
             ImageGenerationBudget.reserve(
               context.space_hash,
               "another-#{context.embed_hash}",
               context.now_ms
             )
  end

  test "does not allow concurrent reservations to exceed the configured budget", context do
    Application.put_env(:mave_core, :image_generation_budget,
      per_minute: 5,
      per_day: 5
    )

    results =
      1..20
      |> Task.async_stream(
        fn _index ->
          ImageGenerationBudget.reserve(
            context.space_hash,
            context.embed_hash,
            context.now_ms
          )
        end,
        max_concurrency: 20,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == :ok)) == 5
    assert Enum.count(results, &match?({:error, {:rate_limited, _retry_after_ms}}, &1)) == 15
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)
end
