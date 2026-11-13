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

  defmodule Storage do
    def get(_, _, _), do: {:ok, "image"}
  end

  test "cached evidence must cover the current frame IDs, times and scenes exactly" do
    document = %{"stills" => [%{"time" => 1.5, "scene" => 0}, %{"time" => 3.5, "scene" => 1}]}

    rows = [
      row(0) |> Map.merge(%{"id" => 0, "time" => 1.5, "scene" => 0}),
      row(1) |> Map.merge(%{"id" => 1, "time" => 3.5, "scene" => 1})
    ]

    assert Observations.reusable?(rows, document)
    refute Observations.reusable?(tl(rows), document)
    refute Observations.reusable?([hd(rows), hd(rows)], document)
    refute Observations.reusable?(["invalid", hd(rows)], document)
    refute Observations.reusable?([Map.put(hd(rows), "time", 2.0), List.last(rows)], document)
    refute Observations.reusable?([Map.put(hd(rows), "actions", nil), List.last(rows)], document)
  end

  defmodule Vision do
    def chat_json(system, _content, _opts) do
      send(self(), {:vision_instruction, system})

      {:ok,
       %{
         "observations" => [
           %{
             "frame" => 0,
             "setting" => "Desk",
             "people_and_objects" => [],
             "actions" => [],
             "visible_text" => ["23 matches"],
             "changes" => [],
             "uncertainties" => [],
             "text_elements" => [
               %{"text" => "23 matches", "role" => "interface", "prominence" => "incidental"}
             ]
           }
         ]
       }}
    end
  end

  test "visual interpretation receives nearby speech without treating speech as visual proof" do
    document = %{"stills" => [%{"key" => "image", "scene" => 0, "time" => 10.0}]}

    transcript = %{
      segments: [
        %{"start" => 8.0, "end" => 12.0, "text" => "Everyone can consult the archive."},
        %{"start" => 50.0, "end" => 54.0, "text" => "A later reveal."}
      ]
    }

    assert {:ok, [observation]} =
             Observations.collect(
               %{storage: Storage, bucket: "synthetic", region: nil},
               document,
               Vision,
               "en",
               transcript
             )

    assert_received {:vision_instruction, instruction}
    assert instruction =~ "Everyone can consult the archive"
    refute instruction =~ "A later reveal"
    assert observation["spoken_context"] == [hd(transcript.segments)]
    assert [%{"prominence" => "incidental", "role" => "interface"}] = observation["text_elements"]
    assert instruction =~ "never use spoken words as proof"
  end

  test "text prominence is retained and unsupported classifications are rejected" do
    batch = [{%{"time" => 3.0, "scene" => 0}, 7}]

    element = %{
      "text" => "Read more at example.org",
      "role" => "title_card",
      "prominence" => "primary"
    }

    assert {:ok, [anchored]} =
             Observations.anchor([Map.put(row(7), "text_elements", [element])], batch)

    assert anchored["text_elements"] == [element]

    assert {:error, _} =
             Observations.anchor(
               [Map.put(row(7), "text_elements", [%{element | "prominence" => "unknown"}])],
               batch
             )
  end

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
