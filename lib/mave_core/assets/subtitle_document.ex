defmodule MaveCore.Assets.SubtitleDocument do
  @moduledoc """
  An editable WebVTT subtitle file.

  `parse/1` reads a WebVTT file into cues, the editing functions change them, and
  `to_vtt/1` writes the file back. A cue is
  `%{id: String.t(), start: seconds, end: seconds, text: String.t(), settings: String.t()}`;
  ids only identify a cue while it is being edited and are not written to the file.

  The header line, header metadata and any `STYLE`/`REGION`/`NOTE` blocks before the
  first cue are kept as they are. Cue identifiers and comments between cues are
  dropped. Cue text keeps WebVTT tags such as `<i>` and `<v Name>`; `&amp;`,
  `&lt;`, `&gt;` and `&nbsp;` are shown as plain characters and escaped again on write.

  `issues/1` reports the same reading limits the subtitle generator aims for
  (`MaveCore.Transcription.SubtitleCues`): two lines of 42 characters and 17
  characters per second.
  """

  alias MaveCore.Transcription.SubtitleCues

  @enforce_keys [:header, :preamble, :cues, :next_id]
  defstruct [:header, :preamble, :cues, :next_id]

  @type cue :: %{
          id: String.t(),
          start: float(),
          end: float(),
          text: String.t(),
          settings: String.t()
        }
  @type t :: %__MODULE__{
          header: String.t(),
          preamble: [String.t()],
          cues: [cue()],
          next_id: pos_integer()
        }
  @type issue ::
          :empty
          | {:line_length, pos_integer()}
          | {:lines, pos_integer()}
          | {:reading_speed, pos_integer()}
          | :overlap

  @max_lines 2
  @min_duration 0.1
  @new_cue_duration 2.0
  @timestamp ~r/^(?:(\d+):)?(\d{1,2}):(\d{2})[.,](\d{1,3})$/
  @tag ~r/<\/?[A-Za-z][^>]*>|<\d+:[\d:.]+>/u

  def max_line_length, do: SubtitleCues.line_length()
  def max_lines, do: @max_lines
  def max_reading_speed, do: round(SubtitleCues.reading_speed())

  @doc "Parses a WebVTT file."
  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_webvtt}
  def parse(body) when is_binary(body) do
    with true <- String.valid?(body),
         [header | blocks] <- blocks(body),
         true <- String.starts_with?(header, "WEBVTT") do
      {preamble, cue_blocks} = Enum.split_while(blocks, &(parse_cue(&1) == nil))
      cues = cue_blocks |> Enum.map(&parse_cue/1) |> Enum.reject(&is_nil/1) |> with_ids(1)

      {:ok,
       %__MODULE__{
         header: header,
         preamble: preamble,
         cues: Enum.sort_by(cues, & &1.start),
         next_id: length(cues) + 1
       }}
    else
      _ -> {:error, :invalid_webvtt}
    end
  end

  def parse(_body), do: {:error, :invalid_webvtt}

  @doc "Writes the document as a WebVTT file. Cues without text are left out."
  @spec to_vtt(t()) :: String.t()
  def to_vtt(%__MODULE__{} = document) do
    cues =
      document.cues
      |> Enum.reject(&(clean_text(&1.text) == ""))
      |> Enum.map(fn cue ->
        settings = if cue.settings == "", do: "", else: " " <> cue.settings

        "#{timestamp(cue.start)} --> #{timestamp(cue.end)}#{settings}\n#{escape(clean_text(cue.text))}"
      end)

    Enum.join([document.header] ++ document.preamble ++ cues, "\n\n") <> "\n"
  end

  @doc "The cue with `id`, or nil."
  @spec cue(t(), String.t()) :: cue() | nil
  def cue(%__MODULE__{cues: cues}, id), do: Enum.find(cues, &(&1.id == id))

  @doc """
  Replaces the text of a cue. The text is kept as typed; spacing is tidied when
  the file is written.
  """
  @spec put_text(t(), String.t(), String.t()) :: t()
  def put_text(%__MODULE__{} = document, id, text) when is_binary(text) do
    update_cue(document, id, &%{&1 | text: String.replace(text, ~r/\r\n?/, "\n")})
  end

  @doc """
  Sets the start and end of a cue. Times are kept inside `0..duration`, the cue
  keeps a minimum length, and cues stay ordered by start time.
  """
  @spec put_timing(t(), String.t(), number(), number(), number() | nil) :: t()
  def put_timing(%__MODULE__{} = document, id, start_time, end_time, duration \\ nil)
      when is_number(start_time) and is_number(end_time) do
    limit = if is_number(duration) and duration > 0, do: duration * 1.0, else: nil
    start_time = start_time |> max(0.0) |> cap(limit && limit - @min_duration) |> round_ms()
    end_time = end_time |> max(start_time + @min_duration) |> cap(limit) |> round_ms()
    end_time = max(end_time, round_ms(start_time + @min_duration))

    document = update_cue(document, id, &%{&1 | start: start_time, end: end_time})
    %{document | cues: Enum.sort_by(document.cues, & &1.start)}
  end

  @doc """
  Splits a cue in two at character `offset` of its text. The time is divided in
  proportion to the text on each side. Returns the document and the id of the
  second cue.
  """
  @spec split(t(), String.t(), non_neg_integer()) :: {t(), String.t() | nil}
  def split(%__MODULE__{} = document, id, offset) when is_integer(offset) do
    case cue(document, id) do
      nil ->
        {document, nil}

      cue ->
        length = String.length(cue.text)
        offset = offset |> max(0) |> min(length)
        {head, tail} = String.split_at(cue.text, offset)
        ratio = if length == 0, do: 0.5, else: offset / length

        split_at =
          (cue.start + (cue.end - cue.start) * ratio)
          |> max(cue.start + @min_duration)
          |> min(cue.end - @min_duration)
          |> max(cue.start)
          |> round_ms()

        new_id = "c#{document.next_id}"
        first = %{cue | text: String.trim(head), end: split_at}
        second = %{cue | id: new_id, text: String.trim(tail), start: split_at}

        {replace(document, id, [first, second], document.next_id + 1), new_id}
    end
  end

  @doc """
  Joins a cue with the one after it. Returns the document, the id of the cue
  that remains and the character offset where the two texts meet.
  """
  @spec merge_with_next(t(), String.t()) :: {t(), String.t() | nil, non_neg_integer()}
  def merge_with_next(%__MODULE__{} = document, id) do
    index = Enum.find_index(document.cues, &(&1.id == id))

    case index && Enum.slice(document.cues, index, 2) do
      [first, second] ->
        head = String.trim_trailing(first.text)
        tail = String.trim_leading(second.text)
        separator = if head == "" or tail == "", do: "", else: " "
        merged = %{first | text: head <> separator <> tail, end: max(first.end, second.end)}

        cues =
          document.cues
          |> List.replace_at(index, merged)
          |> List.delete_at(index + 1)

        {%{document | cues: cues}, first.id, String.length(head <> separator)}

      _ ->
        {document, nil, 0}
    end
  end

  @doc "Joins a cue with the one before it. See `merge_with_next/2`."
  @spec merge_with_previous(t(), String.t()) :: {t(), String.t() | nil, non_neg_integer()}
  def merge_with_previous(%__MODULE__{} = document, id) do
    case Enum.find_index(document.cues, &(&1.id == id)) do
      index when is_integer(index) and index > 0 ->
        merge_with_next(document, Enum.at(document.cues, index - 1).id)

      _ ->
        {document, nil, 0}
    end
  end

  @doc """
  Adds an empty cue after the cue with `id` (or at the start when `id` is nil).
  It takes the silence up to the next cue; without enough room it takes the
  second half of the cue it follows. Returns the document and the new id.
  """
  @spec insert_after(t(), String.t() | nil, number() | nil) :: {t(), String.t()}
  def insert_after(%__MODULE__{} = document, id, duration \\ nil) do
    index = Enum.find_index(document.cues, &(&1.id == id))
    previous = index && Enum.at(document.cues, index)
    next = Enum.at(document.cues, if(index, do: index + 1, else: 0))
    new_id = "c#{document.next_id}"

    {previous, start_time, end_time} = new_cue_slot(previous, room_limit(next, duration))

    new = %{
      id: new_id,
      start: round_ms(start_time),
      end: round_ms(end_time),
      text: "",
      settings: ""
    }

    cues =
      case index do
        nil ->
          [new | document.cues]

        index ->
          document.cues |> List.replace_at(index, previous) |> List.insert_at(index + 1, new)
      end

    {%{document | cues: cues, next_id: document.next_id + 1}, new_id}
  end

  # Where a new cue has to end: the next cue, or the end of the video.
  defp room_limit(%{start: start_time}, _duration), do: start_time
  defp room_limit(nil, duration) when is_number(duration) and duration > 0, do: duration * 1.0
  defp room_limit(nil, _duration), do: nil

  defp new_cue_slot(previous, limit) do
    start_time = if previous, do: previous.end, else: 0.0
    room = if limit, do: limit - start_time, else: @new_cue_duration

    cond do
      room >= 0.5 ->
        {previous, start_time, start_time + min(room, @new_cue_duration)}

      previous ->
        middle = round_ms(previous.start + (previous.end - previous.start) / 2)
        {%{previous | end: middle}, middle, previous.end}

      true ->
        {previous, start_time, start_time + @new_cue_duration}
    end
  end

  @doc "Removes a cue. Returns the document and the id of a neighbouring cue, if any."
  @spec delete(t(), String.t()) :: {t(), String.t() | nil}
  def delete(%__MODULE__{} = document, id) do
    case Enum.find_index(document.cues, &(&1.id == id)) do
      nil ->
        {document, nil}

      index ->
        cues = List.delete_at(document.cues, index)
        neighbour = Enum.at(cues, index) || List.last(cues)
        {%{document | cues: cues}, neighbour && neighbour.id}
    end
  end

  @doc "Reading measurements of a cue: characters per line and characters per second."
  @spec reading(cue()) :: %{lines: [non_neg_integer()], speed: non_neg_integer()}
  def reading(cue) do
    lines = cue.text |> visible_text() |> String.split("\n") |> Enum.map(&String.length/1)
    duration = max(cue.end - cue.start, @min_duration)

    %{lines: lines, speed: round(Enum.sum(lines) / duration)}
  end

  @doc """
  Problems per cue id, most important first. Cues without problems are absent.
  """
  @spec issues(t()) :: %{String.t() => [issue()]}
  def issues(%__MODULE__{cues: cues}) do
    cues
    |> Enum.zip([nil | cues])
    |> Enum.flat_map(fn {cue, previous} ->
      case cue_issues(cue, previous) do
        [] -> []
        issues -> [{cue.id, issues}]
      end
    end)
    |> Map.new()
  end

  defp cue_issues(cue, previous) do
    %{lines: lines, speed: speed} = reading(cue)
    longest = Enum.max(lines)

    if Enum.sum(lines) == 0 do
      [:empty]
    else
      Enum.filter(
        [
          longest > max_line_length() && {:line_length, longest},
          length(lines) > @max_lines && {:lines, length(lines)},
          speed > max_reading_speed() && {:reading_speed, speed},
          previous && cue.start < previous.end - 0.0005 && :overlap
        ],
        & &1
      )
    end
  end

  defp blocks(body) do
    body
    |> String.trim_leading("﻿")
    |> String.replace(~r/\r\n?/, "\n")
    |> String.split(~r/\n{2,}/, trim: true)
    |> Enum.map(&String.trim(&1, "\n"))
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_cue(block) do
    lines = String.split(block, "\n")

    {timing, text} =
      case lines do
        [first | rest] ->
          if String.contains?(first, "-->"),
            do: {first, rest},
            else: {List.first(rest), tl_or_empty(rest)}

        [] ->
          {nil, []}
      end

    with timing when is_binary(timing) <- timing,
         [from, rest] <- String.split(timing, "-->", parts: 2),
         [to | settings] <- String.split(String.trim(rest), ~r/\s+/, parts: 2),
         start_time when is_float(start_time) <- parse_timestamp(String.trim(from)),
         end_time when is_float(end_time) <- parse_timestamp(to) do
      %{
        start: start_time,
        end: max(end_time, start_time),
        text: text |> Enum.join("\n") |> unescape() |> normalize_text(),
        settings: settings |> List.first() |> to_string() |> String.trim()
      }
    else
      _ -> nil
    end
  end

  defp tl_or_empty([_ | rest]), do: rest
  defp tl_or_empty([]), do: []

  defp parse_timestamp(value) do
    case Regex.run(@timestamp, value) do
      [_, hours, minutes, seconds, fraction] ->
        hours = if hours == "", do: 0, else: String.to_integer(hours)
        millis = fraction |> String.pad_trailing(3, "0") |> String.to_integer()

        hours * 3600.0 + String.to_integer(minutes) * 60 + String.to_integer(seconds) +
          millis / 1000

      _ ->
        nil
    end
  end

  defp timestamp(seconds) do
    ms = round(max(seconds, 0) * 1000)

    :io_lib.format("~2..0B:~2..0B:~2..0B.~3..0B", [
      div(ms, 3_600_000),
      div(rem(ms, 3_600_000), 60_000),
      div(rem(ms, 60_000), 1000),
      rem(ms, 1000)
    ])
    |> IO.iodata_to_binary()
  end

  defp with_ids(cues, first) do
    cues
    |> Enum.with_index(first)
    |> Enum.map(fn {cue, index} -> Map.put(cue, :id, "c#{index}") end)
  end

  defp update_cue(%__MODULE__{} = document, id, fun) do
    %{document | cues: Enum.map(document.cues, &if(&1.id == id, do: fun.(&1), else: &1))}
  end

  defp replace(%__MODULE__{} = document, id, replacement, next_id) do
    cues = Enum.flat_map(document.cues, &if(&1.id == id, do: replacement, else: [&1]))
    %{document | cues: cues, next_id: next_id}
  end

  defp normalize_text(text) do
    text
    |> String.replace(~r/\r\n?/, "\n")
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/ ?\n ?/, "\n")
  end

  # A blank line would end the cue in the file.
  defp clean_text(text) do
    text
    |> normalize_text()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp visible_text(text) do
    text
    |> clean_text()
    |> String.replace(@tag, "")
    |> String.split("\n")
    |> Enum.map_join("\n", &String.trim/1)
  end

  defp unescape(text) do
    Regex.replace(~r/&(amp|lt|gt|nbsp);/, text, fn _, name ->
      case name do
        "amp" -> "&"
        "lt" -> "<"
        "gt" -> ">"
        "nbsp" -> " "
      end
    end)
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace(~r/<(?!\/?[A-Za-z]|\d+:\d)/, "&lt;")
    |> String.replace("-->", "--&gt;")
    |> String.replace(" ", "&nbsp;")
  end

  defp cap(value, nil), do: value
  defp cap(value, limit), do: min(value, max(limit, 0.0))

  defp round_ms(seconds), do: Float.round(seconds * 1.0, 3)
end
