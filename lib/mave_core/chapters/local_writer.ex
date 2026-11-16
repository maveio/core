defmodule MaveCore.Chapters.LocalWriter do
  @moduledoc """
  Suggests chapters without calling an external service.

  Topic changes are found with lexical cohesion, after TextTiling (Hearst, 1997):
  at every gap between two transcript cues, the words spoken shortly before are
  compared with the words spoken shortly after. A gap where the vocabulary shifts
  more than around it is a likely topic change. Pauses, sentence ends and nearby
  scene cuts make a gap more likely.

  Titles are the words that set a chapter apart from the others. They are
  keywords, not sentences: a starting point for review, not finished copy.
  """
  @behaviour MaveCore.Chapters.Writer

  alias MaveCore.Chapters.Stopwords

  @pause_seconds 0.6
  @cut_distance_seconds 1.0
  @nearby_seconds 6.0
  # Below this, the words on both sides of a gap are too alike for a new topic,
  # however long the pause.
  @min_topic 0.15
  @title_keywords 3

  @impl true
  def suggest(%{cues: cues, duration: duration} = input, _opts \\ []) do
    stopwords = Stopwords.for_language(input[:language])

    units = Enum.map(cues, &Map.put(&1, :tokens, tokenize(&1.text, stopwords)))

    case units |> candidates(input) |> select(input) do
      [] ->
        {:error, :no_topic_changes}

      starts ->
        starts = [0.0 | starts]
        {:ok, titled(starts, units, duration)}
    end
  end

  # --- Boundaries ---------------------------------------------------------

  @doc false
  def candidates(units, _input) when length(units) < 4, do: []

  def candidates(units, %{duration: duration} = input) do
    cuts = Map.get(input, :cuts, [])
    count = length(units)
    punctuated? = Enum.count(units, &sentence_end?(&1.text)) >= max(2, div(count, 20))
    topics = topics(units, duration, weights(units))

    for {{previous, unit}, index} <- Enum.with_index(Enum.zip(units, tl(units)), 1),
        eligible?(unit, input) do
      topic = Map.fetch!(topics, index)
      pause = unit.start - previous.end

      score =
        topic + pause_bonus(pause) + cut_bonus(cuts, previous.end, unit.start) +
          if(sentence_end?(previous.text), do: 0.08, else: 0.0)

      score = if punctuated? and not sentence_end?(previous.text), do: score * 0.5, else: score
      %{start: unit.start, score: score, topic: topic, likely?: topic >= @min_topic}
    end
  end

  defp eligible?(unit, %{duration: duration, min_chapter_seconds: min_chapter}),
    do: unit.start >= min_chapter and duration - unit.start >= min_chapter

  # How much the vocabulary shifts at the gap before each cue, by cue index.
  #
  # Lines that close one topic or announce the next share words with both, so
  # the dip in cohesion says "around here"; pauses, sentence ends and cuts say
  # where exactly. That is why a gap also counts the deepest dip close to it.
  defp topics(units, duration, weights) do
    window = duration |> Kernel./(10) |> max(20.0) |> min(75.0)
    indexed = List.to_tuple(units)
    count = tuple_size(indexed)
    first_start = elem(indexed, 0).start
    last_end = elem(indexed, count - 1).end

    similarities =
      1..(count - 1)//1
      |> Enum.map(fn index ->
        time = elem(indexed, index).start
        # Compare equal stretches: near the ends there is less on one side.
        span = Enum.min([window, time - first_start, last_end - time])

        similarity(
          vector(units, time - span, time, weights),
          vector(units, time, time + span, weights)
        )
      end)
      |> smooth()
      |> List.to_tuple()

    depths =
      for index <- 1..(count - 1)//1 do
        {index, elem(indexed, index).start, depth(similarities, index - 1)}
      end

    Map.new(depths, fn {index, time, depth} ->
      nearby =
        depths
        |> Enum.filter(fn {_index, other, _depth} -> abs(other - time) <= @nearby_seconds end)
        |> Enum.map(&elem(&1, 2))
        |> Enum.max()

      {index, (depth + nearby) / 2}
    end)
  end

  defp select([], _input), do: []

  defp select(candidates, input) do
    scores = Enum.map(candidates, & &1.score)
    mean = Enum.sum(scores) / length(scores)

    deviation =
      :math.sqrt(Enum.sum(Enum.map(scores, &((&1 - mean) * (&1 - mean)))) / length(scores))

    threshold = mean + deviation / 2
    required = if input.duration >= 120, do: 2, else: 1
    limit = max(input.max_chapters - 1, 1)

    candidates
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.reduce([], fn candidate, picked ->
      wanted? = candidate.likely? and (candidate.score >= threshold or length(picked) < required)

      spaced? = Enum.all?(picked, &(abs(&1 - candidate.start) >= input.min_chapter_seconds))

      if length(picked) < limit and wanted? and spaced? and candidate.score > 0,
        do: [candidate.start | picked],
        else: picked
    end)
    |> Enum.sort()
  end

  # Weighted word counts of the lines that start in a stretch of time.
  defp vector(units, from, to, weights) do
    units
    |> Enum.filter(&(&1.start >= from and &1.start < to))
    |> Enum.flat_map(& &1.tokens)
    |> Enum.frequencies_by(&elem(&1, 0))
    |> Map.new(fn {token, count} -> {token, count * Map.fetch!(weights, token)} end)
  end

  # A silent side has nothing in common with the other side.
  defp similarity(left, right) when map_size(left) == 0 or map_size(right) == 0, do: 0.0

  defp similarity(left, right) do
    dot =
      Enum.reduce(left, 0, fn {token, weight}, sum -> sum + weight * Map.get(right, token, 0) end)

    dot / (magnitude(left) * magnitude(right))
  end

  defp magnitude(vector) do
    vector |> Map.values() |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt()
  end

  defp smooth(values) do
    indexed = List.to_tuple(values)
    last = tuple_size(indexed) - 1

    Enum.map(0..last//1, fn index ->
      neighbours =
        for offset <- -1..1, (index + offset) in 0..last//1, do: elem(indexed, index + offset)

      Enum.sum(neighbours) / length(neighbours)
    end)
  end

  # How far similarity drops below the nearest peak on each side.
  defp depth(similarities, index) do
    value = elem(similarities, index)
    peak(similarities, index, -1, value) - value + (peak(similarities, index, 1, value) - value)
  end

  defp peak(similarities, index, step, highest) do
    next = index + step

    if next >= 0 and next < tuple_size(similarities) and elem(similarities, next) >= highest,
      do: peak(similarities, next, step, elem(similarities, next)),
      else: highest
  end

  defp pause_bonus(pause) when pause >= @pause_seconds, do: 0.25 * min(pause / 2.0, 1.0)
  defp pause_bonus(_pause), do: 0.0

  defp cut_bonus(cuts, previous_end, start) do
    near? =
      Enum.any?(cuts, fn cut ->
        cut >= previous_end - @cut_distance_seconds and cut <= start + @cut_distance_seconds
      end)

    if near?, do: 0.2, else: 0.0
  end

  defp sentence_end?(text), do: String.match?(text, ~r/[.!?…]["')\]]?\s*\z/u)

  # --- Words --------------------------------------------------------------

  defp tokenize(text, stopwords) do
    ~r/[\p{L}\p{N}][\p{L}\p{N}'’-]*/u
    |> Regex.scan(text)
    |> Enum.map(fn [surface] -> {String.downcase(surface), surface} end)
    |> Enum.reject(fn {token, _surface} ->
      String.length(token) < 3 or MapSet.member?(stopwords, token) or
        String.match?(token, ~r/\A[\d'’-]+\z/)
    end)
  end

  # Words used in many lines (a product name, function words in a language
  # without a stop list) say less about the topic than words used in a few.
  defp weights(units) do
    lines = length(units)

    units
    |> Enum.flat_map(fn unit -> unit.tokens |> Enum.map(&elem(&1, 0)) |> Enum.uniq() end)
    |> Enum.frequencies()
    |> Map.new(fn {token, count} -> {token, :math.log(1 + lines / count)} end)
  end

  # --- Titles -------------------------------------------------------------

  defp titled(starts, units, duration) do
    chapters =
      starts
      |> Enum.zip(Enum.drop(starts, 1) ++ [duration + 1.0])
      |> Enum.map(fn {start, finish} ->
        tokens =
          units
          |> Enum.filter(&(&1.start >= start and &1.start < finish))
          |> Enum.flat_map(& &1.tokens)

        %{start: start, tokens: tokens}
      end)

    document_frequency =
      chapters
      |> Enum.flat_map(fn chapter -> chapter.tokens |> Enum.map(&elem(&1, 0)) |> Enum.uniq() end)
      |> Enum.frequencies()

    chapters
    |> Enum.with_index(1)
    |> Enum.map(fn {chapter, number} ->
      %{
        start: chapter.start,
        title: title(chapter.tokens, document_frequency, length(chapters), number)
      }
    end)
  end

  defp title([], _document_frequency, _chapter_count, number), do: "Chapter #{number}"

  defp title(tokens, document_frequency, chapter_count, _number) do
    frequencies = tokens |> Enum.map(&elem(&1, 0)) |> Enum.frequencies()

    first_seen =
      tokens
      |> Enum.with_index()
      |> Enum.reverse()
      |> Map.new(fn {{token, _}, index} -> {token, index} end)

    frequencies
    |> Enum.map(fn {token, count} ->
      rarity = :math.log(1 + chapter_count / Map.fetch!(document_frequency, token))
      {token, count * rarity, Map.fetch!(first_seen, token)}
    end)
    |> Enum.sort_by(fn {_token, score, first} -> {-score, first} end)
    |> Enum.take(@title_keywords)
    |> Enum.sort_by(fn {_token, _score, first} -> first end)
    |> Enum.map_join(", ", fn {token, _score, _first} -> surface(tokens, token) end)
    |> capitalize_first()
  end

  # The spelling used most often, so names and acronyms keep their capitals.
  defp surface(tokens, token) do
    tokens
    |> Enum.filter(fn {normalized, _surface} -> normalized == token end)
    |> Enum.map(&elem(&1, 1))
    |> Enum.frequencies()
    |> Enum.max_by(fn {surface, count} -> {count, surface == String.downcase(surface)} end)
    |> elem(0)
  end

  defp capitalize_first(text) do
    case String.next_grapheme(text) do
      {first, rest} -> String.upcase(first) <> rest
      nil -> text
    end
  end
end
