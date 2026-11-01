defmodule MaveCore.AudioDescription.TimelineTest do
  use ExUnit.Case, async: true

  alias MaveCore.AudioDescription.Timeline

  # 1 sample = 1 ms keeps the numbers readable.
  @sr 1000

  defp i(start, stop), do: %{start: start * 1.0, end: stop * 1.0}

  describe "speech_from_words/2" do
    test "merges close words, pads and clamps" do
      speech =
        Timeline.speech_from_words(
          [i(0.72, 1.28), i(1.28, 2.68), i(4.82, 5.38), i(5.6, 6.68), i(9.9, 10.4)],
          10
        )

      assert speech == [i(0.57, 2.83), i(4.67, 6.83), i(9.75, 10)]
    end

    test "returns nothing for silence" do
      assert Timeline.speech_from_words([], 30) == []
    end
  end

  describe "free_gaps/2" do
    test "returns the pauses between speech" do
      assert Timeline.free_gaps([i(2, 4), i(6, 7)], 10) == [i(0, 2), i(4, 6), i(7, 10)]
    end

    test "is the whole video without speech, and empty when speech never stops" do
      assert Timeline.free_gaps([], 30) == [i(0, 30)]
      assert Timeline.free_gaps([i(0, 30)], 30) == []
    end
  end

  describe "plan_timeline/5" do
    @speech [%{start: 2.0, end: 4.0}, %{start: 6.0, end: 9.0}]

    test "keeps a description that fits its pause, without ducking" do
      t = Timeline.plan_timeline([cue(0.5, 1.5, "A door opens.")], [1200], @speech, 10, @sr)

      assert t.placements == [%{index: 0, start: 500, length: 1200}]
      assert t.cues == [cue(0.5, 1.7, "A door opens.")]
      assert t.ducks == []
      assert t.total_samples == 10_000
    end

    test "moves a description into a nearby pause when the whole clip fits there" do
      t = Timeline.plan_timeline([cue(3.5, 5, "She sits down.")], [1500], @speech, 10, @sr)

      assert hd(t.cues) == cue(4, 5.5, "She sits down.")
      assert t.ducks == []
    end

    test "plays over speech and ducks when no pause fits" do
      t = Timeline.plan_timeline([cue(6.5, 9, "Long description.")], [3000], @speech, 10, @sr)

      assert hd(t.cues) == cue(6.5, 9.5, "Long description.")
      assert t.ducks == [i(6.5, 9.5)]
    end

    test "never overlaps two descriptions and keeps the clip inside the video" do
      t =
        Timeline.plan_timeline(
          [cue(0, 1, "a"), cue(0.5, 1, "b"), cue(9.5, 10, "c")],
          [1500, 1000, 2000],
          [],
          10,
          @sr
        )

      assert Enum.map(t.cues, &{&1.start, &1.end}) == [{0.0, 1.5}, {1.65, 2.65}, {8.0, 10.0}]
      assert t.ducks == []
    end

    test "skips descriptions without speech audio" do
      t = Timeline.plan_timeline([cue(1, 2, "a")], [0], [], 10, @sr)
      assert t.placements == []
      assert t.cues == []
    end
  end

  describe "plan_timeline/5 with scenes" do
    @speech [
      %{start: 4.35, end: 8.91},
      %{start: 9.43, end: 10.41},
      %{start: 11.97, end: 15.59}
    ]
    @lawn %{start: 7.88, end: 10.24}

    test "never moves a description into a pause after its scene has ended" do
      t =
        Timeline.plan_timeline(
          [Map.put(cue(8, 9.5, "An un-mowed lawn."), :scene, @lawn)],
          [1600],
          @speech,
          27,
          @sr
        )

      assert hd(t.cues).start == 8.0
      assert t.ducks == [i(8, 9.6)]
    end

    test "uses a pause inside the scene when the clip fits there" do
      scene = %{start: 10.24, end: 13.28}
      t = Timeline.plan_timeline([cue(11.5, 12.5, "A messy attic.")], [1200], @speech, 27, @sr)
      assert hd(t.cues) == cue(10.77, 11.97, "A messy attic.")

      in_scene =
        Timeline.plan_timeline(
          [Map.put(cue(10.3, 12, "A messy attic."), :scene, scene)],
          [1200],
          @speech,
          27,
          @sr
        )

      assert hd(in_scene.cues).start >= scene.start
      assert in_scene.ducks == []
    end

    test "skips a description that earlier long ones pushed out of its scene" do
      t =
        Timeline.plan_timeline(
          [
            Map.put(cue(0, 2, "A very long first description."), :scene, i(0, 3)),
            Map.put(cue(3, 4, "Second shot."), :scene, i(3, 4)),
            Map.put(cue(4, 9, "Third shot."), :scene, i(4, 10))
          ],
          [5000, 1000, 1000],
          [],
          10,
          @sr
        )

      assert t.skipped == [1]
      assert Enum.map(t.cues, & &1.text) == ["A very long first description.", "Third shot."]
      assert Enum.at(t.cues, 1).start == 5.15
    end

    test "speaks at least half of the clip during its scene" do
      t =
        Timeline.plan_timeline([Map.put(cue(1.8, 2, "a"), :scene, i(0, 2))], [1000], [], 10, @sr)

      assert hd(t.cues).start <= 1.5
    end
  end

  test "shots_from_cuts/2 turns cut times into shot intervals" do
    assert Timeline.shots_from_cuts([5.28, 7.88, 30], 10) == [
             i(0, 5.28),
             i(5.28, 7.88),
             i(7.88, 10)
           ]

    assert Timeline.shots_from_cuts([], 10) == [i(0, 10)]
  end

  describe "timing_prompt/4" do
    test "lists numbered scenes, speech and numbered pauses with word budgets" do
      assert Timeline.timing_prompt([i(1, 3)], [i(0, 2), i(2, 5)], 5) ==
               Enum.join(
                 [
                   "Scenes (index: seconds), from cut detection; quick cuts are grouped into one scene:",
                   "S0: 0.00-2.00",
                   "S1: 2.00-5.00",
                   "Speech (seconds): 1.00-3.00",
                   "Pauses without speech (index: seconds, length, max words):",
                   "P0: 0.00-1.00 (1.0 s, max 2 words)",
                   "P1: 3.00-5.00 (2.0 s, max 4 words)"
                 ],
                 "\n"
               )
    end

    test "budgets about 2.5 words per second with a small margin" do
      assert Timeline.word_budget(0.5) == 0
      assert Timeline.word_budget(1.5) == 3
      assert Timeline.word_budget(4) == 9
    end

    test "with a window lists only overlapping scenes and pauses, with their global numbers" do
      scenes = [i(0, 5), i(5, 10), i(10, 15)]
      speech = [i(1, 4), i(6, 9), i(11, 14)]
      text = Timeline.timing_prompt(speech, scenes, 15, i(5, 10))

      assert text =~ "S1: 5.00-10.00"
      refute text =~ "S0:"
      refute text =~ "S2:"
      assert text =~ "P1: 4.00-6.00"
      assert text =~ "P2: 9.00-11.00"
      refute text =~ "P0:"
      assert text =~ "Speech (seconds): 6.00-9.00"
    end
  end

  describe "snap_cues/3" do
    @gaps [%{start: 0.0, end: 0.5}, %{start: 2.8, end: 4.4}, %{start: 10.4, end: 12.0}]
    @scenes [%{start: 0.0, end: 5.0}, %{start: 7.9, end: 10.2}, %{start: 10.2, end: 13.0}]

    test "moves a cue into its pause when the pause overlaps its scene" do
      assert Timeline.snap_cues(
               [%{start: 1.07, end: 2.5, text: "Kitchen.", pause: 1, scene: 0}],
               @gaps,
               @scenes
             ) == [%{start: 2.8, end: 3.3, text: "Kitchen.", scene: i(0, 5)}]
    end

    test "ignores a pause outside the scene, so the description stays in sync" do
      [cue] =
        Timeline.snap_cues(
          [%{start: 10.42, end: 11.9, text: "A lawn.", pause: 2, scene: 1}],
          @gaps,
          @scenes
        )

      assert cue.start < 10.2
      assert cue.start >= 7.9
      assert cue.scene == i(7.9, 10.2)
    end

    test "finds the scene from the start time when the model gave none" do
      assert Timeline.snap_cues(
               [%{start: 8.5, end: 9.5, text: "x", pause: -1, scene: nil}],
               @gaps,
               @scenes
             ) == [%{start: 8.5, end: 9.5, text: "x", scene: i(7.9, 10.2)}]
    end
  end

  describe "plan_stills/4" do
    test "takes at least one still per shot and one per ~3 s in longer shots, never on a cut" do
      assert Timeline.plan_stills([i(0, 1), i(1, 10)], 10) == [
               %{scene: 0, time: 0.5},
               %{scene: 1, time: 2.5},
               %{scene: 1, time: 5.5},
               %{scene: 1, time: 8.5}
             ]
    end

    test "covers a video without cuts as one shot" do
      assert Timeline.plan_stills([], 6) == [%{scene: 0, time: 1.5}, %{scene: 0, time: 4.5}]
    end

    test "batches stills to the provider's image limit, in order" do
      stills = Timeline.plan_stills([i(0, 75)], 75)
      batches = Timeline.batch_stills(stills, 12)

      assert Enum.map(batches, &length/1) == [12, 12, 1]
      assert List.flatten(batches) == stills
    end

    test "takes a still from every cut, labelled with its scene" do
      cuts = [i(0, 1.2), i(1.2, 2.4), i(2.4, 3.6)]
      scenes = Timeline.scenes_from_shots(cuts)

      assert Timeline.plan_stills(scenes, 3.6, 3, cuts) == [
               %{scene: 0, time: 0.6},
               %{scene: 0, time: 1.8},
               %{scene: 0, time: 3.0}
             ]
    end
  end

  describe "scenes_from_shots/2" do
    test "groups quick cuts into scenes of at least 3 s and keeps long shots as they are" do
      cuts = [i(0, 1.3), i(1.3, 2.6), i(2.6, 3.9), i(3.9, 10), i(10, 11.2)]
      assert Timeline.scenes_from_shots(cuts) == [i(0, 3.9), i(3.9, 11.2)]
    end

    test "keeps a single short video as one scene" do
      assert Timeline.scenes_from_shots([i(0, 2)]) == [i(0, 2)]
      assert Timeline.scenes_from_shots([]) == []
    end
  end

  defp cue(start, stop, text), do: %{start: start * 1.0, end: stop * 1.0, text: text}
end
