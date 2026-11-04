defmodule MaveCore.Transcription.SubtitleCues do
  @moduledoc """
  Builds readable cues for generated subtitles. Uploaded VTT is not processed here.

  Cues contain at most two lines of 42 graphemes. Existing segment boundaries are retained;
  provider word timings are preserved when complete and ordered. Otherwise,
  subdivisions use estimated, evenly spaced word timings, not speech alignment.
  Seven seconds is the target maximum duration, except when a single word spans
  longer. Dense speech may still exceed a comfortable reading speed: text is
  never dropped. Display can linger into silence to improve reading time, bounded
  by the next cue, the media duration (when known), and the seven-second limit.
  Original word timestamps remain unchanged.
  """

  @line_length 42
  @max_duration 7.0
  @min_duration 5 / 6
  @reading_speed 17.0
  @cue_gap 0.04

  def build(segments) when is_list(segments) do
    segments
    |> Enum.filter(&is_map/1)
    |> Enum.flat_map(&split_segment/1)
  end

  def build(_segments), do: []

  def from_transcription(transcription, duration \\ nil) do
    cues =
      case timed_words(get(transcription, :words), get(transcription, :text)) do
        [] ->
          case build(get(transcription, :segments)) do
            [] -> from_text(get(transcription, :text), duration)
            cues -> cues
          end

        words ->
          from_words(words)
      end

    hold_for_reading(cues, duration)
  end

  defp hold_for_reading(cues, duration) do
    cues
    |> Enum.with_index()
    |> Enum.map(fn {cue, index} ->
      next_start =
        case Enum.at(cues, index + 1) do
          nil -> number(duration) || cue.end + 0.8
          next -> next.start - @cue_gap
        end

      desired_end = cue.start + max(@min_duration, String.length(cue.text) / @reading_speed)
      limit = min(next_start, cue.start + @max_duration)
      end_time = max(cue.end, min(desired_end, limit))

      if end_time > cue.end do
        # A reading hold extends display time, not spoken word timings.
        cue |> Map.put(:end, end_time) |> Map.put(:words, original_word_timings(cue))
      else
        cue
      end
    end)
  end

  defp original_word_timings(%{words: words}), do: words

  defp original_word_timings(cue) do
    Enum.map(words(cue), fn word ->
      %{word: word["word"], start: word["start"], end: word["end"]}
    end)
  end

  defp timed_words(entries, text) when is_list(entries) and is_binary(text) do
    words =
      Enum.map(entries, fn entry ->
        %{
          word: get(entry, :word) || get(entry, :text),
          start: number(get(entry, :start)),
          end: number(get(entry, :end))
        }
      end)

    ordered? = Enum.all?(words, &valid_timed_word?/1) and ordered_words?(words)

    if ordered? and Enum.any?(words, &(&1.end > &1.start)) and
         compact_text(Enum.map_join(words, & &1.word)) == compact_text(text),
       do: words,
       else: []
  end

  defp timed_words(_, _), do: []

  defp valid_timed_word?(word) do
    is_binary(word.word) and word.word != "" and String.length(word.word) <= @line_length and
      is_number(word.start) and is_number(word.end) and word.start >= 0 and word.end >= word.start
  end

  defp ordered_words?(words) do
    Enum.all?(Enum.chunk_every(words, 2, 1, :discard), fn [left, right] ->
      left.end <= right.start
    end)
  end

  defp compact_text(text), do: String.replace(text, ~r/\s+/u, "")

  defp from_words(words) do
    units =
      Enum.map(words, fn word ->
        %{text: word.word, start: word.start, end: word.end, words: [word]}
      end)

    indexed_units = List.to_tuple(units)

    duration = fn offset, count ->
      elem(indexed_units, offset + count - 1).end - elem(indexed_units, offset).start
    end

    units
    |> Enum.map(& &1.text)
    |> partition(duration, fn offset, count ->
      next_index = offset + count
      current = elem(indexed_units, next_index - 1)

      next_index == tuple_size(indexed_units) or
        elem(indexed_units, next_index).start - current.end < 0.7
    end)
    |> Enum.map(fn {offset, chunk} ->
      selected = for index <- offset..(offset + length(chunk) - 1), do: elem(indexed_units, index)

      %{
        start: hd(selected).start,
        end: max(List.last(selected).end, hd(selected).start + 0.001),
        text: wrap(chunk),
        words: Enum.flat_map(selected, & &1.words)
      }
    end)
  end

  def from_text(text, duration) do
    build([%{text: text, start: 0.0, end: max(duration || 5.0, 0.5)}])
  end

  def to_vtt([]), do: {:error, :empty_subtitle_segments}

  def to_vtt(cues) do
    body =
      Enum.map(
        cues,
        &[format_time(&1.start), " --> ", format_time(&1.end), "\n", &1.text, "\n\n"]
      )

    {:ok, IO.iodata_to_binary(["WEBVTT\n\n", body])}
  end

  def json_segments(cues) do
    cues
    |> Enum.with_index(1)
    |> Enum.map(fn {cue, id} ->
      %{
        "id" => id,
        "start" => cue.start,
        "end" => cue.end,
        "text" => cue.text,
        "words" => words(cue)
      }
    end)
  end

  defp split_segment(segment) do
    start_time = max(number(get(segment, :start)) || 0.0, 0.0)
    end_time = max(number(get(segment, :end)) || start_time + 0.5, start_time + 0.1)
    tokens = segment |> get(:text) |> to_string() |> String.split(~r/\s+/u, trim: true)
    # A single unbroken token may be longer than a line (for example a URL).
    tokens = Enum.flat_map(tokens, &split_long_token/1)
    count = length(tokens)
    step = (end_time - start_time) / max(count, 1)

    tokens
    |> partition(step)
    |> Enum.map(fn {offset, chunk} ->
      %{
        start: start_time + offset * step,
        end: min(end_time, start_time + (offset + length(chunk)) * step),
        text: wrap(chunk)
      }
    end)
  end

  defp split_long_token(token) do
    token |> String.graphemes() |> Enum.chunk_every(@line_length) |> Enum.map(&Enum.join/1)
  end

  defp partition(tokens, step) when is_number(step) do
    partition(tokens, fn _offset, count -> count * step end, fn _offset, _count -> true end)
  end

  defp partition([], _duration, _join?), do: []

  defp partition(tokens, duration, join?) do
    {_cost, chunks} =
      best_partition(List.to_tuple(tokens), duration, join?, length(tokens) - 1, %{
        length(tokens) => {0.0, []}
      })

    chunks
  end

  defp best_partition(_tokens, _duration, _join?, -1, cache), do: Map.fetch!(cache, 0)

  defp best_partition(tokens, duration, join?, offset, cache) do
    choices =
      offset..min(offset + 83, tuple_size(tokens) - 1)
      |> Stream.map(&elem(tokens, &1))
      |> Stream.scan([], fn token, acc -> acc ++ [token] end)
      |> Enum.take_while(fn chunk ->
        count = length(chunk)

        fits?(chunk) and
          (count == 1 or
             (duration.(offset, count) <= @max_duration and join?.(offset, count - 1)))
      end)

    best =
      Enum.min_by(choices, fn chunk ->
        {cost, _} = Map.fetch!(cache, offset + length(chunk))
        cost + chunk_cost(chunk, duration.(offset, length(chunk)))
      end)

    {cost, rest} = Map.fetch!(cache, offset + length(best))
    result = {cost + chunk_cost(best, duration.(offset, length(best))), [{offset, best} | rest]}
    best_partition(tokens, duration, join?, offset - 1, Map.put(cache, offset, result))
  end

  defp chunk_cost(chunk, duration) do
    duration = max(duration, 0.001)
    size = String.length(Enum.join(chunk, " "))
    ending = List.last(chunk)

    boundary_cost =
      cond do
        String.match?(ending, ~r/[.!?…]["'”’)]?$/u) -> 0.0
        String.match?(ending, ~r/[,;:]["'”’)]?$/u) -> 0.6
        true -> 1.2
      end

    crossed_sentences =
      chunk |> Enum.drop(-1) |> Enum.count(&String.match?(&1, ~r/[.!?…]["'”’)]?$/u))

    crossed_sentences * 0.8 + 0.4 + 0.3 * :math.pow((84 - size) / 84, 2) + boundary_cost +
      max(0.0, 0.833 - duration) * 4 + max(0.0, size / duration - @reading_speed) / @reading_speed
  end

  defp fits?(tokens), do: not is_nil(line_split(tokens))

  defp wrap(tokens) do
    case line_split(tokens) do
      0 ->
        Enum.join(tokens, " ")

      index ->
        {left, right} = Enum.split(tokens, index)
        Enum.join(left, " ") <> "\n" <> Enum.join(right, " ")
    end
  end

  defp line_split(tokens) do
    if String.length(Enum.join(tokens, " ")) <= @line_length do
      0
    else
      1..(length(tokens) - 1)
      |> Enum.filter(fn index ->
        {left, right} = Enum.split(tokens, index)

        String.length(Enum.join(left, " ")) <= @line_length and
          String.length(Enum.join(right, " ")) <= @line_length
      end)
      |> Enum.min_by(
        fn index ->
          {left, right} = Enum.split(tokens, index)

          balance =
            abs(String.length(Enum.join(left, " ")) - String.length(Enum.join(right, " ")))

          balance + line_boundary_cost(List.last(left))
        end,
        fn -> nil end
      )
    end
  end

  defp line_boundary_cost(word) do
    cond do
      String.match?(word, ~r/[.!?,;:]$/u) -> -10
      String.downcase(word) in ~w(a an the and or to of de het een en of van in op met voor) -> 12
      true -> 0
    end
  end

  defp words(%{words: words}) do
    Enum.map(words, fn word ->
      %{"word" => word.word, "start" => word.start, "end" => word.end}
    end)
  end

  defp words(cue) do
    tokens = String.split(cue.text, ~r/\s+/u, trim: true)
    step = (cue.end - cue.start) / length(tokens)

    tokens
    |> Enum.with_index()
    |> Enum.map(fn {word, index} ->
      %{
        "word" => word,
        "start" => Float.round(cue.start + index * step, 3),
        "end" => Float.round(min(cue.end, cue.start + (index + 1) * step), 3)
      }
    end)
  end

  defp get(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp get(_, _), do: nil

  defp number(value) when is_number(value), do: value * 1.0

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _} -> number
      :error -> nil
    end
  end

  defp number(_), do: nil

  defp format_time(seconds) do
    ms = round(seconds * 1000)

    :io_lib.format("~2..0B:~2..0B:~2..0B.~3..0B", [
      div(ms, 3_600_000),
      div(rem(ms, 3_600_000), 60_000),
      div(rem(ms, 60_000), 1000),
      rem(ms, 1000)
    ])
  end
end
