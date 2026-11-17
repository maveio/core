defmodule MaveCore.Search.Document do
  @moduledoc """
  Turns the text Core already has about a video into searchable moments.

  Visual moments come from the timestamped observations that audio description
  collects for every sampled frame; transcript moments come from subtitle cues.
  This module is pure: it neither calls a provider nor touches storage.
  """

  alias MaveCore.AudioDescription.Cues

  @schema_version 1
  @max_moments 5_000
  @max_text_length 2_000
  # Subtitle cues are a few words long. Grouping them keeps a phrase that spans
  # two cues findable, while a result still starts within a few seconds of it.
  @transcript_window_seconds 8.0
  @transcript_window_gap_seconds 2.0
  @transcript_window_length 320

  @type moment :: %{source: String.t(), start: float(), end: float(), text: String.t()}

  def schema_version, do: @schema_version

  @doc "The private JSON document a flow step stores and Core indexes."
  def to_json(moments, language) do
    %{
      "schema_version" => @schema_version,
      "language" => language,
      "moments" =>
        Enum.map(moments, fn moment ->
          %{
            "source" => moment.source,
            "start" => moment.start,
            "end" => moment.end,
            "text" => moment.text
          }
        end)
    }
  end

  @doc "Reads moments back from a stored document, dropping malformed entries."
  @spec from_json(term()) :: {:ok, [moment()], String.t() | nil} | {:error, :invalid_document}
  def from_json(%{"schema_version" => @schema_version, "moments" => moments} = document)
      when is_list(moments) do
    language = if is_binary(document["language"]), do: document["language"]

    moments =
      moments
      |> Enum.flat_map(fn
        %{"source" => source, "start" => start, "end" => stop, "text" => text}
        when source in ["visual", "transcript"] and is_number(start) and is_number(stop) and
               is_binary(text) ->
          moment(source, start, stop, text)

        _other ->
          []
      end)
      |> Enum.take(@max_moments)

    {:ok, moments, language}
  end

  def from_json(_document), do: {:error, :invalid_document}

  @doc """
  One moment per observed frame. A frame's moment lasts until the next sampled
  frame; consecutive frames with the same description become one longer moment.
  """
  @spec visual_moments([map()], number()) :: [moment()]
  def visual_moments(observations, duration) when is_list(observations) do
    observations
    |> Enum.filter(&(is_map(&1) and is_number(&1["time"])))
    |> Enum.sort_by(& &1["time"])
    |> Enum.map(&{&1["time"] * 1.0, observation_text(&1)})
    |> Enum.reject(fn {_time, text} -> text == "" end)
    |> then(fn frames ->
      ends = frames |> Enum.drop(1) |> Enum.map(&elem(&1, 0))
      last = if is_number(duration) and duration > 0, do: [duration * 1.0], else: []
      Enum.zip(frames, ends ++ last ++ [nil])
    end)
    |> Enum.reduce([], fn {{start, text}, stop}, acc ->
      stop = max(stop || start + 2.0, start)

      case acc do
        [%{text: ^text} = previous | rest] -> [%{previous | end: stop} | rest]
        _ -> moment("visual", start, stop, text) ++ acc
      end
    end)
    |> Enum.reverse()
  end

  def visual_moments(_observations, _duration), do: []

  @doc "Groups timed transcript segments (`start`, `end`, `text`) into moments."
  @spec transcript_moments([map()]) :: [moment()]
  def transcript_moments(segments) when is_list(segments) do
    segments
    |> Enum.flat_map(&segment/1)
    |> Enum.sort_by(& &1.start)
    |> Enum.reduce([], &add_to_window/2)
    |> Enum.reverse()
    |> Enum.flat_map(&moment("transcript", &1.start, &1.end, &1.text))
  end

  def transcript_moments(_segments), do: []

  @doc "Timed cues of a WebVTT body, for transcripts without a JSON sidecar."
  @spec vtt_segments(binary()) :: [map()]
  def vtt_segments(body) when is_binary(body) do
    body
    |> String.replace("\r\n", "\n")
    |> String.split(~r/\n{2,}/, trim: true)
    |> Enum.flat_map(fn block ->
      lines = String.split(block, "\n", trim: true)

      case Enum.split_while(lines, &(not String.contains?(&1, "-->"))) do
        {_header, [timing | text]} when text != [] -> vtt_cue(timing, text)
        _ -> []
      end
    end)
  end

  def vtt_segments(_body), do: []

  defp vtt_cue(timing, text) do
    with [start, stop | _] <- String.split(timing, "-->"),
         start when is_number(start) <- Cues.parse_timestamp(String.trim(start)),
         stop when is_number(stop) <-
           stop |> String.trim() |> String.split(" ") |> hd() |> Cues.parse_timestamp() do
      [%{"start" => start, "end" => stop, "text" => text |> Enum.join(" ") |> strip_tags()}]
    else
      _ -> []
    end
  end

  defp add_to_window(segment, [window | rest] = acc) do
    if joins_window?(window, segment),
      do: [%{window | end: segment.end, text: window.text <> " " <> segment.text} | rest],
      else: [segment | acc]
  end

  defp add_to_window(segment, []), do: [segment]

  defp joins_window?(window, segment) do
    segment.start - window.end <= @transcript_window_gap_seconds and
      segment.end - window.start <= @transcript_window_seconds and
      String.length(window.text) + String.length(segment.text) < @transcript_window_length
  end

  defp segment(segment) when is_map(segment) do
    start = segment["start"] || segment[:start]
    stop = segment["end"] || segment[:end]
    text = segment["text"] || segment[:text]

    if is_number(start) and is_number(stop) and is_binary(text) and stop >= start and
         String.trim(text) != "",
       do: [%{start: start * 1.0, end: stop * 1.0, text: clean(text)}],
       else: []
  end

  defp segment(_segment), do: []

  # Subtitles burned into the picture repeat the transcript, which is indexed
  # on its own; uncertainties are the model's doubts, not facts to find.
  defp observation_text(observation) do
    subtitles =
      for %{"text" => text, "role" => "subtitle"} <- list(observation["text_elements"]),
          into: MapSet.new(),
          do: clean(text)

    visible =
      observation["visible_text"]
      |> strings()
      |> Enum.reject(&MapSet.member?(subtitles, &1))

    [
      sentence(strings([observation["setting"]])),
      sentence(strings(observation["people_and_objects"])),
      sentence(strings(observation["actions"])),
      sentence(strings(observation["changes"])),
      if(visible != [], do: "On screen: " <> Enum.join(visible, " · "))
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp sentence([]), do: nil

  defp sentence(parts) do
    {first, rest} =
      parts |> Enum.map_join(", ", &String.trim_trailing(&1, ".")) |> String.split_at(1)

    String.upcase(first) <> rest <> "."
  end

  defp strings(values),
    do:
      values
      |> list()
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&clean/1)
      |> Enum.reject(&(&1 == ""))

  defp list(values) when is_list(values), do: values
  defp list(_values), do: []

  defp moment(source, start, stop, text) do
    text = text |> clean() |> String.slice(0, @max_text_length)
    start = Float.round(max(start * 1.0, 0.0), 3)

    if text == "",
      do: [],
      else: [
        %{source: source, start: start, end: Float.round(max(stop * 1.0, start), 3), text: text}
      ]
  end

  defp clean(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp strip_tags(text), do: String.replace(text, ~r/<[^>]*>/, "")
end
