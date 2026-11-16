defmodule MaveCore.Chapters.Writer do
  @moduledoc """
  Turns a timed transcript into chapter suggestions.

  The input has `:cues` (`MaveCore.Chapters.Transcript` cues), `:duration` in
  seconds, `:language`, `:cuts` (scene-cut times in seconds, possibly empty),
  `:max_chapters` and `:min_chapter_seconds`. A writer returns chapters ordered
  by start time; `MaveCore.Chapters.Suggester` validates and aligns them.
  """

  @type input :: %{
          cues: [MaveCore.Chapters.Transcript.cue()],
          duration: float(),
          language: String.t() | nil,
          cuts: [float()],
          max_chapters: pos_integer(),
          min_chapter_seconds: float()
        }

  @callback suggest(input(), keyword()) ::
              {:ok, [%{start: number(), title: String.t()}]} | {:error, term()}
end
