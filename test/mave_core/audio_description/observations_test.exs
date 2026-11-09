defmodule MaveCore.AudioDescription.ObservationsTest do
  use ExUnit.Case, async: true
  alias MaveCore.AudioDescription.{Observations, Script, Timeline}

  defp row(id),
    do: %{
      "frame" => id,
      "time" => 999,
      "setting" => "A room",
      "people_and_objects" => ["A person"],
      "actions" => [],
      "changes" => ["A door is open"],
      "visible_text" => ["Exit"],
      "uncertainties" => ["Motion cannot be established"]
    }

  test "observations preserve detail but cannot change their source timestamps" do
    batch = [{%{"time" => 2.0, "scene" => 0}, 7}, {%{"time" => 4.0, "scene" => 1}, 8}]
    assert {:ok, [first, second]} = Observations.anchor([row(8), row(7)], batch)
    assert first["time"] == 2.0
    assert second["time"] == 4.0
    assert first["uncertainties"] == ["Motion cannot be established"]
    assert first["visible_text"] == ["Exit"]
    assert {:error, _} = Observations.anchor([row(7), row(7)], batch)
    assert {:error, _} = Observations.anchor([row(7)], batch)
  end

  test "narration cannot cite nonexistent evidence or exceed the video" do
    cue = %{"start" => 1, "end" => 3, "text" => "A door opens.", "observation_ids" => [7]}

    script = %{
      "cues" => [cue],
      "category" => "story",
      "summary" => "A room",
      "essential_text" => []
    }

    assert :ok = Script.validate(script, [%{"id" => 7}], 4)
    assert {:error, _} = Script.validate(script, [%{"id" => 8}], 4)
    assert {:error, _} = Script.validate(script, [%{"id" => 7}], 2)
  end

  test "cited evidence determines the visual window, not a late model timestamp" do
    cues = [%{"start" => 12.7, "end" => 16, "observation_ids" => [3, 4]}]
    observations = [%{"id" => 3, "time" => 10}, %{"id" => 4, "time" => 14}]
    shots = [%{"start" => 9, "end" => 12}, %{"start" => 12, "end" => 16}]

    assert [%{"visual_window" => %{"start" => 9, "end" => 16}}] =
             Script.anchor_cues(cues, observations, shots)
  end

  test "observation sampling covers both ends of short shots without sampling a cut" do
    shots = [%{start: 0.0, end: 2.0}, %{start: 2.0, end: 4.0}]
    samples = Timeline.plan_observation_stills(shots, 4, shots)
    assert Enum.map(samples, & &1.time) == [0.5, 1.5, 2.5, 3.5]
    assert Enum.map(samples, & &1.scene) == [0, 0, 1, 1]
  end
end
