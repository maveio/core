defmodule MaveCore.Workers.FlowCoordinatorWorkerTest do
  use ExUnit.Case, async: true

  alias MaveCore.Workers.FlowCoordinatorWorker

  test "uniqueness ignores terminal and executing coordinator jobs" do
    unique = FlowCoordinatorWorker.__opts__()[:unique]

    assert unique[:states] ==
             Oban.Job.states() -- [:completed, :cancelled, :discarded, :executing]
  end
end
