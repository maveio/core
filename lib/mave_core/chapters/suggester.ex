defmodule MaveCore.Chapters.Suggester do
  @moduledoc """
  Suggests chapters for a video from its timed transcript and scene cuts.

  A writer proposes topic changes and titles (`MaveCore.Chapters.MistralWriter`
  when a Mistral API key is configured, `MaveCore.Chapters.LocalWriter`
  otherwise). The proposal is then checked here, whichever writer made it: starts
  move to the beginning of the nearest spoken line and to a scene cut right next
  to it, chapters that are too short are merged, and titles are tidied.

  When the configured writer fails, the local writer is used so a suggestion
  still arrives; the result records which writer produced it.
  """

  alias MaveCore.Assets.ChapterSet
  alias MaveCore.Chapters.{LocalWriter, MistralWriter, Transcript}

  require Logger

  @min_video_seconds 60
  @min_words 40
  @max_chapters 24
  @cue_snap_seconds 2.5
  @cut_snap_seconds 1.5

  @type result :: %{
          chapters: [%{String.t() => term()}],
          generator: String.t(),
          inputs: [String.t()]
        }

  @doc """
  Suggests chapters. Options: `:cues` (required), `:duration` (required),
  `:language`, `:cuts`, `:writer` and `:usage_context`.
  """
  @spec suggest(keyword()) :: {:ok, result()} | {:error, atom()}
  def suggest(opts) do
    cues = Keyword.get(opts, :cues, [])
    duration = opts |> Keyword.get(:duration) |> duration(cues)
    cuts = opts |> Keyword.get(:cuts, []) |> Enum.filter(&is_number/1) |> Enum.sort()

    cond do
      cues == [] -> {:error, :no_transcript}
      duration < @min_video_seconds -> {:error, :too_short}
      Transcript.word_count(cues) < @min_words -> {:error, :too_short}
      true -> write(opts, cues, duration, cuts)
    end
  end

  defp write(opts, cues, duration, cuts) do
    input = %{
      cues: cues,
      duration: duration,
      language: Keyword.get(opts, :language),
      cuts: cuts,
      max_chapters: max_chapters(duration),
      min_chapter_seconds: min_chapter_seconds(duration)
    }

    writer = Keyword.get(opts, :writer) || writer()
    writer_opts = Keyword.take(opts, [:usage_context])

    with {:ok, writer, proposed} <- run_writer(writer, input, writer_opts),
         [_, _ | _] = chapters <- normalize(proposed, input) do
      {:ok,
       %{
         chapters: chapters,
         generator: generator(writer),
         inputs: if(cuts == [], do: ["transcript"], else: ["transcript", "scenes"])
       }}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :no_topic_changes}
    end
  end

  defp run_writer(LocalWriter, input, opts) do
    with {:ok, proposed} <- LocalWriter.suggest(input, opts), do: {:ok, LocalWriter, proposed}
  end

  defp run_writer(writer, input, opts) do
    case writer.suggest(input, opts) do
      {:ok, proposed} when is_list(proposed) ->
        {:ok, writer, proposed}

      other ->
        Logger.warning(
          "Chapter writer #{inspect(writer)} failed (#{inspect(failure(other))}); using the local writer"
        )

        run_writer(LocalWriter, input, opts)
    end
  end

  # Never log provider responses: keep the reason only.
  defp failure({:error, {:http_error, status}}), do: {:http_error, status}
  defp failure({:error, reason}) when is_atom(reason), do: reason
  defp failure(_other), do: :failed

  @doc "The writer for new suggestions: configured, or chosen by available credentials."
  def writer do
    configured = Application.get_env(:mave_core, :chapters, [])[:writer]

    cond do
      is_atom(configured) and not is_nil(configured) -> configured
      System.get_env("MAVE_CHAPTERS_WRITER") == "local" -> LocalWriter
      MistralWriter.available?() -> MistralWriter
      true -> LocalWriter
    end
  end

  defp generator(LocalWriter), do: "local"
  defp generator(MistralWriter), do: "mistral"
  defp generator(writer), do: writer |> Module.split() |> List.last() |> Macro.underscore()

  @doc "Most chapters suggested for a video of `duration` seconds."
  def max_chapters(duration) do
    # About one per half minute in short videos, growing slowly in long ones.
    by_length = round(duration / 30)
    by_growth = 10 + round(duration / 600)
    by_length |> min(by_growth) |> max(3) |> min(@max_chapters)
  end

  @doc "Shortest suggested chapter for a video of `duration` seconds."
  def min_chapter_seconds(duration), do: (duration / 25) |> max(15.0) |> min(90.0)

  defp duration(value, _cues) when is_number(value) and value > 0, do: value * 1.0
  defp duration(_value, []), do: 0.0
  defp duration(_value, cues), do: cues |> Enum.map(& &1.end) |> Enum.max()

  @doc false
  def normalize(proposed, input) do
    cue_starts = Enum.map(input.cues, & &1.start)

    proposed
    |> Enum.flat_map(fn chapter ->
      start = chapter[:start] || chapter["start"]
      title = clean_title(chapter[:title] || chapter["title"])

      if is_number(start) and start >= 0 and start < input.duration and title != "",
        do: [%{start: start * 1.0, title: title}],
        else: []
    end)
    |> Enum.sort_by(& &1.start)
    |> anchor_first()
    |> Enum.map(&align(&1, cue_starts, input.cuts))
    |> merge_short(input)
    |> Enum.take(ChapterSet.max_chapters())
    |> Enum.map(&%{"start" => Float.round(&1.start, 3), "title" => &1.title})
  end

  defp anchor_first([first | rest]), do: [%{first | start: 0.0} | rest]
  defp anchor_first([]), do: []

  # A chapter should begin where a line begins, and on the cut when the picture
  # changes right there.
  defp align(%{start: +0.0} = chapter, _cue_starts, _cuts), do: chapter

  defp align(chapter, cue_starts, cuts) do
    start = chapter.start |> nearest(cue_starts, @cue_snap_seconds)
    cut = nearest(start, cuts, @cut_snap_seconds)
    # Never move past the line: the first words of the chapter must be audible.
    %{chapter | start: if(cut <= start, do: cut, else: start)}
  end

  defp nearest(value, [], _within), do: value

  defp nearest(value, candidates, within) do
    candidate = Enum.min_by(candidates, &abs(&1 - value))
    if abs(candidate - value) <= within, do: candidate, else: value
  end

  defp merge_short(chapters, input) do
    # Writers are asked for the minimum length; allow some slack after aligning.
    minimum = input.min_chapter_seconds * 0.6

    chapters
    |> Enum.reduce([], fn chapter, kept ->
      case kept do
        [previous | _] when chapter.start - previous.start < minimum -> kept
        _ -> [chapter | kept]
      end
    end)
    |> drop_short_tail(input.duration, minimum)
    |> Enum.reverse()
  end

  defp drop_short_tail([last, _previous | _] = kept, duration, minimum)
       when duration - last.start < minimum,
       do: tl(kept)

  defp drop_short_tail(kept, _duration, _minimum), do: kept

  @doc "A title without wrapping quotes, numbering, line breaks or a final full stop."
  def clean_title(title) when is_binary(title) do
    title
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.replace(~r/\A(?:chapter\s+)?\d+[.):]\s+/iu, "")
    |> String.trim(~s("))
    |> String.trim("“")
    |> String.trim("”")
    |> String.replace(~r/[.。]\z/u, "")
    |> String.trim()
    |> String.slice(0, ChapterSet.max_title_length())
  end

  def clean_title(_title), do: ""
end
