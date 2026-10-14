defmodule MaveCore.Transcription.SubtitleSource do
  @moduledoc "Normalizes timed VTT, SRT and transcription JSON for subtitle translation."

  @max_bytes 5 * 1024 * 1024
  @timestamp ~r/^(?:(\d{2,}):)?(\d{2}):(\d{2})[.,](\d{3})$/

  def parse(body) when is_binary(body) and byte_size(body) <= @max_bytes do
    if String.valid?(body) do
      body =
        body
        |> String.trim_leading("\uFEFF")
        |> String.replace("\r\n", "\n")
        |> String.replace("\r", "\n")
        |> String.trim()

      if String.starts_with?(body, "{"), do: parse_json(body), else: parse_cues(body)
    else
      {:error, :invalid_subtitle_encoding}
    end
  end

  def parse(_body), do: {:error, :subtitle_source_too_large}

  defp parse_json(body) do
    with {:ok, %{"segments" => segments}} when is_list(segments) <- Jason.decode(body),
         {:ok, normalized} <- normalize_segments(segments) do
      transcription(normalized)
    else
      _ -> {:error, :invalid_transcription_json}
    end
  end

  defp normalize_segments(segments) do
    Enum.reduce_while(segments, {:ok, []}, fn segment, {:ok, acc} ->
      case normalize_segment(segment) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        error -> {:halt, error}
      end
    end)
    |> reverse_segments()
  end

  defp normalize_segment(%{"start" => start_time, "end" => end_time, "text" => text})
       when is_number(start_time) and is_number(end_time) and is_binary(text) and start_time >= 0 and
              end_time > start_time do
    if String.trim(text) == "",
      do: {:error, :empty_subtitle_cue},
      else: {:ok, %{"start" => start_time, "end" => end_time, "text" => String.trim(text)}}
  end

  defp normalize_segment(_), do: {:error, :invalid_subtitle_cue}

  defp parse_cues(body) do
    body
    |> String.split(~r/\n[\t ]*\n+/, trim: true)
    |> Enum.reject(&metadata_block?/1)
    |> Enum.reduce_while({:ok, []}, fn block, {:ok, segments} ->
      case parse_cue(block) do
        {:ok, segment} -> {:cont, {:ok, [segment | segments]}}
        error -> {:halt, error}
      end
    end)
    |> reverse_segments()
    |> case do
      {:ok, segments} -> transcription(segments)
      error -> error
    end
  end

  defp metadata_block?(block), do: Regex.match?(~r/^(WEBVTT|NOTE|STYLE|REGION)(\s|$)/, block)

  defp parse_cue(block) do
    lines = String.split(block, "\n")
    lines = if String.contains?(hd(lines), "-->"), do: lines, else: tl(lines)

    with [timing | text_lines] when text_lines != [] <- lines,
         [start_value, ending] <- String.split(timing, ~r/\s+-->\s+/, parts: 2),
         end_value = ending |> String.split(~r/\s+/, trim: true) |> List.first(),
         {:ok, start_time} <- timestamp(String.trim(start_value)),
         {:ok, end_time} <- timestamp(end_value) do
      normalize_segment(%{
        "start" => start_time,
        "end" => end_time,
        "text" => Enum.join(text_lines, "\n")
      })
    else
      _ -> {:error, :invalid_subtitle_cue}
    end
  end

  defp timestamp(value) when is_binary(value) do
    case Regex.run(@timestamp, value) do
      [_, hours, minutes, seconds, millis] ->
        h = if hours == "", do: 0, else: String.to_integer(hours)
        m = String.to_integer(minutes)
        s = String.to_integer(seconds)

        if m < 60 and s < 60,
          do: {:ok, h * 3600 + m * 60 + s + String.to_integer(millis) / 1000},
          else: {:error, :invalid_timestamp}

      _ ->
        {:error, :invalid_timestamp}
    end
  end

  defp timestamp(_), do: {:error, :invalid_timestamp}
  defp reverse_segments({:ok, segments}), do: {:ok, Enum.reverse(segments)}
  defp reverse_segments(error), do: error
  defp transcription([]), do: {:error, :empty_subtitle_source}

  defp transcription(segments),
    do: {:ok, %{"text" => Enum.map_join(segments, " ", & &1["text"]), "segments" => segments}}
end
