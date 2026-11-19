defmodule MaveCore.Chapters.SuggesterTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias MaveCore.Chapters.{LocalWriter, Suggester}
  alias MaveCore.TestSupport.ChapterTranscriptFixture, as: Fixture

  defmodule FixedWriter do
    @behaviour MaveCore.Chapters.Writer

    @impl true
    def suggest(_input, _opts) do
      {:ok,
       [
         %{start: 3.0, title: "1. Opening."},
         %{start: 36.4, title: ~s("Bikes")},
         %{start: 40.0, title: "Too close to the previous one"},
         %{start: 72.2, title: "Baking\nbread"},
         %{start: 139.0, title: "A tail that is too short"},
         %{start: 500.0, title: "After the end"},
         %{start: 90.0, title: " "}
       ]}
    end
  end

  defmodule FailingWriter do
    @behaviour MaveCore.Chapters.Writer

    @impl true
    def suggest(_input, _opts), do: {:error, {:http_error, 500}}
  end

  defp suggest(opts) do
    Suggester.suggest(
      Keyword.merge(
        [cues: Fixture.cues(), duration: Fixture.duration(), language: "en", writer: LocalWriter],
        opts
      )
    )
  end

  describe "with the local writer" do
    test "starts a chapter at every topic change and titles it with the topic's words" do
      assert {:ok, %{chapters: chapters, generator: "local", inputs: ["transcript"]}} =
               suggest([])

      assert Enum.map(chapters, & &1["start"]) == Fixture.topic_starts()

      assert Enum.map(chapters, & &1["title"]) == [
               "Garden, soil, seeds",
               "Bicycle, chain, brakes",
               "Flour, dough, oven",
               "Camera, lens, photos"
             ]
    end

    test "finds the same chapters without a stop list for the language" do
      assert {:ok, %{chapters: chapters}} = suggest(language: "xx")
      assert Enum.map(chapters, & &1["start"]) == Fixture.topic_starts()
    end

    test "starts a chapter on a scene cut just before its first line" do
      cuts = Fixture.topic_starts() |> tl() |> Enum.map(&Float.round(&1 - 0.8, 3))

      assert {:ok, %{chapters: chapters, inputs: ["transcript", "scenes"]}} = suggest(cuts: cuts)
      assert Enum.map(chapters, & &1["start"]) == [0.0 | cuts]
    end

    test "does not move a chapter to a scene cut after its first line" do
      cuts = Fixture.topic_starts() |> tl() |> Enum.map(&Float.round(&1 + 1.2, 3))

      assert {:ok, %{chapters: chapters}} = suggest(cuts: cuts)
      assert Enum.map(chapters, & &1["start"]) == Fixture.topic_starts()
    end

    test "suggests nothing when the same words are used throughout" do
      vocabulary =
        ~w(river bridge water stone boat rope sail wind harbor dock anchor tide wave shore sand
           shell gull net fish crab salt rock reef storm)

      cues =
        for line <- 0..29 do
          words =
            for word <- 0..6, do: Enum.at(vocabulary, rem(line * 7 + word * 5 + div(line, 3), 24))

          %{start: line * 4.3, end: line * 4.3 + 4.0, text: Enum.join(words, " ") <> "."}
        end

      assert suggest(cues: cues, duration: 130.0) == {:error, :no_topic_changes}
    end
  end

  test "needs a transcript with enough words and a video that is long enough" do
    assert suggest(cues: []) == {:error, :no_transcript}
    assert suggest(cues: Enum.take(Fixture.cues(), 2)) == {:error, :too_short}
    assert suggest(duration: 45.0) == {:error, :too_short}
  end

  test "tidies what a writer proposes" do
    assert {:ok, %{chapters: chapters, generator: "fixed_writer"}} = suggest(writer: FixedWriter)

    # The first chapter starts at zero, starts move to the nearest line, and
    # chapters that would be too short, untitled or outside the video are dropped.
    assert chapters == [
             %{"start" => 0.0, "title" => "Opening"},
             %{"start" => 35.7, "title" => "Bikes"},
             %{"start" => 71.4, "title" => "Baking bread"}
           ]
  end

  test "falls back to the local writer when the writer fails" do
    log =
      capture_log(fn ->
        assert {:ok, %{generator: "local", chapters: [_, _ | _]}} = suggest(writer: FailingWriter)
      end)

    assert log =~ "using the local writer"
  end

  test "scales the number and length of chapters with the video" do
    assert Suggester.max_chapters(60) == 3
    assert Suggester.max_chapters(150) == 5
    assert Suggester.max_chapters(3600) == 16
    assert Suggester.max_chapters(86_400) == 24

    assert Suggester.min_chapter_seconds(60) == 15.0
    assert Suggester.min_chapter_seconds(1000) == 40.0
    assert Suggester.min_chapter_seconds(86_400) == 90.0
  end

  test "cleans titles" do
    assert Suggester.clean_title("  Chapter 2: Getting   started. ") == "Getting started"
    assert Suggester.clean_title("“Quoted”") == "Quoted"
    assert Suggester.clean_title(nil) == ""
    assert String.length(Suggester.clean_title(String.duplicate("a", 500))) == 120
  end
end
