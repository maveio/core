defmodule MaveCore.Transcription.SubtitleDocumentTest do
  use ExUnit.Case, async: true

  alias MaveCore.AudioDescription.DescriptionDocument
  alias MaveCore.Transcription.SubtitleDocument

  @vtt "WEBVTT\nLanguage: en\n\nNOTE Keep this\n\nintro\n00:00:01.000 --> 00:00:03.000 align:start\n<v Speaker>Hello &amp; welcome</v>\n\n00:04.000 --> 00:06.000\nSecond line\n"

  test "validates upload structure while accepting cue markup, metadata and alternate line endings" do
    for newline <- ["\n", "\r\n", "\r"] do
      assert :ok =
               SubtitleDocument.validate_upload("\uFEFF" <> String.replace(@vtt, "\n", newline))
    end

    for body <- [
          <<255>>,
          "plain text",
          "WEBVTTjunk",
          "WEBVTT\n\nNOTE only",
          @vtt <> <<0>>,
          @vtt <> "\ninvalid block",
          "WEBVTT\n\n00:03.000 --> 00:01.000\nCaption"
        ] do
      assert {:error, :invalid_vtt} = SubtitleDocument.validate_upload(body)
    end
  end

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

  test "inserting a subtitle splits its predecessor and preserves cue markup and settings" do
    {:ok, document} = SubtitleDocument.parse(@vtt)
    [first, second] = DescriptionDocument.from_vtt(document)
    new = %{"id" => "new", "start" => 2.5, "text" => "<new>"}
    assert {:ok, body} = SubtitleDocument.render_moments(document, [first, new, second], 12)
    assert body =~ "00:00:01.000 --> 00:00:02.500 align:start\n<v Speaker>Hello &amp; welcome</v>"
    assert body =~ "00:00:02.500 --> 00:00:04.000\n&lt;new&gt;"
    assert body =~ "00:04.000 --> 00:06.000\nSecond line"

    assert {:error, :invalid_time_labels} =
             SubtitleDocument.render_moments(document, [first, second, new], 12)

    assert {:ok, body} = SubtitleDocument.render_moments(document, [%{second | "start" => 8}], 12)
    assert body =~ "00:00:08.000 --> 00:00:10.000"
    refute body =~ "intro"
  end

  test "an edited subtitle end controls playback and its published interval" do
    {:ok, document} = SubtitleDocument.parse(@vtt)
    [first, second] = DescriptionDocument.from_vtt(document)
    edited = Map.put(first, "end", 2.125)
    assert [%{end: 2.125}, _] = SubtitleDocument.windows(document, [edited, second], 12)
    assert {:ok, body} = SubtitleDocument.render_moments(document, [edited, second], 12)
    assert body =~ "00:00:01.000 --> 00:00:02.125 align:start"

    for invalid <- [1, 0.5, 13, "invalid"] do
      assert {:error, :invalid_time_labels} =
               SubtitleDocument.render_moments(
                 document,
                 [Map.put(first, "end", invalid), second],
                 12
               )
    end
  end

  test "raw WebVTT edits require separated cues and valid video times" do
    assert {:ok, _, [_]} =
             SubtitleDocument.parse_editor_vtt(
               "WEBVTT\r\n\r\n00:01.000\t-->  00:02.000\r\nHello",
               10,
               :subtitle
             )

    for invalid <- [
          "WEBVTT\n\n00:00.000 --> 00:60.000\nHello",
          "WEBVTT\n\n00:01.000 --> 00:02.000\nFirst\n00:02.000 --> 00:03.000\nSecond",
          "WEBVTT\n00:01.000 --> 00:02.000\nFirst\n\n00:02.000 --> 00:03.000\nSecond",
          "WEBVTT\n\n00:04.000 --> 00:03.000\nHello",
          "WEBVTT\n\n00:04.000 --> 00:15.000\nHello"
        ] do
      assert {:error, :invalid_webvtt} = SubtitleDocument.parse_editor_vtt(invalid, 10, :subtitle)
    end
  end

  test "edited transcript JSON preserves word timings for unchanged cues" do
    {:ok, document} = SubtitleDocument.parse(@vtt)
    previous = Jason.decode!(SubtitleDocument.transcript_json(document, %{}))
    original = put_in(previous, ["segments", Access.at(0), "words", Access.at(0), "end"], 1.123)
    first = hd(original["segments"])

    {:ok, changed} =
      SubtitleDocument.parse(String.replace(@vtt, "Second line", "Different words"))

    json = Jason.decode!(SubtitleDocument.transcript_json(changed, original))

    assert [^first, %{"start" => 4.0, "end" => 6.0, "text" => "Different words"}] =
             json["segments"]

    assert json["text"] == "Hello & welcome Different words"
  end

  test "existing simultaneous subtitles remain editable" do
    source = String.replace(@vtt, "00:04.000", "00:01.000")
    {:ok, document} = SubtitleDocument.parse(source)
    moments = DescriptionDocument.from_vtt(document)
    assert {:ok, ^source} = SubtitleDocument.render_moments(document, moments, 12)
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
