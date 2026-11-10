defmodule MaveCore.AudioDescription.SpeechTimingTest do
  use ExUnit.Case, async: true
  alias MaveCore.AudioDescription.SpeechTiming

  defp seconds(text), do: SpeechTiming.estimate(text, "nl")["estimated_seconds"]

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
