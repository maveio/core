defmodule MaveCore.Transcription.SubtitleSourceTest do
  use ExUnit.Case, async: true
  alias MaveCore.Transcription.SubtitleSource

  test "VTT accepts BOM, CRLF, cue identifiers, settings and multiline text without losing timing" do
    vtt =
      "\uFEFFWEBVTT\r\n\r\nNOTE context\r\nignored\r\n\r\ncue-1\r\n00:00:01.125 --> 00:00:03.500 align:start\r\nFirst line\r\nSecond line\r\n\r\n00:04.000 --> 00:05.250\r\nLast line\r\n"

    assert {:ok, %{"segments" => [first, last]}} = SubtitleSource.parse(vtt)
    assert first == %{"start" => 1.125, "end" => 3.5, "text" => "First line\nSecond line"}
    assert last["start"] == 4.0
    assert last["end"] == 5.25
  end

  test "SRT accepts numbered cues with comma milliseconds" do
    srt = "\uFEFF1\r\n00:00:02,010 --> 00:00:04,250\r\nHello\r\nworld\r\n"

    assert {:ok, %{"segments" => [%{"start" => 2.01, "end" => 4.25, "text" => "Hello\nworld"}]}} =
             SubtitleSource.parse(srt)
  end

  test "existing transcription JSON retains segment times" do
    body = Jason.encode!(%{"segments" => [%{"start" => 1.0, "end" => 2.75, "text" => "Hallo"}]})

    assert {:ok, %{"text" => "Hallo", "segments" => [%{"start" => 1.0, "end" => 2.75}]}} =
             SubtitleSource.parse(body)
  end

  test "malformed, empty, oversized and backwards cues fail explicitly" do
    for body <- [
          "",
          "WEBVTT\n\n",
          "not subtitles",
          "1\n00:00:03,000 --> 00:00:01,000\nNo",
          "WEBVTT\n\n00:80.000 --> 00:81.000\nNo",
          "{\"segments\":[]}",
          <<255>>,
          String.duplicate("x", 5 * 1024 * 1024 + 1)
        ] do
      assert {:error, _} = SubtitleSource.parse(body)
    end
  end
end
