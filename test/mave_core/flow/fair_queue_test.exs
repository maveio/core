defmodule MaveCore.Flow.FairQueueTest do
  use ExUnit.Case, async: true

  alias MaveCore.Flow.FairQueue

  test "keeps the configured per-space ceiling for fixed queues" do
    assert FairQueue.space_concurrency(
             [space_concurrency: 6, global_concurrency: 50],
             1
           ) == 6
  end

  test "lets a single space borrow all idle foreground capacity" do
    config = [
      space_concurrency: 6,
      global_concurrency: 50,
      work_conserving: true
    ]

    assert FairQueue.space_concurrency(config, 1) == 50
    assert FairQueue.space_concurrency(config, 2) == 25
    assert FairQueue.space_concurrency(config, 3) == 17
    assert FairQueue.space_concurrency(config, 10) == 5
    assert FairQueue.space_concurrency(config, 100) == 1
  end

  test "keeps immediate headroom for a newly demanding space" do
    config = [
      space_concurrency: 6,
      global_concurrency: 50,
      new_space_headroom: 5,
      work_conserving: true
    ]

    assert FairQueue.space_concurrency(config, 1) == 45
    assert FairQueue.space_concurrency(config, 2) == 25
    assert FairQueue.space_concurrency(config, 3) == 17
  end

  test "uses the reserved background capacity for background shares" do
    config = [
      space_concurrency: 2,
      global_concurrency: 50,
      background_concurrency: 38,
      work_conserving: true
    ]

    assert FairQueue.space_concurrency(config, 1) == 38
    assert FairQueue.space_concurrency(config, 2) == 19
    assert FairQueue.space_concurrency(config, 3) == 13
  end

  test "falls back to configured concurrency when demand is unavailable" do
    config = [
      space_concurrency: 6,
      global_concurrency: 50,
      work_conserving: true
    ]

    assert FairQueue.space_concurrency(config, 0) == 6
  end

  test "lets one run borrow up to its source-safety ceiling" do
    config = [
      run_concurrency: 6,
      global_concurrency: 50,
      background_concurrency: 38,
      work_conserving: true
    ]

    assert FairQueue.run_concurrency(config, 1) == 6
    assert FairQueue.run_concurrency(config, 6) == 6
    assert FairQueue.run_concurrency(config, 7) == 6
    assert FairQueue.run_concurrency(config, 8) == 5
    assert FairQueue.run_concurrency(config, 19) == 2
    assert FairQueue.run_concurrency(config, 38) == 1
  end

  test "keeps fixed per-run concurrency when work conservation is disabled" do
    assert FairQueue.run_concurrency([run_concurrency: 2], 1) == 2
    assert FairQueue.run_concurrency([run_concurrency: 2], 20) == 2
    assert FairQueue.run_concurrency([], 1) == nil
  end
end
