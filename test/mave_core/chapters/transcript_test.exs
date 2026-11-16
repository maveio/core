defmodule MaveCore.Chapters.TranscriptTest do
  use ExUnit.Case, async: true

  alias MaveCore.Chapters.Transcript

  test "reads cues from a WebVTT document and ignores notes, settings and markup" do
    vtt = """
    WEBVTT

    NOTE made for a test

    intro
    00:00:01.000 --> 00:00:03.500 line:90% align:center
    <v Speaker>Hello <i>there</i>.
    and welcome

    01:02.250 --> 01:04.000
    Second line

    00:00:10.000 --> broken
    Skipped
    """

    assert [
             %{start: 1.0, end: 3.5, text: "Hello there. and welcome"},
             %{start: 62.25, end: 64.0, text: "Second line"}
           ] = Transcript.from_vtt(vtt)
  end

  test "reads cues from a stored transcription document" do
    json =
      Jason.encode!(%{
        "segments" => [
          %{"start" => 4, "end" => 6, "text" => " Second "},
          %{"start" => 0.5, "end" => 2.0, "text" => "First"},
          %{"start" => 7, "text" => ""},
          %{"text" => "No time"}
        ]
      })

    assert [%{start: 0.5, end: 2.0, text: "First"}, %{start: 4.0, end: 6.0, text: "Second"}] =
             Transcript.from_json(json)
  end

  test "returns no cues for anything else" do
    assert Transcript.from_json("not json") == []
    assert Transcript.from_json(%{"text" => "no segments"}) == []
    assert Transcript.from_vtt(nil) == []
  end

  test "counts words" do
    assert Transcript.word_count([%{text: "one two"}, %{text: "three"}]) == 3
  end
end
