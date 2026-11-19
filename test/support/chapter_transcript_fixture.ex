defmodule MaveCore.TestSupport.ChapterTranscriptFixture do
  @moduledoc """
  A synthetic timed transcript with four clearly separate topics, for chapter
  tests. Every line lasts four seconds; a longer pause separates the topics.
  """

  @topics [
    {"garden",
     [
       "This video starts in the garden with the soil.",
       "Good soil is loose, so loosen the soil with a fork.",
       "Mix compost into the soil before you plant seeds.",
       "Plant the seeds in rows and cover the seeds lightly.",
       "Water the seeds every morning for a week.",
       "Seedlings need sun, so keep the garden bed open.",
       "Pull weeds from the soil before the weeds take over.",
       "That is how the garden bed gets ready for seeds."
     ]},
    {"bicycle",
     [
       "The bicycle is the second subject of this video.",
       "Check the tires and pump the tires until they are firm.",
       "A dry chain squeaks, so oil the chain link by link.",
       "Wipe the chain with a cloth after oiling the chain.",
       "Squeeze the brakes to test both brakes.",
       "Worn brake pads make the brakes weak.",
       "Tighten the saddle so the bicycle fits your height.",
       "Now the bicycle is safe with firm tires and brakes."
     ]},
    {"bread",
     [
       "Bread is what the kitchen part is about.",
       "Weigh the flour and add salt to the flour.",
       "Stir yeast into warm milk and pour it on the flour.",
       "Knead the dough until the dough feels smooth.",
       "Let the dough rise under a towel for an hour.",
       "Shape the dough into a loaf and heat the oven.",
       "Bake the loaf in the oven until the crust is brown.",
       "Fresh bread from the oven needs to cool on a rack."
     ]},
    {"camera",
     [
       "The camera closes this video with a few settings.",
       "Clean the lens, because dust on the lens shows in photos.",
       "A fast shutter freezes motion in bright light.",
       "A slow shutter needs a tripod under the camera.",
       "Open the lens wide when the light is low.",
       "Hold the camera steady and focus on the eyes.",
       "Review the photos on the camera screen afterwards.",
       "With lens, shutter and light set, the photos come out sharp."
     ]}
  ]

  @line_seconds 4.0
  @gap_seconds 0.3
  @topic_pause_seconds 1.6

  @doc "Topic names in order."
  def topics, do: Enum.map(@topics, &elem(&1, 0))

  @doc "Cues `%{start, end, text}` for the whole transcript."
  def cues do
    {cues, _time} =
      Enum.reduce(@topics, {[], 0.0}, fn {_topic, lines}, {cues, time} ->
        {topic_cues, time} =
          Enum.reduce(lines, {[], time}, fn line, {acc, time} ->
            cue = %{start: time, end: time + @line_seconds, text: line}
            {[cue | acc], time + @line_seconds + @gap_seconds}
          end)

        {cues ++ Enum.reverse(topic_cues), time - @gap_seconds + @topic_pause_seconds}
      end)

    Enum.map(cues, &%{&1 | start: Float.round(&1.start, 3), end: Float.round(&1.end, 3)})
  end

  @doc "Start time of every topic."
  def topic_starts do
    cues() |> Enum.take_every(8) |> Enum.map(& &1.start)
  end

  @doc "Length of the video the transcript belongs to."
  def duration, do: List.last(cues()).end + 1.0

  @doc "The transcript as a WebVTT document."
  def vtt do
    body =
      Enum.map_join(cues(), "\n\n", fn cue ->
        "#{timestamp(cue.start)} --> #{timestamp(cue.end)}\n#{cue.text}"
      end)

    "WEBVTT\n\n" <> body <> "\n"
  end

  @doc "The transcript as a stored transcription document."
  def json do
    Jason.encode!(%{
      "language" => "en",
      "segments" => Enum.map(cues(), &%{"start" => &1.start, "end" => &1.end, "text" => &1.text})
    })
  end

  defp timestamp(seconds) do
    millis = round(seconds * 1000)

    :io_lib.format("~2..0B:~2..0B:~2..0B.~3..0B", [
      div(millis, 3_600_000),
      millis |> rem(3_600_000) |> div(60_000),
      millis |> rem(60_000) |> div(1000),
      rem(millis, 1000)
    ])
    |> IO.iodata_to_binary()
  end
end
