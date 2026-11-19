defmodule MaveCore.Assets.SubtitleDocumentTest do
  use ExUnit.Case, async: true

  alias MaveCore.Assets.SubtitleDocument

  @vtt """
  WEBVTT - Harbour

  STYLE
  ::cue { color: white }

  1
  00:00:01.000 --> 00:00:04.000 line:80%
  Every morning, before the city wakes,

  NOTE checked by a human

  00:05.500 --> 00:08,000
  Fish &amp; chips &lt;3
  second line
  """

  defp document(body \\ @vtt) do
    {:ok, document} = SubtitleDocument.parse(body)
    document
  end

  defp texts(document), do: Enum.map(document.cues, & &1.text)

  describe "parse/1 and to_vtt/1" do
    test "reads cues, timestamps, settings and entities" do
      assert [first, second] = document().cues

      assert %{id: "c1", start: 1.0, end: 4.0, settings: "line:80%"} = first
      assert first.text == "Every morning, before the city wakes,"
      assert %{id: "c2", start: 5.5, end: 8.0, settings: ""} = second
      assert second.text == "Fish & chips <3\nsecond line"
    end

    test "keeps the header and style block and writes full timestamps" do
      assert SubtitleDocument.to_vtt(document()) == """
             WEBVTT - Harbour

             STYLE
             ::cue { color: white }

             00:00:01.000 --> 00:00:04.000 line:80%
             Every morning, before the city wakes,

             00:00:05.500 --> 00:00:08.000
             Fish &amp; chips &lt;3
             second line
             """
    end

    test "is stable once written" do
      written = SubtitleDocument.to_vtt(document())

      assert written |> document() |> SubtitleDocument.to_vtt() == written
    end

    test "keeps WebVTT tags and leaves out cues without text" do
      document =
        document()
        |> SubtitleDocument.put_text("c1", "<i>Quiet</i> & <v Marit>early")
        |> SubtitleDocument.put_text("c2", "  \n ")

      written = SubtitleDocument.to_vtt(document)

      assert written =~ "<i>Quiet</i> &amp; <v Marit>early"
      refute written =~ "00:00:05.500"
    end

    test "tidies spacing and blank lines when writing" do
      document = SubtitleDocument.put_text(document(), "c1", " two   spaces \n\n next ")

      assert SubtitleDocument.to_vtt(document) =~ "line:80%\ntwo spaces\nnext\n"
    end

    test "rejects anything that is not WebVTT" do
      assert SubtitleDocument.parse("1\n00:00:01,000 --> 00:00:02,000\nHi\n") ==
               {:error, :invalid_webvtt}

      assert SubtitleDocument.parse(<<255, 254>>) == {:error, :invalid_webvtt}
      assert SubtitleDocument.parse(nil) == {:error, :invalid_webvtt}
    end
  end

  describe "editing" do
    test "split divides text at the caret and time in proportion" do
      document = SubtitleDocument.put_text(document(), "c1", "one two")

      assert {document, "c3"} = SubtitleDocument.split(document, "c1", 3)
      assert [first, second, _] = document.cues
      assert {first.text, first.start, first.end} == {"one", 1.0, 2.286}
      assert {second.id, second.text, second.start, second.end} == {"c3", "two", 2.286, 4.0}
      assert second.settings == "line:80%"
    end

    test "merging joins text and time and reports where the texts meet" do
      assert {document, "c1", 38} = SubtitleDocument.merge_with_next(document(), "c1")

      assert [%{id: "c1", start: 1.0, end: 8.0, text: text}] = document.cues
      assert text == "Every morning, before the city wakes, Fish & chips <3\nsecond line"

      assert {^document, "c1", 38} = SubtitleDocument.merge_with_previous(document(), "c2")
    end

    test "merging at either end changes nothing" do
      document = document()

      assert SubtitleDocument.merge_with_next(document, "c2") == {document, nil, 0}
      assert SubtitleDocument.merge_with_previous(document, "c1") == {document, nil, 0}
    end

    test "a new cue takes the silence that follows" do
      assert {document, "c3"} = SubtitleDocument.insert_after(document(), "c1")

      assert [_, %{id: "c3", start: 4.0, end: 5.5, text: ""}, _] = document.cues
    end

    test "a new cue takes half of the previous cue when there is no silence" do
      document = SubtitleDocument.put_timing(document(), "c1", 1.0, 5.5)

      assert {document, "c3"} = SubtitleDocument.insert_after(document, "c1")
      assert [%{end: 3.25}, %{id: "c3", start: 3.25, end: 5.5}, _] = document.cues
    end

    test "a new cue after the last one stays inside the video" do
      assert {document, "c3"} = SubtitleDocument.insert_after(document(), "c2", 9.0)

      assert %{start: 8.0, end: 9.0} = SubtitleDocument.cue(document, "c3")
    end

    test "timing stays inside the video, keeps a minimum length and keeps cues ordered" do
      document = SubtitleDocument.put_timing(document(), "c1", -2, 0, 20.0)
      assert %{start: +0.0, end: 0.1} = SubtitleDocument.cue(document, "c1")

      document = SubtitleDocument.put_timing(document, "c1", 19.99, 30, 20.0)
      assert %{start: 19.9, end: 20.0} = SubtitleDocument.cue(document, "c1")
      assert Enum.map(document.cues, & &1.id) == ["c2", "c1"]
    end

    test "deleting returns a neighbour to move to" do
      assert {document, "c2"} = SubtitleDocument.delete(document(), "c1")
      assert texts(document) == ["Fish & chips <3\nsecond line"]

      assert {document, nil} = SubtitleDocument.delete(document, "c2")
      assert document.cues == []
    end
  end

  describe "issues/1" do
    test "flags long lines, extra lines, fast reading, overlap and missing text" do
      document =
        """
        WEBVTT

        00:00:00.000 --> 00:00:10.000
        What isn't sold at the quay goes to the smokehouse two streets away,

        00:00:10.000 --> 00:00:20.000
        one
        two
        three

        00:00:20.000 --> 00:00:21.000
        This is far too much to read in a second

        00:00:20.500 --> 00:00:25.000
        Overlapping

        00:00:26.000 --> 00:00:28.000
        <i>Fine</i>
        """
        |> document()
        |> SubtitleDocument.put_text("c5", "<i> </i>")

      assert SubtitleDocument.issues(document) == %{
               "c1" => [line_length: 68],
               "c2" => [lines: 3],
               "c3" => [reading_speed: 40],
               "c4" => [:overlap],
               "c5" => [:empty]
             }
    end

    test "reading counts visible characters only" do
      cue = %{start: 0.0, end: 2.0, text: "<i>Fine</i>\n& well"}

      assert SubtitleDocument.reading(cue) == %{lines: [4, 6], speed: 5}
    end
  end
end
