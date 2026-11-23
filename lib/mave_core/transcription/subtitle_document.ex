defmodule MaveCore.Transcription.SubtitleDocument do
  @moduledoc """
  Text-only editing of WebVTT cues while retaining their timing and settings.
  """

  @timing ~r/^(?:\d{2,9}:)?[0-5]\d:[0-5]\d\.\d{3}[ \t]+-->[ \t]+(?:\d{2,9}:)?[0-5]\d:[0-5]\d\.\d{3}(?:\s.*)?$/

  alias MaveCore.AudioDescription.DescriptionDocument
  alias MaveCore.Transcription.SubtitleCues

  def parse(body) when is_binary(body) do
    if String.valid?(body) and byte_size(body) <= 2_000_000 do
      parse_blocks(body)
    else
      {:error, :invalid_document}
    end
  end

  def validate_upload(body) when is_binary(body) and byte_size(body) <= 10_485_760 do
    if String.valid?(body) and not String.contains?(body, <<0>>) do
      [header | blocks] =
        body
        |> String.replace_prefix("\uFEFF", "")
        |> String.replace(["\r\n", "\r"], "\n")
        |> String.split(~r/\n[\t ]*\n(?:[\t ]*\n)*/, trim: false)

      if Regex.match?(~r/\AWEBVTT(?:[ \t\n]|\z)/, header) and
           not String.contains?(header, "-->") and valid_upload_blocks?(blocks) do
        :ok
      else
        {:error, :invalid_vtt}
      end
    else
      {:error, :invalid_vtt}
    end
  end

  def validate_upload(_body), do: {:error, :invalid_vtt}

  defp valid_upload_blocks?(blocks) do
    Enum.reduce_while(blocks, false, fn block, has_cue ->
      cond do
        String.trim(block) == "" ->
          {:cont, has_cue}

        Regex.match?(~r/\A(?:NOTE(?:[ \t\n]|\z)|STYLE\n|REGION\n)/, block) ->
          upload_metadata_result(block, has_cue)

        valid_upload_cue?(block) ->
          {:cont, true}

        true ->
          {:halt, false}
      end
    end)
  end

  defp upload_metadata_result(block, has_cue) do
    if String.contains?(block, "-->"), do: {:halt, false}, else: {:cont, has_cue}
  end

  defp valid_upload_cue?(block) do
    lines = String.split(block, "\n", parts: 2)

    [timing | payload] =
      case lines do
        [identifier, rest] ->
          if String.contains?(identifier, "-->"),
            do: lines,
            else: String.split(rest, "\n", parts: 2)

        _ ->
          lines
      end

    Regex.match?(@timing, timing) and end_seconds(timing) > start_seconds(timing) and
      not String.contains?(List.first(payload) || "", "-->")
  end

  def parse_editor_vtt(body, duration, kind) do
    with {:ok, document} <- parse(body),
         false <- String.contains?(document.header, "-->"),
         cues = cues(document),
         moments =
           Enum.map(cues, &%{"id" => &1.id, "start" => &1.start_seconds, "text" => &1.text}),
         {:ok, _} <-
           DescriptionDocument.validate(
             moments,
             duration,
             if(kind == :subtitle, do: 100_000, else: 500)
           ),
         true <-
           Enum.all?(
             cues,
             &(&1.end_seconds > &1.start_seconds and &1.end_seconds <= duration and
                 String.trim(&1.text) != "" and
                 not String.contains?(String.replace_prefix(&1.raw, &1.prefix, ""), "-->"))
           ),
         :ok <-
           DescriptionDocument.validate_time_labels(
             moments,
             if(kind == :subtitle, do: original_starts(document), else: %{})
           ) do
      {:ok, document, moments}
    else
      _ -> {:error, :invalid_webvtt}
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

  def transcript_json(document, previous) do
    existing =
      for %{"start" => start, "end" => stop, "text" => text, "words" => [_ | _] = words} <-
            List.wrap(previous["segments"]),
          is_number(start) and is_number(stop),
          into: %{} do
        {{round(start * 1000), round(stop * 1000), text}, words}
      end

    cues =
      Enum.map(cues(document), fn cue ->
        %{start: cue.start_seconds, end: cue.end_seconds, text: cue.text}
      end)

    segments = SubtitleCues.json_segments(cues)

    segments =
      Enum.map(segments, fn segment ->
        key = {round(segment["start"] * 1000), round(segment["end"] * 1000), segment["text"]}
        Map.put(segment, "words", Map.get(existing, key, segment["words"]))
      end)

    Jason.encode!(%{
      text: Enum.map_join(cues, " ", &String.replace(&1.text, ~r/\s+/u, " ")),
      segments: segments
    })
  end

  defp start_seconds(timing) do
    [timestamp | _] = String.split(timing, ~r/[ \t]+/)

    timestamp_seconds(timestamp)
  end

  defp end_seconds(timing) do
    [_, _, timestamp | _] = String.split(timing, ~r/[ \t]+/)

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
    [_, start_time, end_time] = Regex.run(~r/^(\S+)\s+-->\s+(\S+)/, timing)

    [start_time, end_time]
    |> Enum.map_join(" – ", fn time ->
      time |> String.replace(~r/^00:(?=\d{2}:)/, "") |> String.replace_suffix(".000", "")
    end)
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

  def windows(document, moments, duration) do
    originals = Map.new(cues(document), &{&1.id, &1})

    moments
    |> Enum.filter(&is_number(&1["start"]))
    |> Enum.chunk_every(2, 1)
    |> Enum.map(fn [moment | following] ->
      start = moment["start"]
      source = originals[moment["id"]]
      next = List.first(following)
      limit = if next, do: next["start"], else: duration

      stop = window_stop(moment, source, start, next, limit, originals)

      %{id: moment["id"], start: start, end: stop}
    end)
  end

  defp window_stop(moment, source, start, next, limit, originals) do
    cond do
      is_number(moment["end"]) ->
        moment["end"]

      source && source.start_seconds == start ->
        unedited_window_stop(source, start, next, limit, originals)

      source ->
        min(start + source.end_seconds - source.start_seconds, limit)

      true ->
        min(start + 2, limit)
    end
  end

  defp unedited_window_stop(source, start, next, limit, originals) do
    if next && limit > start &&
         Map.get(originals[next["id"]] || %{}, :start_seconds) != limit,
       do: min(source.end_seconds, limit),
       else: source.end_seconds
  end

  def original_starts(document), do: Map.new(cues(document), &{&1.id, &1.start_seconds})

  def validate_moments(moments, duration) do
    with {:ok, normalized} <-
           DescriptionDocument.validate(moments, duration, 100_000) do
      valid_ends =
        Enum.all?(moments, fn moment ->
          stop = moment["end"]

          is_nil(stop) or
            (is_number(stop) and is_number(moment["start"]) and
               round(stop * 1000) > round(moment["start"] * 1000) and stop <= duration)
        end)

      if valid_ends do
        {:ok,
         Enum.zip_with(normalized, moments, fn cue, input ->
           Map.merge(cue, Map.take(input, ["end"]))
         end)}
      else
        {:error, :invalid_time_labels}
      end
    end
  end

  def render_moments(document, moments, duration) do
    alias MaveCore.AudioDescription.DescriptionDocument

    with {:ok, moments} <- validate_moments(moments, duration),
         :ok <- DescriptionDocument.validate_time_labels(moments, original_starts(document)),
         true <-
           moments != [] and
             Enum.all?(moments, &(is_number(&1["start"]) and String.trim(&1["text"]) != "")),
         windows = windows(document, moments, duration),
         true <- Enum.all?(windows, &(round(&1.end * 1000) > round(&1.start * 1000))) do
      originals = Map.new(cues(document), &{&1.id, &1})

      rendered =
        Enum.zip_with(moments, windows, fn moment, window ->
          render_moment(originals[moment["id"]], moment["text"], window)
        end)

      {blocks, remaining} =
        Enum.map_reduce(document.blocks, rendered, fn
          %{text: _}, [cue | rest] -> {cue, rest}
          %{text: _}, [] -> {nil, []}
          block, rest -> {block.raw, rest}
        end)

      body =
        Enum.join(Enum.reject([document.header | blocks] ++ remaining, &is_nil/1), "\n\n") <> "\n"

      if byte_size(body) <= 2_000_000, do: {:ok, body}, else: {:error, :invalid_text}
    else
      false -> {:error, :invalid_text}
      error -> error
    end
  end

  defp render_moment(nil, text, window),
    do: timestamp(window.start) <> " --> " <> timestamp(window.end) <> "\n" <> escape_text(text)

  defp render_moment(source, text, window) do
    block =
      if String.trim(source.text) == text,
        do: source.raw,
        else: render_block(source, %{source.id => text})

    if window.start == source.start_seconds and window.end == source.end_seconds do
      block
    else
      prefix =
        Regex.replace(
          ~r/^\d[\d:.]*[ \t]+-->[ \t]+[\d:.]+/m,
          source.prefix,
          timestamp(window.start) <> " --> " <> timestamp(window.end)
        )

      prefix <> String.replace_prefix(block, source.prefix, "")
    end
  end

  defp timestamp(seconds) do
    ms = round(seconds * 1000)

    :io_lib.format("~2..0B:~2..0B:~2..0B.~3..0B", [
      div(ms, 3_600_000),
      rem(div(ms, 60_000), 60),
      rem(div(ms, 1000), 60),
      rem(ms, 1000)
    ])
    |> IO.iodata_to_binary()
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
