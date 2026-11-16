defmodule MaveCore.Search.DocumentTest do
  use ExUnit.Case, async: true

  alias MaveCore.Search.Document

  defp observation(time, attrs) do
    Map.merge(
      %{
        "id" => round(time * 10),
        "time" => time,
        "scene" => 0,
        "setting" => "",
        "people_and_objects" => [],
        "actions" => [],
        "visible_text" => [],
        "text_elements" => [],
        "changes" => [],
        "uncertainties" => []
      },
      attrs
    )
  end

  test "a frame becomes a moment that lasts until the next sampled frame" do
    observations = [
      observation(0.1, %{"setting" => "A kitchen", "actions" => ["A cook whisks eggs."]}),
      observation(2.0, %{
        "setting" => "A kitchen",
        "people_and_objects" => ["A cook", "a frying pan"],
        "visible_text" => ["Step 2: fry"],
        "uncertainties" => ["The label on the jar is unreadable"]
      })
    ]

    assert [
             %{source: "visual", start: 0.1, end: 2.0, text: "A kitchen. A cook whisks eggs."},
             %{
               source: "visual",
               start: 2.0,
               end: 6.0,
               text: "A kitchen. A cook, a frying pan. On screen: Step 2: fry"
             }
           ] = Document.visual_moments(observations, 6.0)
  end

  test "consecutive frames with the same description share one moment" do
    still = %{"setting" => "A title card", "visible_text" => ["Welcome"]}

    assert [%{start: +0.0, end: 4.0}, %{start: 4.0, end: 5.0}] =
             Document.visual_moments(
               [
                 observation(0.0, still),
                 observation(2.0, still),
                 observation(4.0, %{"setting" => "A beach"})
               ],
               5.0
             )
  end

  test "burned-in subtitles are left to the transcript and empty frames are dropped" do
    observations = [
      observation(1.0, %{
        "setting" => "An office",
        "visible_text" => ["we ship on friday", "ACME"],
        "text_elements" => [
          %{"text" => "we ship on friday", "role" => "subtitle", "prominence" => "secondary"},
          %{"text" => "ACME", "role" => "background", "prominence" => "incidental"}
        ]
      }),
      observation(3.0, %{})
    ]

    assert [%{text: "An office. On screen: ACME"}] = Document.visual_moments(observations, 4.0)
  end

  test "short transcript cues are grouped into one moment, split on pauses" do
    segments = [
      %{"start" => 0.0, "end" => 1.5, "text" => "Welcome to"},
      %{"start" => 1.5, "end" => 3.0, "text" => " the harbour tour."},
      %{"start" => 9.0, "end" => 10.0, "text" => "Look left."},
      %{"start" => 10.0, "end" => 10.0, "text" => "  "},
      %{"start" => "soon", "end" => 12.0, "text" => "ignored"}
    ]

    assert [
             %{source: "transcript", start: +0.0, end: 3.0, text: "Welcome to the harbour tour."},
             %{source: "transcript", start: 9.0, end: 10.0, text: "Look left."}
           ] = Document.transcript_moments(segments)
  end

  test "reads cues from a WebVTT transcript" do
    vtt = """
    WEBVTT

    1
    00:00:01.000 --> 00:00:02.500 align:start
    <v Sam>Hello there,</v>
    second line

    NOTE a comment

    00:01:00.000 --> 00:01:02.000
    Goodbye.
    """

    assert [
             %{"start" => 1.0, "end" => 2.5, "text" => "Hello there, second line"},
             %{"start" => 60.0, "end" => 62.0, "text" => "Goodbye."}
           ] = Document.vtt_segments(vtt)
  end

  test "a stored document round-trips and rejects other shapes" do
    moments = [%{source: "visual", start: 1.0, end: 2.0, text: "A red door."}]
    json = moments |> Document.to_json("en") |> Jason.encode!() |> Jason.decode!()

    assert {:ok, ^moments, "en"} = Document.from_json(json)

    assert {:ok, [], nil} =
             Document.from_json(%{
               "schema_version" => 1,
               "moments" => [%{"source" => "other", "start" => 0, "end" => 1, "text" => "x"}]
             })

    assert {:error, :invalid_document} = Document.from_json(%{"moments" => []})
  end
end
