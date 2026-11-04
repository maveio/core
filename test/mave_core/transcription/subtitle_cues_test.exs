defmodule MaveCore.Transcription.SubtitleCuesTest do
  use ExUnit.Case, async: true

  alias MaveCore.Transcription.SubtitleCues

  @text "Welkom bij deze korte rondleiding. We laten zien hoe je een video toevoegt, ondertitels maakt en het resultaat met anderen deelt. Daarna kun je rustig verder kijken."

  test "splits long segments into bounded cues without losing text" do
    cues = SubtitleCues.build([%{start: 2.0, end: 14.0, text: @text}])
    assert length(cues) >= 3
    assert flatten(cues) == @text
    assert hd(cues).start == 2.0
    assert List.last(cues).end == 14.0
    assert Enum.all?(cues, &(&1.end > &1.start and &1.end - &1.start <= 7.0))
    assert_layout(cues)

    for [left, right] <- Enum.chunk_every(cues, 2, 1, :discard) do
      assert_in_delta left.end, right.start, 0.0001
    end
  end

  test "keeps short segments and silence between source segments" do
    cues =
      SubtitleCues.build([
        %{"start" => "1.25", "end" => "2.5", "text" => "Hello world."},
        %{start: 5, end: 6, text: "Another sentence."}
      ])

    assert [
             %{start: 1.25, end: 2.5, text: "Hello world."},
             %{start: 5.0, end: 6.0, text: "Another sentence."}
           ] = cues
  end

  test "plain text fallback uses the same cue layout" do
    assert SubtitleCues.from_text(@text, 12.0) ==
             SubtitleCues.build([%{start: 0, end: 12, text: @text}])
  end

  test "dense speech keeps every word inside the original timing envelope" do
    cues = SubtitleCues.from_text(@text, 1.0)
    assert flatten(cues) == @text
    assert hd(cues).start == 0.0
    assert List.last(cues).end == 1.0
    assert Enum.all?(cues, &(&1.start >= 0 and &1.end <= 1 and &1.end > &1.start))
    assert_layout(cues)
  end

  test "punctuation provides a natural cue boundary" do
    [first | _] = SubtitleCues.from_text(@text, 12.0)
    assert first.text == "Welkom bij deze korte rondleiding."
  end

  test "JSON and VTT carry the same cues and bounded estimated word times" do
    cues = SubtitleCues.from_text(@text, 12.0)
    json = SubtitleCues.json_segments(cues)
    assert {:ok, vtt} = SubtitleCues.to_vtt(cues)

    for {cue, segment} <- Enum.zip(cues, json) do
      assert segment["text"] == cue.text
      assert vtt =~ "\n#{cue.text}\n\n"

      for word <- segment["words"] do
        assert word["start"] >= Float.round(cue.start, 3)
        assert word["end"] <= Float.round(cue.end, 3)
      end
    end
  end

  test "handles Unicode, line breaks, blank segments and long unbroken tokens" do
    text = String.duplicate("é", 100)
    cues = SubtitleCues.build([nil, %{}, %{text: "  \n "}, %{text: text, start: -1, end: 5}])
    assert cues |> flatten() |> String.replace(" ", "") == text
    assert Enum.all?(cues, &(&1.start >= 0))
    assert_layout(cues)
    assert {:error, :empty_subtitle_segments} = SubtitleCues.to_vtt([])
  end

  test "preserves real word timings, including unequal lengths and pauses" do
    words = [
      %{word: "Hello", start: 0.1254, end: 0.4},
      %{word: "there.", start: 0.5, end: 1.1},
      %{word: "After", start: 2.7, end: 3.0},
      %{word: "a", start: 3.05, end: 3.1},
      %{word: "pause.", start: 3.15, end: 4.2}
    ]

    cues = SubtitleCues.from_transcription(%{text: "Hello there. After a pause.", words: words})
    assert [%{start: 0.1254, end: 1.1}, %{start: 2.7, end: 4.2}] = cues
    assert_layout(cues)
    encoded_words = cues |> SubtitleCues.json_segments() |> Enum.flat_map(& &1["words"])

    assert encoded_words ==
             Enum.map(words, fn word ->
               %{"word" => word.word, "start" => word.start, "end" => word.end}
             end)
  end

  test "incomplete or unordered provider words fall back without losing transcript text" do
    segment = %{text: "Hello there.", start: 0.0, end: 3.0}

    for words <- [
          [%{word: "Hello", start: 0.0, end: 1.0}],
          [%{word: "Hello", start: 1.0, end: 2.0}, %{word: "there.", start: 0.0, end: 1.0}],
          [%{word: "Hello", start: nil, end: 1.0}, %{word: "there.", start: 1.0, end: 3.0}]
        ] do
      cues =
        SubtitleCues.from_transcription(%{text: segment.text, segments: [segment], words: words})

      assert cues == SubtitleCues.build([segment])
    end
  end

  test "groups a long word-timed transcript into readable cues and preserves all word data" do
    words =
      for index <- 0..49 do
        %{word: "example", start: index * 0.4, end: index * 0.4 + 0.2}
      end

    text = Enum.map_join(words, " ", & &1.word)
    cues = SubtitleCues.from_transcription(%{text: text, words: words})
    assert_layout(cues)
    assert flatten(cues) == text
    assert Enum.flat_map(cues, & &1.words) == words
    assert Enum.all?(cues, &(&1.end - &1.start <= 7))
  end

  test "short speech remains readable during following silence without changing word times" do
    word = %{word: "Hello.", start: 1.0, end: 1.1}
    cues = SubtitleCues.from_transcription(%{text: "Hello.", words: [word]}, 4.0)
    assert [cue] = cues
    assert_in_delta cue.end, 1.0 + 5 / 6, 0.001
    assert cue.words == [word]
  end

  test "reading holds stop before the next cue and the end of the video" do
    words = [
      %{word: "Hello.", start: 0.0, end: 0.1},
      %{word: "Goodbye.", start: 1.2, end: 1.3}
    ]

    cues = SubtitleCues.from_transcription(%{text: "Hello. Goodbye.", words: words}, 1.6)
    assert [first, last] = cues
    assert first.end < last.start
    assert last.end == 1.6
    assert Enum.flat_map(cues, & &1.words) == words
  end

  defp assert_layout(cues) do
    for cue <- cues do
      lines = String.split(cue.text, "\n")
      assert length(lines) <= 2
      assert Enum.all?(lines, &(String.length(&1) <= 42))
    end
  end

  defp flatten(cues) do
    cues |> Enum.map_join(" ", & &1.text) |> String.replace(~r/\s+/u, " ")
  end
end
