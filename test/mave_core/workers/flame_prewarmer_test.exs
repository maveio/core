defmodule MaveCore.Workers.FlamePrewarmerTest do
  use ExUnit.Case, async: true

  alias MaveCore.Workers.FlamePrewarmer

  test "periodically warms the configured FLAME pool" do
    parent = self()
    name = :"flame_prewarmer_#{System.unique_integer([:positive])}"

    start_supervised!(
      {FlamePrewarmer,
       name: name,
       pool: :test_pool,
       initial_delay_ms: 0,
       interval_ms: 20,
       call_timeout_ms: 123,
       warmer: fn pool, timeout_ms ->
         send(parent, {:warm, pool, timeout_ms})
         :ok
       end}
    )

    assert_receive {:warm, :test_pool, 123}, 100
    assert_receive {:warm, :test_pool, 123}, 100
  end

  test "keeps running when a prewarm attempt exits" do
    parent = self()
    name = :"flame_prewarmer_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {FlamePrewarmer,
         name: name,
         pool: :test_pool,
         initial_delay_ms: 0,
         interval_ms: 20,
         warmer: fn _pool, _timeout_ms ->
           send(parent, :warm_attempted)
           exit(:no_capacity)
         end}
      )

    assert_receive :warm_attempted, 100
    assert %FlamePrewarmer{} = :sys.get_state(pid)
  end
end
