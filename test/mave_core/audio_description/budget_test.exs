defmodule MaveCore.AudioDescription.BudgetTest do
  use ExUnit.Case, async: true
  alias MaveCore.AudioDescription.{Budget, Cues, Timeline}

  defp cue(start, stop, text, priority),
    do: %{
      start: start * 1.0,
      end: stop * 1.0,
      text: text,
      priority: priority,
      kind: "text",
      scene: %{start: 0.0, end: 10.0}
    }

  test "reserves end room and prioritizes essential visible text over optional detail" do
    low = cue(8.5, 9.5, "The background is blue.", 1)
    essential = cue(8, 10, "Call 112.", 3)
    plan = Budget.allocate([low, essential], [%{start: 0.0, end: 7.0}], 10, "tutorial")
    assert [%{text: "Call 112.", window: window}] = plan.cues
    assert window.start >= 7
    assert window.end <= 9.7
    assert [%{"priority" => 1, "reason" => "no_safe_time"}] = plan.rejected
  end

  test "coarse scenes cannot let setup displace later main actions" do
    cues = [
      cue(0.1, 1, "Setup.", 1),
      cue(1.2, 2.4, "Two people toast.", 3),
      cue(3.5, 5, "A passenger waits.", 3),
      cue(6, 8, "A player gestures.", 3)
    ]

    plan = Budget.allocate(cues, [%{start: 0.0, end: 3.0}], 8, "montage")
    toast = Enum.find(plan.cues, &(&1.text == "Two people toast."))
    assert toast
    assert toast.scene.end == 3.0
    assert toast.duck_window.end <= 3.5

    for item <- plan.cues do
      window = item.window || item.duck_window
      assert window.end <= item.scene.end
      assert window.start >= item.scene.start
    end
  end

  test "a sustained closing instruction can wait for speech to finish without ducking" do
    instruction = %{
      cue(15, 24, "Read the guide at example.org.", 3)
      | scene: %{start: 15.0, end: 24.0}
    }

    detail = %{
      cue(20, 22, "A person smiles.", 3)
      | kind: "action",
        scene: %{start: 15.0, end: 24.0}
    }

    for category <- ["interview", "tutorial", "other"] do
      plan = Budget.allocate([detail, instruction], [%{start: 0.0, end: 19.0}], 24, category)
      selected = Enum.find(plan.cues, &(&1.text == instruction.text))
      assert selected.window.start >= 19.0
      assert selected.window.end <= 23.7
      assert selected.max_words >= 6
    end
  end

  test "a late proposed cue uses earlier visible footage before ducking dialogue" do
    item = %{
      cue(12.7, 16, "Inside a studio.", 3)
      | kind: "setting",
        scene: %{start: 9.0, end: 16.0}
    }

    item = Map.put(item, :visual_window, %{start: 9.0, end: 16.0})

    [restored] =
      [item] |> Cues.to_json() |> Jason.encode!() |> Jason.decode!() |> Cues.from_json()

    plan = Budget.allocate([restored], [%{start: 12.65, end: 20.0}], 20, "interview")
    assert [planned] = plan.cues
    assert planned.window.start >= 9.0
    assert planned.window.end <= 12.65
    result = Timeline.plan_timeline([planned], [1500], [%{start: 12.65, end: 20.0}], 20, 1000)
    assert result.ducks == []
    assert length(result.placements) == 1
  end

  test "continuous dialogue reserves ducking only for essential information" do
    essential = cue(2, 4, "Press Save.", 3)
    optional = cue(5, 7, "A blue background.", 1)
    plan = Budget.allocate([essential, optional], [%{start: 0.0, end: 10.0}], 10, "tutorial")
    assert [%{window: nil, duck_window: fallback, priority: 3}] = plan.cues

    assert [%{window: nil, duck_window: ^fallback}] =
             plan.cues |> Cues.to_json() |> Jason.encode!() |> Jason.decode!() |> Cues.from_json()

    assert fallback.end <= 9.7
    assert [%{"priority" => 1}] = plan.rejected
  end

  test "short clips and music have a smaller total word budget" do
    assert Budget.word_limit([], 8, "montage") < 12
    assert Budget.word_limit([], 120, "music") < Budget.word_limit([], 120, "tutorial")
  end

  test "reserved windows survive JSON and never allow cut-off audio" do
    plan = Budget.allocate([cue(8, 10, "Call 112.", 3)], [], 10, "other")

    [planned] =
      plan.cues |> Cues.to_json() |> Jason.encode!() |> Jason.decode!() |> Cues.from_json()

    assert planned.priority == 3
    assert planned.kind == "text"
    assert planned.window.end <= 9.7
    length_ms = round((planned.window.end - planned.window.start) * 1000)
    fitted = Timeline.plan_timeline([planned], [length_ms], [], 10, 1000)
    assert [%{end: stop}] = fitted.cues
    assert stop <= 9.7
    oversized = Timeline.plan_timeline([planned], [length_ms + 1], [], 10, 1000)
    assert oversized.placements == []
    assert oversized.skipped == [0]
  end

  test "quality indicators use accepted speech durations" do
    metrics =
      Timeline.quality_metrics(
        [%{start: 1.0, end: 2.5, text: "Press Save."}],
        [%{start: 2.0, end: 3.0}],
        8.0
      )

    assert metrics == %{
             "description_seconds" => 1.5,
             "speech_overlap_seconds" => 0.5,
             "ending_room_seconds" => 5.5,
             "spoken_word_count" => 2
           }
  end

  test "global end protection also rejects legacy clips that run beyond the video" do
    legacy = [%{start: 0.0, end: 10.0, text: "First."}, %{start: 9.8, end: 10.0, text: "Last."}]
    plan = Timeline.plan_timeline(legacy, [9800, 400], [], 10, 1000)
    assert plan.skipped == [1]
    assert Enum.all?(plan.cues, &(&1.end <= 10))
  end
end
