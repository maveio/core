defmodule MaveCore.AudioDescription.Budget do
  @moduledoc "Time budgets for inline descriptions that preserve dialogue and finish before the video."

  alias MaveCore.AudioDescription.{Cues, Timeline}

  @end_margin 0.3
  @breath 0.15
  @minimum_slot 0.8
  @max_slot 8.0

  def end_margin, do: @end_margin

  def word_limit(speech, duration, category) do
    available =
      Enum.reduce(Timeline.free_gaps(speech, max(0.0, duration - @end_margin)), 0.0, fn gap,
                                                                                        sum ->
        sum + gap.end - gap.start
      end)

    density =
      cond do
        category == "music" -> 0.25
        duration <= 15 -> 0.45
        category == "interview" -> 0.35
        category == "tutorial" -> 0.55
        true -> 0.65
      end

    floor(min(available, duration * density) * 2.5)
  end

  @doc "Reserve speech pauses first and optional last-resort ducking windows for essential information."
  def allocate(cues, speech, duration, category) do
    cues = bound_events(cues, duration)
    gaps = Timeline.free_gaps(speech, max(0.0, duration - @end_margin))
    limit = word_limit(speech, duration, category)

    {accepted, rejected, _gaps, _remaining} =
      cues
      |> Enum.with_index()
      |> Enum.sort_by(fn {cue, index} ->
        {-priority(cue), if(cue[:kind] == "text", do: 0, else: 1), index}
      end)
      |> Enum.reduce({[], [], gaps, limit}, fn {cue, index},
                                               {accepted, rejected, free, remaining} ->
        case reserve(cue, free, remaining) do
          nil when cue.priority == 3 ->
            planned = cue |> Map.put(:window, nil) |> Map.put(:max_words, 0)
            {[{index, planned} | accepted], rejected, free, remaining}

          nil ->
            {accepted, [rejection(cue, "no_safe_time") | rejected], free, remaining}

          window ->
            planned =
              cue
              |> Map.put(:window, window)
              |> Map.merge(%{start: window.start, end: window.end})

            words = min(Timeline.word_budget(window.end - window.start), remaining)
            planned = Map.put(planned, :max_words, words)
            {[{index, planned} | accepted], rejected, subtract(free, window), remaining - words}
        end
      end)

    {planned, fallback_rejected} = add_fallbacks(accepted, duration)

    %{
      cues: Enum.sort_by(planned, fn cue -> (cue[:window] || cue[:duck_window]).start end),
      rejected: Enum.reverse(rejected) ++ fallback_rejected,
      word_limit: limit
    }
  end

  # Coarse scene detection can group several distinct actions. A cue may not
  # borrow the next action's time just because both share a detected scene.
  defp bound_events(cues, duration) do
    sorted = Enum.sort_by(cues, & &1.start)

    sorted
    |> Enum.with_index()
    |> Enum.map(fn {cue, index} ->
      next = sorted |> Enum.drop(index + 1) |> Enum.find(&(rank(&1) >= rank(cue)))
      next_start = if next, do: max(cue.start, next.start - 0.5), else: duration
      scene = Map.get(cue, :scene, %{start: 0.0, end: duration})

      Map.put(cue, :scene, %{
        start: if(cue[:visual_window], do: scene.start, else: max(scene.start, cue.start - 0.5)),
        end: min(scene.end, next_start)
      })
    end)
  end

  defp add_fallbacks(accepted, duration) do
    accepted
    |> Enum.sort_by(fn {index, cue} ->
      {-priority(cue), if(cue[:kind] == "text", do: 0, else: 1), index}
    end)
    |> Enum.reduce({[], [], []}, &add_fallback(&1, accepted, duration, &2))
    |> then(fn {planned, rejected, _} -> {planned, Enum.reverse(rejected)} end)
  end

  defp add_fallback({index, cue}, accepted, duration, {planned, rejected, reserved}) do
    free =
      Enum.reduce(accepted, [%{start: 0.0, end: max(0.0, duration - @end_margin)}], fn
        {^index, _}, gaps -> gaps
        {_, %{window: nil}}, gaps -> gaps
        {_, other}, gaps -> subtract(gaps, other.window)
      end)

    free = Enum.reduce(reserved, free, &subtract(&2, &1))

    fallback =
      if priority(cue) == 3,
        do:
          reserve_window(
            cue,
            free,
            min(4.0, max(1.2, Cues.estimate_speech_seconds(cue.text) * 1.5))
          )

    cue = if fallback, do: Map.put(cue, :duck_window, fallback), else: cue

    if cue.window || fallback do
      reserved = if fallback, do: [fallback | reserved], else: reserved
      {[cue | planned], rejected, reserved}
    else
      {planned, [rejection(cue, "no_safe_time") | rejected], reserved}
    end
  end

  def rejection(cue, reason),
    do: %{"text" => cue.text, "reason" => reason, "priority" => Map.get(cue, :priority, 2)}

  defp rank(cue), do: {priority(cue), if(cue[:kind] == "text", do: 1, else: 0)}

  defp priority(cue) do
    case Map.get(cue, :priority) do
      value when value in [1, 2, 3] -> value
      _ -> 2
    end
  end

  defp reserve(_cue, _gaps, remaining) when remaining < 2, do: nil

  defp reserve(cue, gaps, remaining) do
    target_seconds =
      if cue[:kind] == "text",
        do: @max_slot,
        else:
          min(@max_slot, max(@minimum_slot, Cues.estimate_speech_seconds(cue.text) * 1.2 + 0.4))

    max_seconds = min(target_seconds, remaining / 2.5 + 0.2)
    reserve_window(cue, gaps, max_seconds)
  end

  defp reserve_window(cue, gaps, max_seconds) do
    scene = Map.get(cue, :scene, %{start: 0.0, end: 1.0e9})

    gaps
    |> Enum.flat_map(fn gap ->
      earliest = if cue[:visual_window], do: scene.start, else: max(scene.start, cue.start - 1.0)
      start = max(gap.start, earliest)
      stop = min(gap.end, scene.end)
      start = min(max(start, cue.start), max(start, stop - max_seconds))
      stop = min(stop, start + max_seconds)

      if (cue[:kind] == "text" or start <= cue.start + 2.0) and stop - start >= @minimum_slot,
        do: [%{start: Timeline.round3(start), end: Timeline.round3(stop)}],
        else: []
    end)
    |> Enum.min_by(&abs(&1.start - cue.start), fn -> nil end)
  end

  defp subtract(gaps, window) do
    Enum.flat_map(gaps, fn gap ->
      if window.end <= gap.start or window.start >= gap.end do
        [gap]
      else
        [
          %{start: gap.start, end: window.start - @breath},
          %{start: window.end + @breath, end: gap.end}
        ]
        |> Enum.filter(&(&1.end - &1.start >= @minimum_slot))
      end
    end)
  end
end
