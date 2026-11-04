defmodule MaveCore.AudioDescription.Timeline do
  @moduledoc """
  Pure timing logic for audio descriptions: where speech is, which scenes the
  video has, and where each spoken description goes.

  Descriptions play in the pauses of the original speech. When one doesn't fit a
  nearby pause it plays at its own moment and the original audio is ducked under
  it. A description always stays with its scene: it starts while the scene is on
  screen and at least half of it is spoken during the scene.

  Intervals are maps `%{start: seconds, end: seconds}`. All results are rounded
  to milliseconds.
  """

  # Words closer together than this belong to the same stretch of speech.
  @merge_gap_seconds 0.5
  # Margin kept around speech, so a description never clips a syllable.
  @speech_pad_seconds 0.15
  # How far a description may move away from its moment to fit in a pause.
  @max_shift_later 2.0
  @max_shift_earlier 1.0
  # Silence between two consecutive descriptions.
  @breath_seconds 0.15
  # Shortest scene: quick cuts are grouped until a scene is at least this long.
  @min_scene_seconds 3.0
  @epsilon 1.0e-9

  def min_scene_seconds, do: @min_scene_seconds

  @doc "Padded, merged stretches of speech within `[0, duration]` from word or segment timings."
  def speech_from_words(
        words,
        duration,
        merge_gap \\ @merge_gap_seconds,
        pad \\ @speech_pad_seconds
      ) do
    words
    |> Enum.filter(&(&1.end > &1.start))
    |> Enum.sort_by(& &1.start)
    |> Enum.reduce([], fn word, acc ->
      case acc do
        [prev | rest] when word.start - prev.end <= merge_gap ->
          [%{prev | end: max(prev.end, word.end)} | rest]

        _ ->
          [%{start: word.start, end: word.end} | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.reduce([], fn stretch, acc ->
      start = max(0.0, stretch.start - pad)
      stop = min(duration * 1.0, stretch.end + pad)

      cond do
        stop <= start -> acc
        match?([prev | _] when start <= prev.end, acc) -> merge_into_head(acc, stop)
        true -> [%{start: start, end: stop} | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(&round_interval/1)
  end

  defp merge_into_head([prev | rest], stop), do: [%{prev | end: max(prev.end, stop)} | rest]

  @doc "The pauses between speech, within `[0, duration]`."
  def free_gaps(speech, duration) do
    duration = duration * 1.0

    {gaps, cursor} =
      Enum.reduce_while(speech, {[], 0.0}, fn stretch, {gaps, cursor} ->
        gaps =
          if stretch.start > cursor,
            do: [%{start: cursor, end: min(stretch.start, duration)} | gaps],
            else: gaps

        cursor = max(cursor, stretch.end)
        if cursor >= duration, do: {:halt, {gaps, cursor}}, else: {:cont, {gaps, cursor}}
      end)

    gaps = if cursor < duration, do: [%{start: cursor, end: duration} | gaps], else: gaps

    gaps
    |> Enum.reverse()
    |> Enum.filter(&(&1.end - &1.start > 0.001))
    |> Enum.map(&round_interval/1)
  end

  @doc "Shot intervals from cut times."
  def shots_from_cuts(cuts, duration) do
    inner = cuts |> Enum.filter(&(&1 > 0 and &1 < duration)) |> Enum.sort()

    ([0.0 | inner] ++ [duration * 1.0])
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.filter(fn [a, b] -> b > a end)
    |> Enum.map(fn [a, b] -> round_interval(%{start: a, end: b}) end)
  end

  @doc """
  Group consecutive short shots into scenes of at least `min_seconds`, so a fast
  montage gets described (what its cuts show together) instead of not at all. A
  short remainder at the end joins the scene before it.
  """
  def scenes_from_shots(shots, min_seconds \\ @min_scene_seconds) do
    {scenes, current} =
      Enum.reduce(shots, {[], nil}, fn shot, {scenes, current} ->
        current = if current, do: %{current | end: shot.end}, else: Map.take(shot, [:start, :end])

        if current.end - current.start >= min_seconds,
          do: {[current | scenes], nil},
          else: {scenes, current}
      end)

    scenes =
      case {current, scenes} do
        {nil, _} -> scenes
        {current, []} -> [current]
        {current, [last | rest]} -> [%{last | end: current.end} | rest]
      end

    scenes |> Enum.reverse() |> Enum.map(&round_interval/1)
  end

  @doc "Words a description can have to be spoken within `seconds` (about 2.5 words per second)."
  def word_budget(seconds), do: max(0, floor((seconds - 0.2) * 2.5))

  @doc """
  Scenes, speech and numbered pauses (with a word budget each) as context for the
  description model. With a `window`, only what overlaps it is listed, keeping the
  global numbers.
  """
  def timing_prompt(speech, scenes, duration, window \\ nil) do
    gaps = free_gaps(speech, duration)
    in_window? = fn i -> is_nil(window) or (i.start < window.end and i.end > window.start) end

    scene_lines =
      scenes
      |> Enum.with_index()
      |> Enum.filter(fn {scene, _} -> in_window?.(scene) end)
      |> Enum.map(fn {scene, i} -> "S#{i}: #{format_interval(scene)}" end)

    gap_lines =
      gaps
      |> Enum.with_index()
      |> Enum.filter(fn {gap, _} -> in_window?.(gap) end)
      |> Enum.map(fn {gap, i} ->
        length = gap.end - gap.start

        "P#{i}: #{format_interval(gap)} (#{format_decimal(length, 1)} s, max #{word_budget(length)} words)"
      end)

    speech_in_window = Enum.filter(speech, in_window?)

    speech_line =
      if speech_in_window == [],
        do: "none",
        else: Enum.map_join(speech_in_window, ", ", &format_interval/1)

    Enum.join(
      ["Scenes (index: seconds), from cut detection; quick cuts are grouped into one scene:"] ++
        if(scenes == [], do: ["S0: the whole video"], else: scene_lines) ++
        [
          "Speech (seconds): #{speech_line}",
          "Pauses without speech (index: seconds, length, max words):"
        ] ++ if(gap_lines == [], do: ["none"], else: gap_lines),
      "\n"
    )
  end

  @doc """
  Stills for image-only vision models: at least one per camera shot, and one per
  `every` seconds in longer shots, spread inside the shot (never on the cut). Each
  still carries the index of the scene it belongs to.
  """
  def plan_stills(scenes, duration, every \\ 3, cuts \\ nil) do
    cuts = cuts || scenes
    list = if cuts == [], do: [%{start: 0.0, end: duration * 1.0}], else: cuts

    Enum.flat_map(list, &shot_stills(&1, scenes, every))
  end

  defp shot_stills(%{start: start, end: stop}, _scenes, _every) when stop <= start, do: []

  defp shot_stills(shot, scenes, every) do
    length = shot.end - shot.start
    count = max(1, round(length / every))

    for k <- 0..(count - 1) do
      time = round3(shot.start + (k + 0.5) * length / count)
      %{scene: scene_index(scenes, time), time: time}
    end
  end

  defp scene_index(scenes, time) do
    Enum.find_index(scenes, &(time >= &1.start and time < &1.end)) ||
      max(0, length(scenes) - 1)
  end

  @doc "Stills in batches of at most `max` (the provider's image limit per prompt)."
  def batch_stills(stills, max \\ 12), do: Enum.chunk_every(stills, max)

  @doc """
  Pin each cue to the scene it describes and, when the model chose one, the pause
  it goes in. A pause that doesn't overlap the scene is ignored (the description
  would be out of sync); `-1` means during speech.
  """
  def snap_cues(cues, gaps, scenes), do: Enum.map(cues, &snap_cue(&1, gaps, scenes))

  defp snap_cue(cue, gaps, scenes) do
    scene = cue_scene(cue, scenes)
    {lo, hi} = cue_bounds(scene, indexed(gaps, cue[:pause]))
    start = min_inf(max(cue.start, lo), max_inf(lo, sub_inf(hi, 0.3)))
    stop = min_inf(hi, max(cue.end, start + 0.5))

    %{start: round3(start), end: round3(max(stop, start + 0.1)), text: cue.text}
    |> put_scene(scene)
  end

  defp cue_scene(cue, scenes) do
    indexed(scenes, cue[:scene]) ||
      Enum.find(scenes, &(cue.start >= &1.start and cue.start < &1.end))
  end

  defp indexed(list, index) when is_integer(index) and index >= 0, do: Enum.at(list, index)
  defp indexed(_list, _index), do: nil

  # Within the scene; within the chosen pause too when that pause overlaps the scene.
  defp cue_bounds(nil, gap), do: narrow_to_gap({0.0, :infinity}, gap)
  defp cue_bounds(scene, gap), do: narrow_to_gap({scene.start, scene.end}, gap)

  defp narrow_to_gap({lo, hi}, %{start: gap_start, end: gap_end}) do
    if lt?(gap_start, hi) and gap_end > lo,
      do: {max(lo, gap_start), min_inf(hi, gap_end)},
      else: {lo, hi}
  end

  defp narrow_to_gap(bounds, nil), do: bounds

  @doc """
  Place every spoken description. `lengths` are clip lengths in samples.

  Returns `%{placements: [%{index, start, length}], cues: [...], ducks: [...],
  skipped: [index], total_samples: n}`. `cues` are timed to when each description
  is actually spoken; `ducks` are where the original audio is lowered.
  """
  def plan_timeline(cues, lengths, speech, duration, sample_rate) do
    gaps = free_gaps(speech, duration)
    duration = duration * 1.0

    initial = %{cursor: 0.0, placements: [], cues: [], ducks: [], skipped: []}

    state =
      cues
      |> Enum.with_index()
      |> Enum.reduce(initial, fn {cue, index}, state ->
        length = Enum.at(lengths, index) || 0

        if length <= 0,
          do: state,
          else: place(cue, index, length, sample_rate, gaps, speech, duration, state)
      end)

    timed = Enum.reverse(state.cues)
    last_end = if timed == [], do: 0.0, else: List.last(timed).end

    %{
      placements: Enum.reverse(state.placements),
      cues: timed,
      ducks: Enum.reverse(state.ducks),
      skipped: Enum.reverse(state.skipped),
      total_samples: round(max(duration, last_end) * sample_rate)
    }
  end

  defp place(cue, index, length, sample_rate, gaps, speech, duration, state) do
    seconds = length / sample_rate
    scene = cue[:scene]
    scene_start = if scene, do: scene.start, else: :neg_infinity
    latest_start = if scene, do: scene.end - seconds / 2, else: :infinity

    case pause_start(cue, seconds, gaps, state.cursor, scene_start, latest_start) do
      nil -> place_over_speech(cue, index, length, seconds, sample_rate, speech, duration, state)
      start -> put_placement(state, cue, index, length, start, seconds, sample_rate, false)
    end
  end

  # 1. A pause near the cue, within its scene, that holds the whole clip.
  defp pause_start(cue, seconds, gaps, cursor, scene_start, latest_start) do
    gaps
    |> Enum.flat_map(fn gap ->
      lo = Enum.max([gap.start, cursor, cue.start - @max_shift_earlier, num(scene_start)])
      hi = min_inf(min(gap.end - seconds, cue.start + @max_shift_later), latest_start)
      if lo > hi + @epsilon, do: [], else: [min(max(cue.start, lo), hi)]
    end)
    |> Enum.min_by(&abs(&1 - cue.start), fn -> nil end)
  end

  # 2. Otherwise at its own moment in the scene (after the previous description), over the speech.
  defp place_over_speech(cue, index, length, seconds, sample_rate, speech, duration, state) do
    scene = cue[:scene]
    latest_start = if scene, do: scene.end - seconds / 2, else: :infinity
    start = Enum.max([cue.start, state.cursor, if(scene, do: scene.start, else: cue.start)])
    start = if start + seconds > duration, do: max(state.cursor, duration - seconds), else: start

    if gt_inf?(start, latest_start) or start + seconds > duration + 0.5 do
      %{state | skipped: [index | state.skipped]}
    else
      ducked? = Enum.any?(speech, &(start < &1.end and &1.start < start + seconds))
      put_placement(state, cue, index, length, start, seconds, sample_rate, ducked?)
    end
  end

  defp put_placement(state, cue, index, length, start, seconds, sample_rate, ducked?) do
    stop = start + seconds
    timed = %{start: round3(start), end: round3(stop), text: cue.text} |> put_scene(cue[:scene])
    duck = %{start: round3(start), end: round3(stop)}

    %{
      state
      | cursor: stop + @breath_seconds,
        placements: [
          %{index: index, start: round(start * sample_rate), length: length} | state.placements
        ],
        cues: [timed | state.cues],
        ducks: if(ducked?, do: [duck | state.ducks], else: state.ducks)
    }
  end

  defp put_scene(cue, nil), do: cue
  defp put_scene(cue, scene), do: Map.put(cue, :scene, Map.take(scene, [:start, :end]))

  defp num(:neg_infinity), do: -1.0e18
  defp num(value), do: value

  defp min_inf(:infinity, b), do: b
  defp min_inf(a, :infinity), do: a
  defp min_inf(a, b), do: min(a, b)

  defp max_inf(_a, :infinity), do: :infinity
  defp max_inf(a, b), do: max(a, b)

  defp sub_inf(:infinity, _b), do: :infinity
  defp sub_inf(a, b), do: a - b

  defp lt?(_a, :infinity), do: true
  defp lt?(a, b), do: a < b

  defp gt_inf?(_a, :infinity), do: false
  defp gt_inf?(a, b), do: a > b + @epsilon

  defp round_interval(%{start: start, end: stop}), do: %{start: round3(start), end: round3(stop)}

  @doc false
  def round3(value), do: Float.round(value * 1.0, 3)

  defp format_interval(i), do: "#{format_decimal(i.start, 2)}-#{format_decimal(i.end, 2)}"

  defp format_decimal(value, decimals),
    do: :erlang.float_to_binary(value * 1.0, decimals: decimals)
end
