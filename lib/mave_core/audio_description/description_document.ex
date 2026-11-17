defmodule MaveCore.AudioDescription.DescriptionDocument do
  @moduledoc "Editable description moments and shared speech-pause budgets."

  alias MaveCore.AudioDescription.SpeechTiming
  alias MaveCore.Transcription.SubtitleDocument

  @max_moments 500
  @max_bytes 2_000_000
  @earlier 1.0
  @later 2.0
  @breath 0.15

  def from_vtt(document) do
    Enum.map(SubtitleDocument.cues(document), fn cue ->
      %{"id" => cue.id, "start" => cue.start_seconds, "text" => cue.text}
    end)
  end

  def validate(moments, duration) when is_list(moments) and is_number(duration) do
    valid =
      length(moments) <= @max_moments and
        Enum.all?(moments, &valid_moment?(&1, duration)) and
        length(Enum.uniq_by(moments, & &1["id"])) == length(moments) and
        Enum.reduce(moments, 0, &(byte_size(&1["text"]) + &2)) <= @max_bytes

    if valid,
      do: {:ok, Enum.map(moments, &Map.take(&1, ~w(id start text)))},
      else: {:error, :invalid_moments}
  end

  def validate(_, _), do: {:error, :invalid_moments}

  def validate_time_labels(moments) do
    times = moments |> Enum.map(& &1["start"]) |> Enum.reject(&is_nil/1)
    ordered? = times |> Enum.chunk_every(2, 1, :discard) |> Enum.all?(fn [a, b] -> a < b end)

    unfinished? =
      Enum.any?(moments, &Regex.match?(~r/\[[0-9.,-]*:[0-9:.,-]*\]?|\[[0-9.,-]*$/, &1["text"]))

    if ordered? and not unfinished?, do: :ok, else: {:error, :invalid_time_labels}
  end

  defp valid_moment?(%{"id" => id, "start" => start, "text" => text}, duration) do
    is_binary(id) and Regex.match?(~r/^[A-Za-z0-9_-]{1,64}$/, id) and
      (is_nil(start) or (is_number(start) and start >= 0 and start < duration)) and
      is_binary(text) and String.valid?(text) and byte_size(text) <= 20_000
  end

  defp valid_moment?(_, _), do: false

  def groups(moments, gaps, source_document, language) do
    sources = Map.new(SubtitleDocument.cues(source_document), &{&1.id, &1})

    moments
    |> Enum.with_index()
    |> Enum.group_by(fn {moment, _index} -> gap_index(moment["start"], gaps) end)
    |> Enum.reject(fn {_key, entries} -> spoken_entries(entries) == [] end)
    |> Enum.map(fn {key, entries} ->
      group(key, entries, gaps, sources, language)
    end)
    |> Enum.sort_by(& &1.position)
  end

  def playback_windows(moments, source_document, language, duration) do
    sources = Map.new(SubtitleDocument.cues(source_document), &{&1.id, &1})

    moments
    |> Enum.filter(
      &(is_number(&1["start"]) and SpeechTiming.editor_spoken_text(&1["text"]) != "")
    )
    |> Enum.sort_by(& &1["start"])
    |> Enum.chunk_every(2, 1)
    |> Enum.map(fn [moment | following] ->
      next_start =
        case following do
          [next] -> next["start"]
          [] -> duration
        end

      %{
        id: moment["id"],
        start: moment["start"],
        end: min(moment["start"] + estimated_seconds(moment, sources, language), next_start)
      }
    end)
  end

  defp gap_index(nil, _gaps), do: :untimed
  defp gap_index(_start, nil), do: :unknown

  defp gap_index(start, gaps) do
    gaps
    |> Enum.with_index()
    |> Enum.filter(fn {gap, _} -> gap.end >= start - @earlier and gap.start <= start + @later end)
    |> Enum.min_by(fn {gap, _} -> max(gap.start - start, max(start - gap.end, 0)) end, fn ->
      nil
    end)
    |> case do
      nil -> :unplaced
      {_gap, index} -> index
    end
  end

  defp group(key, entries, _gaps, _sources, _language) when is_atom(key) do
    %{
      id: Atom.to_string(key),
      state: Atom.to_string(key),
      after_id: entries |> List.last() |> elem(0) |> Map.fetch!("id"),
      position: entries |> hd() |> elem(1),
      count: length(spoken_entries(entries))
    }
  end

  defp group(key, entries, gaps, sources, language) do
    gap = Enum.at(gaps, key)
    moments = entries |> spoken_entries() |> Enum.map(&elem(&1, 0))
    start = max(gap.start, hd(moments)["start"] - @earlier)

    {stop, late?, _} =
      Enum.reduce(moments, {start, false, false}, fn moment, {cursor, late?, spoken?} ->
        if SpeechTiming.editor_spoken_text(moment["text"]) == "" do
          {cursor, late?, spoken?}
        else
          seconds = estimated_seconds(moment, sources, language)
          next = max(cursor + if(spoken?, do: @breath, else: 0), moment["start"] - @earlier)
          {next + seconds, late? or next > moment["start"] + @later, true}
        end
      end)

    ordered? = moments |> Enum.map(& &1["start"]) |> then(&(&1 == Enum.sort(&1)))

    state =
      cond do
        not ordered? -> "order"
        stop > gap.end + 0.005 -> "over"
        late? -> "timing"
        true -> "within"
      end

    %{
      id: "gap-#{key}",
      state: state,
      start: gap.start,
      end: gap.end,
      available: Float.round(max(0.0, gap.end - start), 1),
      remaining: Float.round(max(0.0, gap.end - stop), 1),
      excess: Float.round(max(0.0, stop - gap.end), 1),
      after_id: entries |> List.last() |> elem(0) |> Map.fetch!("id"),
      count: length(moments),
      position: entries |> hd() |> elem(1)
    }
  end

  defp spoken_entries(entries) do
    Enum.reject(entries, fn {moment, _} ->
      SpeechTiming.editor_spoken_text(moment["text"]) == ""
    end)
  end

  defp estimated_seconds(moment, sources, language) do
    case Map.get(sources, moment["id"]) do
      nil ->
        text = SpeechTiming.editor_spoken_text(moment["text"])

        if text == "",
          do: 0.0,
          else: SpeechTiming.estimate(text, language)["estimated_seconds"]

      source ->
        SpeechTiming.estimate_edit(
          moment["text"],
          source.text,
          source.end_seconds - source.start_seconds,
          language
        )
    end
  end
end
