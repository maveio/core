defmodule MaveCore.AudioDescription.ScriptEventsTest do
  use ExUnit.Case, async: true
  alias MaveCore.AudioDescription.{Budget, Cues, Script, Timeline}

  defmodule Writer do
    def chat_json(_system, [%{"text" => json}], opts) do
      send(self(), {:writer_input, Jason.decode!(json), opts[:schema]})
      send(self(), {:writer_options, opts})

      case Process.get(:writer_responses, []) do
        [response | rest] ->
          Process.put(:writer_responses, rest)
          response

        [] ->
          {:ok, Process.get(:event_script)}
      end
    end
  end

  defp event(start, stop, text, ids) do
    %{
      "start" => start,
      "end" => stop,
      "event_start" => start,
      "event_end" => stop,
      "text" => text,
      "observation_ids" => ids
    }
  end

  defp script(cues),
    do: %{
      "cues" => cues,
      "category" => "tutorial",
      "summary" => "A demonstration",
      "essential_text" => []
    }

  test "writer sees each spoken passage once and leaves scheduling fields to the scheduler" do
    frame = %{"id" => 1, "time" => 1, "spoken_context" => [%{"text" => "An explanation."}]}
    Process.put(:event_script, script([]))

    assert {:ok, _} =
             Script.write(
               Writer,
               [frame],
               %{"duration" => 5, "shots" => [%{"start" => 0, "end" => 5}]},
               %{text: "An explanation.", intervals: []},
               "en"
             )

    assert_received {:writer_input, input, schema}
    assert input["transcript"] == "An explanation."
    refute Map.has_key?(hd(input["observations"]), "spoken_context")
    assert_received {:writer_options, opts}
    assert opts[:reasoning_effort] == "low"

    for field <- ~w(shot pause max_words) do
      refute Map.has_key?(get_in(schema, ["properties", "cues", "items", "properties"]), field)
    end
  end

  test "only truncated scripts receive one bounded retry without recollecting observations" do
    document = %{"duration" => 5, "shots" => []}
    transcript = %{text: "", intervals: []}
    Process.put(:writer_responses, [{:error, :model_output_truncated}, {:ok, script([])}])
    assert {:ok, _} = Script.write(Writer, [], document, transcript, "en")
    assert_received {:writer_options, first}
    assert_received {:writer_options, second}
    assert first[:max_tokens] == 24_000
    assert second[:max_tokens] == 32_000
    refute_received {:writer_options, _}

    Process.put(:writer_responses, List.duplicate({:error, :model_output_truncated}, 2))

    assert {:error, :model_output_truncated} =
             Script.write(Writer, [], document, transcript, "en")

    assert_received {:writer_options, _}
    assert_received {:writer_options, _}
    refute_received {:writer_options, _}

    Process.put(:writer_responses, [{:error, :timeout}])
    assert {:error, :timeout} = Script.write(Writer, [], document, transcript, "en")
    assert_received {:writer_options, _}
    refute_received {:writer_options, _}
  end

  test "an uncut animation shares a pause across changes and excludes the spoken explanation" do
    frames = [
      %{"id" => 1, "time" => 1, "changes" => ["Two circles appear."]},
      %{"id" => 2, "time" => 7, "changes" => ["A line connects the circles."]},
      %{"id" => 3, "time" => 16, "changes" => ["The line pulses repeatedly."]}
    ]

    shots = [%{"start" => 0, "end" => 20}, %{"start" => 20, "end" => 24}]
    speech = [%{start: 3, end: 6}, %{start: 18, end: 24}]
    transcript = %{text: "The points represent stations.", intervals: speech}

    Process.put(
      :event_script,
      script([
        event(0, 3, "Two circles appear.", [1]),
        event(6, 10, "A line connects them.", [2])
      ])
    )

    assert {:ok, result} =
             Script.write(Writer, frames, %{"duration" => 24, "shots" => shots}, transcript, "en")

    assert_received {:writer_input, input, _}
    assert Enum.map(input["speech_free_windows"], & &1["estimated_words_per_cue"]) == [5, 19]
    assert Enum.map(input["shots"], & &1["estimated_words_in_longest_pause"]) == [19, 0]

    candidates = Cues.normalize(result["cues"], 24)
    allocation = Budget.allocate(candidates, speech, 24, "tutorial")
    assert [first, second] = allocation.cues
    assert first.window.start >= 0.5 and first.window.end <= 3
    assert second.window.start >= 6 and second.window.end <= 10
  end

  test "the writer sees what fits across live-action cuts inside one long pause" do
    shots = [
      %{"start" => 0, "end" => 3},
      %{"start" => 3, "end" => 6},
      %{"start" => 6, "end" => 12}
    ]

    frames = [%{"id" => 1, "time" => 1}, %{"id" => 2, "time" => 4}, %{"id" => 3, "time" => 7}]
    Process.put(:event_script, script([event(0, 6, "A cyclist crosses a bridge.", [1, 2])]))

    assert {:ok, result} =
             Script.write(
               Writer,
               frames,
               %{"duration" => 12, "shots" => shots},
               %{text: "", intervals: []},
               "en"
             )

    assert_received {:writer_input, input, _}
    assert Enum.map(input["shots"], & &1["estimated_words_in_longest_pause"]) == [5, 7, 13]
    assert [%{"visual_window" => %{"start" => 0, "end" => 6}}] = result["cues"]
  end

  test "successive steps in a single continuous shot retain their own speaking windows" do
    frames = [%{"id" => 1, "time" => 1}, %{"id" => 2, "time" => 5}, %{"id" => 3, "time" => 9}]
    shots = [%{"start" => 0, "end" => 12}]

    Process.put(
      :event_script,
      script([
        event(0, 4, "Opens a container.", [1]),
        event(4, 8, "Pours the liquid.", [2]),
        event(8, 12, "Stirs the mixture.", [3])
      ])
    )

    assert {:ok, result} =
             Script.write(
               Writer,
               frames,
               %{"duration" => 12, "shots" => shots},
               %{text: "", intervals: []},
               "en"
             )

    assert Enum.map(result["cues"], & &1["visual_window"]) == [
             %{"start" => 0, "end" => 4},
             %{"start" => 4, "end" => 8},
             %{"start" => 8, "end" => 12}
           ]

    candidates =
      Enum.map(result["cues"], fn cue ->
        %{
          start: cue["start"],
          end: cue["end"],
          text: cue["text"],
          visual_window: cue["visual_window"],
          priority: 2,
          kind: "action"
        }
      end)

    candidates = Timeline.snap_cues(candidates, [], [%{start: 0, end: 12}])
    allocation = Budget.allocate(candidates, [], 12, "tutorial")
    plan = Timeline.plan_timeline(allocation.cues, [1500, 1500, 1500], [], 12, 1000)
    assert length(plan.placements) == 3

    for {cue, expected_start} <- Enum.zip(plan.cues, [0, 4, 8]) do
      assert cue.start >= expected_start
      assert cue.end <= expected_start + 4
    end

    assert_received {:writer_input, input, schema}

    assert input["observation_windows"] ==
             Enum.map(1..3, &%{"observation_id" => &1, "start" => 0, "end" => 12})

    assert "event_start" in get_in(schema, ["properties", "cues", "items", "required"])
  end

  test "one continuing action can span multiple camera angles without artificial splitting" do
    observations = [
      %{"id" => 1, "time" => 1},
      %{"id" => 2, "time" => 3},
      %{"id" => 3, "time" => 5}
    ]

    shots = [
      %{"start" => 0, "end" => 2},
      %{"start" => 2, "end" => 4},
      %{"start" => 4, "end" => 6}
    ]

    cues = [event(0, 6, "A cyclist rides along the path.", [1, 2, 3])]

    assert [%{"visual_window" => %{"start" => 0, "end" => 6}}] =
             Script.anchor_cues(cues, observations, shots)
  end

  test "an early proposed speaking time cannot reveal a later event" do
    cue = event(6, 9, "A parcel opens.", [1]) |> Map.put("start", 0)

    [anchored] =
      Script.anchor_cues([cue], [%{"id" => 1, "time" => 7}], [%{"start" => 0, "end" => 10}])

    [candidate] = Cues.from_json([Map.put(anchored, "priority", 2)])
    [snapped] = Timeline.snap_cues([candidate], [], [%{start: 0, end: 10}])
    assert snapped.start >= 6
    assert snapped.scene == %{start: 6, end: 9}
  end

  test "event windows cannot expand beyond their evidence or create fictitious speaking space" do
    observations = [%{"id" => 1, "time" => 3}]
    shots = [%{"start" => 2, "end" => 4}]

    assert [%{"visual_window" => %{"start" => 2, "end" => 4}}] =
             Script.anchor_cues([event(0, 8, "A page turns.", [1])], observations, shots)

    assert [%{"visual_window" => %{"start" => 6, "end" => 6}}] =
             Script.anchor_cues([event(6, 8, "A page turns.", [1])], observations, shots)
  end

  test "invalid and partial event boundaries are rejected while legacy scripts remain readable" do
    cue = event(1, 3, "A drawer closes.", [1])
    observations = [%{"id" => 1}]

    for invalid <- [
          Map.put(cue, "event_end", 0),
          Map.put(cue, "event_start", -1),
          Map.put(cue, "event_end", 20),
          Map.put(cue, "event_start", "later"),
          Map.delete(cue, "event_end")
        ] do
      assert {:error, :invalid_narration_script} =
               Script.validate(script([invalid]), observations, 10)
    end

    assert :ok =
             Script.validate(script([Map.drop(cue, ~w(event_start event_end))]), observations, 10)
  end
end
