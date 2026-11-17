defmodule MaveCore.Transcription.SubtitleDocument do
  @moduledoc """
  Text-only editing of WebVTT cues while retaining their timing and settings.
  """

  @timing ~r/^\d{2,}:\d{2}(?::\d{2})?\.\d{3} --> \d{2,}:\d{2}(?::\d{2})?\.\d{3}(?:\s.*)?$/

  def parse(body) when is_binary(body) do
    if String.valid?(body) and byte_size(body) <= 2_000_000 do
      parse_blocks(body)
    else
      {:error, :invalid_document}
    end
  end

  defp parse_blocks(body) do
    [header | blocks] =
      body
      |> String.trim_leading("\uFEFF")
      |> String.replace("\r\n", "\n")
      |> String.trim_trailing()
      |> String.split(~r/\n[\t ]*\n/)

    parsed = Enum.with_index(blocks, &parse_block/2)

    if Regex.match?(~r/^WEBVTT(?:[ \t\n]|$)/, header) and
         Enum.any?(parsed, &Map.has_key?(&1, :text)) and
         not Enum.any?(parsed, &Map.get(&1, :invalid, false)) do
      {:ok, %{header: header, blocks: parsed}}
    else
      {:error, :invalid_document}
    end
  end

  defp parse_block(block, index) do
    lines = String.split(block, "\n")

    case Enum.find_index(lines, &Regex.match?(@timing, &1)) do
      position when position in [0, 1] ->
        {prefix, [_timing | text]} = Enum.split(lines, position)
        payload = Enum.join(text, "\n")

        %{
          id: Integer.to_string(index),
          raw: block,
          time_range: time_range(Enum.at(lines, position)),
          start_seconds: start_seconds(Enum.at(lines, position)),
          end_seconds: end_seconds(Enum.at(lines, position)),
          prefix: Enum.join(prefix ++ [Enum.at(lines, position)], "\n"),
          text: plain_text(payload)
        }

      _ ->
        %{raw: block, invalid: not Regex.match?(~r/^(NOTE(?:[ \t\n]|$)|STYLE\n|REGION\n)/, block)}
    end
  end

  def cues(document), do: Enum.filter(document.blocks, &Map.has_key?(&1, :text))

  defp start_seconds(timing) do
    [timestamp | _] = String.split(timing, " ")

    timestamp_seconds(timestamp)
  end

  defp end_seconds(timing) do
    [_, _, timestamp | _] = String.split(timing, " ")

    timestamp_seconds(timestamp)
  end

  defp timestamp_seconds(timestamp) do
    timestamp
    |> String.split(":")
    |> Enum.reduce(0.0, fn part, total ->
      {value, ""} = Float.parse(part)
      total * 60 + value
    end)
  end

  defp time_range(timing) do
    [_, start_time, end_time] = Regex.run(~r/^(\S+) --> (\S+)/, timing)

    [start_time, end_time]
    |> Enum.map(fn time ->
      time |> String.replace(~r/^00:(?=\d{2}:)/, "") |> String.replace_suffix(".000", "")
    end)
    |> Enum.join(" – ")
  end

  def texts(document), do: Map.new(cues(document), &{&1.id, &1.text})

  def render(document, texts) when is_map(texts) do
    originals = texts(document)

    if Map.keys(texts) |> Enum.sort() == Enum.sort(Map.keys(originals)) and
         Enum.all?(texts, fn {_id, text} ->
           is_binary(text) and String.valid?(text) and String.trim(text) != "" and
             byte_size(text) <= 20_000
         end) do
      blocks = Enum.map(document.blocks, &render_block(&1, texts))
      {:ok, Enum.join([document.header | blocks], "\n\n") <> "\n"}
    else
      {:error, :invalid_text}
    end
  end

  defp render_block(%{id: id, text: original} = block, texts) do
    case Map.fetch!(texts, id) do
      ^original -> block.raw
      text -> block.prefix <> "\n" <> escape_text(text)
    end
  end

  defp render_block(block, _texts), do: block.raw

  defp plain_text(text) do
    text
    |> String.replace(~r/<[^>]*>/, "")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&nbsp;", "\u00A0")
    |> String.replace("&lrm;", "\u200E")
    |> String.replace("&rlm;", "\u200F")
    |> String.replace("&amp;", "&")
  end

  defp escape_text(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.trim()
    |> String.replace(~r/\n[\t ]*\n+/, "\n")
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
