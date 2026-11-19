defmodule MaveCore.Chapters.Transcript do
  @moduledoc """
  Timed transcript cues used to suggest chapters.

  Cues are `%{start: seconds, end: seconds, text: text}`, ordered by start time.
  They come from the transcription JSON stored next to generated subtitles, or
  from any WebVTT subtitle file.
  """

  @type cue :: %{start: float(), end: float(), text: String.t()}

  @doc "Cues from the `segments` of a stored transcription JSON document."
  @spec from_json(binary() | map()) :: [cue()]
  def from_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = document} -> from_json(document)
      _ -> []
    end
  end

  def from_json(%{"segments" => segments}) when is_list(segments) do
    segments
    |> Enum.flat_map(fn
      %{"start" => start, "text" => text} = segment when is_number(start) and is_binary(text) ->
        finish = if is_number(segment["end"]), do: segment["end"], else: start
        [cue(start, finish, text)]

      _segment ->
        []
    end)
    |> normalize()
  end

  def from_json(_document), do: []

  @doc "Cues from a WebVTT document. Notes, styles, cue settings and markup are ignored."
  @spec from_vtt(binary()) :: [cue()]
  def from_vtt(body) when is_binary(body) do
    body
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.split(~r/\n{2,}/, trim: true)
    |> Enum.flat_map(&parse_block/1)
    |> normalize()
  end

  def from_vtt(_body), do: []

  defp parse_block(block) do
    lines = String.split(block, "\n", trim: true)

    case Enum.split_while(lines, &(not String.contains?(&1, "-->"))) do
      {_identifier, [timing | text]} ->
        with [left, right] <- String.split(timing, "-->", parts: 2),
             start when is_number(start) <- parse_timestamp(left),
             finish when is_number(finish) <-
               right |> String.split(~r/\s+/, trim: true) |> List.first() |> parse_timestamp() do
          [cue(start, finish, Enum.join(text, " "))]
        else
          _ -> []
        end

      _other ->
        []
    end
  end

  @doc "Seconds for a WebVTT timestamp such as `01:02:03.500` or `02:03.500`."
  @spec parse_timestamp(term()) :: float() | nil
  def parse_timestamp(value) when is_binary(value) do
    case Regex.run(~r/\A(?:(\d+):)?(\d{1,2}):(\d{2})(?:[.,](\d{1,3}))?\z/, String.trim(value)) do
      [_, hours, minutes, seconds | rest] ->
        millis = rest |> List.first() |> Kernel.||("0") |> String.pad_trailing(3, "0")

        to_integer(hours) * 3600 + to_integer(minutes) * 60 + to_integer(seconds) +
          to_integer(millis) / 1000

      _ ->
        nil
    end
  end

  def parse_timestamp(_value), do: nil

  defp to_integer(""), do: 0
  defp to_integer(value), do: String.to_integer(value)

  defp cue(start, finish, text) do
    %{start: start * 1.0, end: max(finish, start) * 1.0, text: clean_text(text)}
  end

  defp clean_text(text) do
    text
    |> String.replace(~r/<[^>]*>/, "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp normalize(cues) do
    cues
    |> Enum.reject(&(&1.text == ""))
    |> Enum.sort_by(& &1.start)
  end

  @doc "Total number of words in the cues."
  @spec word_count([cue()]) :: non_neg_integer()
  def word_count(cues) do
    Enum.reduce(cues, 0, fn cue, count ->
      count + length(String.split(cue.text, ~r/\s+/u, trim: true))
    end)
  end
end
