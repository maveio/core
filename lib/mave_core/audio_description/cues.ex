defmodule MaveCore.AudioDescription.Cues do
  @moduledoc """
  Description cues: parsing model output, cleaning it up and writing the
  descriptions WebVTT (`Kind: descriptions`).

  A cue is `%{start: seconds, end: seconds, text: String.t()}`, optionally with
  `scene: %{start, end}` (the scene it is tied to).
  """

  alias MaveCore.AudioDescription.Timeline

  @min_cue_seconds 0.5

  @doc """
  Parse a timestamp into seconds. Accepts numbers and strings like `HH:MM:SS.mmm`,
  `MM:SS`, `MM:SS.mmm` or `SS.mmm` (comma decimals allowed).
  """
  def parse_timestamp(value) when is_number(value) and value >= 0, do: value * 1.0

  def parse_timestamp(value) when is_binary(value) do
    value = value |> String.trim() |> String.replace(",", ".", global: false)

    if Regex.match?(~r/^\d+(:\d+){0,2}(\.\d+)?$/, value) do
      value
      |> String.split(":")
      |> Enum.reduce(0.0, fn part, acc -> acc * 60 + parse_number(part) end)
    end
  end

  def parse_timestamp(_value), do: nil

  defp parse_number(part) do
    {number, ""} = Float.parse(part)
    number
  end

  @doc "WebVTT timestamp `HH:MM:SS.mmm`."
  def format_timestamp(seconds) do
    total_ms = max(0, round(seconds * 1000))
    ms = rem(total_ms, 1000)
    total_s = div(total_ms, 1000)

    :io_lib.format("~2..0B:~2..0B:~2..0B.~3..0B", [
      div(total_s, 3600),
      rem(div(total_s, 60), 60),
      rem(total_s, 60),
      ms
    ])
    |> IO.iodata_to_binary()
  end

  @doc "Rough time needed to speak a text aloud, in seconds."
  def estimate_speech_seconds(text) do
    words = text |> String.split(~r/\s+/, trim: true) |> length()
    max(1.0, words / 2.5)
  end

  @doc """
  Clean up cues: drop invalid ones, sort, merge cues that start at the same
  moment, repair end times, remove overlaps and clamp to the video duration.
  """
  def normalize(cues, duration \\ nil) do
    limit = if is_number(duration) and duration > 0, do: duration * 1.0

    cues
    |> Enum.flat_map(&parse_cue(&1, limit))
    |> Enum.sort_by(&{&1.start, &1.end})
    |> Enum.reduce([], fn cue, acc ->
      case acc do
        [prev | rest] when cue.start - prev.start < 0.05 ->
          [%{prev | text: prev.text <> " " <> cue.text, end: max(prev.end, cue.end)} | rest]

        _ ->
          [cue | acc]
      end
    end)
    |> Enum.reverse()
    |> fix_ends(limit)
    |> Enum.filter(&(&1.end > &1.start))
  end

  defp parse_cue(cue, limit) do
    text = cue |> field(:text) |> clean_text()
    start = cue |> field(:start) |> parse_timestamp()

    if text == "" or is_nil(start) or (limit && start >= limit) do
      []
    else
      stop = cue |> field(:end) |> parse_timestamp()

      stop =
        if is_nil(stop) or stop <= start, do: start + estimate_speech_seconds(text), else: stop

      [%{start: start, end: stop, text: text} |> maybe_put_scene(field(cue, :scene))]
    end
  end

  defp fix_ends(cues, limit) do
    next_starts = cues |> Enum.drop(1) |> Enum.map(& &1.start) |> Kernel.++([nil])

    cues
    |> Enum.zip(next_starts)
    |> Enum.map(fn {cue, next_start} ->
      stop = if next_start && cue.end > next_start, do: next_start, else: cue.end
      stop = if limit && stop > limit, do: limit, else: stop
      stop = min_length_end(cue.start, stop, next_start || limit)

      %{cue | start: Timeline.round3(cue.start), end: Timeline.round3(stop)}
    end)
  end

  # Short cues are stretched to the minimum length, but never past the next cue or the end.
  defp min_length_end(start, stop, _ceiling) when stop - start >= @min_cue_seconds, do: stop
  defp min_length_end(start, _stop, nil), do: start + @min_cue_seconds
  defp min_length_end(start, _stop, ceiling), do: min(start + @min_cue_seconds, ceiling)

  defp maybe_put_scene(cue, %{start: start, end: stop}) when is_number(start) and is_number(stop),
    do: Map.put(cue, :scene, %{start: start, end: stop})

  defp maybe_put_scene(cue, %{"start" => start, "end" => stop}),
    do: maybe_put_scene(cue, %{start: start, end: stop})

  defp maybe_put_scene(cue, _scene), do: cue

  defp clean_text(text) when is_binary(text),
    do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp clean_text(_text), do: ""

  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  @doc "The descriptions WebVTT for `cues` in `language`."
  def to_vtt(cues, language) do
    body =
      cues
      |> Enum.with_index(1)
      |> Enum.map(fn {cue, i} ->
        "#{i}\n#{format_timestamp(cue.start)} --> #{format_timestamp(cue.end)}\n#{escape(cue.text)}\n"
      end)

    Enum.join(["WEBVTT\nKind: descriptions\nLanguage: #{language}\n" | body], "\n")
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  @doc "Cues as JSON-safe maps (string keys) for storage."
  def to_json(cues) do
    Enum.map(cues, fn cue ->
      %{"start" => cue.start, "end" => cue.end, "text" => cue.text}
      |> put_scene_json(cue[:scene])
    end)
  end

  defp put_scene_json(map, %{start: start, end: stop}),
    do: Map.put(map, "scene", %{"start" => start, "end" => stop})

  defp put_scene_json(map, _scene), do: map

  @doc "Cues read back from `to_json/1`."
  def from_json(list) when is_list(list) do
    Enum.flat_map(list, fn
      %{"start" => start, "end" => stop, "text" => text} = cue
      when is_number(start) and is_number(stop) and is_binary(text) ->
        [%{start: start * 1.0, end: stop * 1.0, text: text} |> maybe_put_scene(cue["scene"])]

      _ ->
        []
    end)
  end

  def from_json(_), do: []
end
