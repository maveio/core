defmodule MaveCore.Transcription.SubtitleDocumentTest do
  use ExUnit.Case, async: true

  alias MaveCore.Transcription.SubtitleDocument

  @vtt "WEBVTT\nLanguage: en\n\nNOTE Keep this\n\nintro\n00:00:01.000 --> 00:00:03.000 align:start\n<v Speaker>Hello &amp; welcome</v>\n\n00:04.000 --> 00:06.000\nSecond line\n"

  test "edits text without changing timestamps, cue identifiers or settings" do
    assert {:ok, document} = SubtitleDocument.parse(@vtt)

    assert Enum.map(SubtitleDocument.cues(document), & &1.start_seconds) == [1.0, 4.0]
    assert Enum.map(SubtitleDocument.cues(document), & &1.end_seconds) == [3.0, 6.0]

    assert Enum.map(SubtitleDocument.cues(document), & &1.time_range) == [
             "00:01 – 00:03",
             "00:04 – 00:06"
           ]

    assert %{"1" => "Hello & welcome", "2" => "Second line"} = SubtitleDocument.texts(document)

    texts = Map.put(SubtitleDocument.texts(document), "2", "Changed <text> & more")
    assert {:ok, result} = SubtitleDocument.render(document, texts)
    assert result == String.replace(@vtt, "Second line", "Changed &lt;text&gt; &amp; more")
  end

  test "unchanged cue markup survives a round trip" do
    assert {:ok, document} = SubtitleDocument.parse(@vtt)
    assert {:ok, @vtt} = SubtitleDocument.render(document, SubtitleDocument.texts(document))
  end

  test "line breaks cannot inject a new cue" do
    assert {:ok, document} = SubtitleDocument.parse(@vtt)

    texts =
      Map.put(SubtitleDocument.texts(document), "2", "Text\n\n00:07.000 --> 00:08.000\nMore")

    assert {:ok, result} = SubtitleDocument.render(document, texts)
    assert {:ok, reparsed} = SubtitleDocument.parse(result)
    assert length(SubtitleDocument.cues(reparsed)) == 2
    assert result =~ "--&gt;"
  end

  test "empty, missing and additional passages are rejected" do
    assert {:ok, document} = SubtitleDocument.parse(@vtt)
    texts = SubtitleDocument.texts(document)

    for invalid <- [
          Map.put(texts, "2", " "),
          Map.delete(texts, "1"),
          Map.put(texts, "9", "extra")
        ] do
      assert {:error, :invalid_text} = SubtitleDocument.render(document, invalid)
    end
  end

  test "invalid documents are rejected and Windows line endings are accepted" do
    for invalid <- ["", "not a VTT", "WEBVTT\n\nno timing", <<255>>] do
      assert {:error, :invalid_document} = SubtitleDocument.parse(invalid)
    end

    assert {:ok, _} = SubtitleDocument.parse("\uFEFF" <> String.replace(@vtt, "\n", "\r\n"))
  end
end
