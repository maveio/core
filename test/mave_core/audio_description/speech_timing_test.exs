defmodule MaveCore.AudioDescription.SpeechTimingTest do
  use ExUnit.Case, async: true
  alias MaveCore.AudioDescription.SpeechTiming

  defp seconds(text), do: SpeechTiming.estimate(text, "nl")["estimated_seconds"]

  test "unchanged text uses the existing timing even when a generic estimate is too long" do
    original = "Wetenschappelijke toegankelijkheidsinformatie."
    assert seconds(original) > 1.0
    assert SpeechTiming.estimate_edit(original, original, 1.0, "nl") == 1.0
  end

  test "edits are estimated relative to the published text and timing" do
    original = "Een blauwe lucht."
    longer = "Een blauwe lucht met witte wolken boven een groot veld."
    assert SpeechTiming.estimate_edit(longer, original, 2.0, "nl") > 2.0
    assert SpeechTiming.estimate_edit("Lucht.", original, 2.0, "nl") < 2.0
    assert SpeechTiming.estimate_edit("", original, 2.0, "nl") == 0.0
  end

  test "time labels in progress do not count as spoken text" do
    original = "Een vliegtuig vliegt over."

    for label <- ["[", "[00", "[00:", "[00:40", "[00:40]", "[00:40.550]"] do
      assert SpeechTiming.estimate_edit(original <> " " <> label, original, 2.0, "nl") == 2.0
      assert SpeechTiming.editor_spoken_text(label) == ""
    end

    assert SpeechTiming.editor_spoken_text("In [2024] gebeurde dit.") == "In [2024] gebeurde dit."
  end

  test "complex words take longer than short words with the same word count" do
    assert seconds("Wetenschappelijke toegankelijkheid") > seconds("Een deur")
  end

  test "uses the spoken Dutch URL form rather than treating a URL as one word" do
    assert seconds("example.org/onderzoek") > seconds("website") * 2
  end

  test "accounts for numeric groups, abbreviations and punctuation" do
    assert seconds("123456789") > seconds("1")
    assert seconds("API") > seconds("map")
    assert seconds("Een deur, een raam.") > seconds("Een deur een raam")
  end

  test "labels its result as a prediction without claiming an actual recording" do
    estimate = SpeechTiming.estimate("Een deur gaat open.", "nl")
    assert estimate["duration_source"] == "heuristic_estimate"
    assert estimate["estimated_seconds"] > 0
    refute Map.has_key?(estimate, "measured_seconds")
  end
end
