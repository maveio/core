defmodule MaveCore.Transcription.VocabularyTest do
  use ExUnit.Case, async: true
  alias MaveCore.Transcription.Vocabulary

  test "matches whole terms within a segment and preserves their configured spelling" do
    assert ["KB", "Open Science"] ==
             Vocabulary.matching(["KB", "Open Science", "mave"], [
               "kb uses Open Science with a maven."
             ])

    assert [] == Vocabulary.matching(["Open Science"], ["Open", "Science"])
  end

  test "bounds the vocabulary and retains meaningful punctuation" do
    assert {:ok, ["C++", "AT&T"]} = Vocabulary.parse("C++\nAT&T")

    assert {:error, :invalid_vocabulary} =
             Vocabulary.parse(Enum.map_join(1..26, "\n", &"Name #{&1}"))

    assert {:error, :invalid_vocabulary} = Vocabulary.parse("<instruction>")
  end
end
