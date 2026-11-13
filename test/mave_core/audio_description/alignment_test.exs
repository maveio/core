defmodule MaveCore.AudioDescription.AlignmentTest do
  use ExUnit.Case, async: true
  alias MaveCore.AudioDescription.Script

  defmodule Writer do
    def chat_json(_instruction, [%{"text" => json}], opts) do
      send(self(), {:repair_request, Jason.decode!(json), opts})
      [response | rest] = Process.get(:alignment_responses)
      Process.put(:alignment_responses, rest)
      response
    end
  end

  defp cue(start, stop, text, refs),
    do: %{
      "start" => start,
      "end" => stop,
      "event_start" => start,
      "event_end" => stop,
      "text" => text,
      "observation_ids" => refs,
      "priority" => 2,
      "kind" => "action",
      "on_screen_text" => ""
    }

  defp script(cues),
    do: %{
      "cues" => cues,
      "category" => "story",
      "summary" => "A visitor arrives",
      "essential_text" => []
    }

  defp frames,
    do: [%{"id" => 11, "time" => 1}, %{"id" => 17, "time" => 6}, %{"id" => 19, "time" => 10}]

  defp document,
    do: %{
      "duration" => 12,
      "shots" => [
        %{"start" => 0, "end" => 3},
        %{"start" => 5, "end" => 8},
        %{"start" => 9, "end" => 12}
      ]
    }

  defp correction(index, start, stop, text, refs),
    do: cue(start, stop, text, refs) |> Map.merge(%{"index" => index, "supported" => true})

  test "repairs mismatched references and times while leaving valid cues unchanged" do
    good = cue(0, 3, "A key turns.", [11])
    bad = cue(5, 8, "A door opens.", [11])

    Process.put(:alignment_responses, [
      {:ok, %{"corrections" => [correction(1, 5, 8, bad["text"], [17])]}}
    ])

    assert {:ok, result} = Script.repair(Writer, script([good, bad]), frames(), document(), "en")
    assert [first, repaired] = result["cues"]
    assert Map.drop(first, ["visual_window"]) == good
    assert repaired["observation_ids"] == [17]
    assert repaired["visual_window"] == %{"start" => 5, "end" => 8}
    assert result["alignment_report"]["repaired_count"] == 1
    assert_received {:repair_request, input, _opts}
    assert Enum.map(input["cues_to_correct"], & &1["index"]) == [1]
    refute_received {:repair_request, _, _}
  end

  test "a coarse shared camera shot cannot hide a reference to an earlier action" do
    bad = cue(9, 12, "A visitor enters.", [11])

    Process.put(:alignment_responses, [
      {:ok, %{"corrections" => [correction(0, 9, 12, bad["text"], [19])]}}
    ])

    assert {:ok, result} =
             Script.repair(
               Writer,
               script([bad]),
               frames(),
               %{"duration" => 12, "shots" => [%{"start" => 0, "end" => 12}]},
               "en"
             )

    assert hd(result["cues"])["observation_ids"] == [19]
  end

  test "unsupported cues have an explicit evidence rejection rather than no safe time" do
    good = cue(0, 3, "A key turns.", [11])
    bad = cue(5, 8, "A visitor flies away.", [11])

    Process.put(:alignment_responses, [
      {:ok, %{"corrections" => [%{"index" => 1, "supported" => false}]}}
    ])

    assert {:ok, result} = Script.repair(Writer, script([good, bad]), frames(), document(), "en")
    assert length(result["cues"]) == 1

    assert [%{"reason" => "unsupported_visual_alignment"}] =
             result["alignment_report"]["rejected"]
  end

  test "invalid, duplicate and still mismatched corrections cannot silently become a script" do
    bad = cue(5, 8, "A door opens.", [11])
    valid = correction(0, 5, 8, bad["text"], [17])

    for rows <- [
          [],
          [valid, valid],
          [%{valid | "index" => 9}],
          [%{valid | "observation_ids" => [11]}],
          [%{valid | "observation_ids" => [999]}]
        ] do
      Process.put(:alignment_responses, [{:ok, %{"corrections" => rows}}])

      assert {:error, :invalid_alignment_repair} =
               Script.repair(Writer, script([bad]), frames(), document(), "en")
    end
  end

  test "a truncated correction gets one bounded retry using the same supplied evidence" do
    bad = cue(5, 8, "A door opens.", [11])
    response = {:ok, %{"corrections" => [correction(0, 5, 8, bad["text"], [17])]}}
    Process.put(:alignment_responses, [{:error, :model_output_truncated}, response])
    assert {:ok, _} = Script.repair(Writer, script([bad]), frames(), document(), "en")
    assert_received {:repair_request, first, first_opts}
    assert_received {:repair_request, ^first, second_opts}
    assert first_opts[:max_tokens] == 16_000
    assert second_opts[:max_tokens] == 24_000
    refute_received {:repair_request, _, _}
  end

  test "already aligned scripts require no repair request" do
    assert {:ok, result} =
             Script.repair(
               Writer,
               script([cue(5, 8, "A door opens.", [17])]),
               frames(),
               document(),
               "en"
             )

    assert result["alignment_report"]["repaired_count"] == 0
    refute_received {:repair_request, _, _}
  end
end
