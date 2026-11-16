defmodule MaveCoreWeb.Dashboard.Settings.PipelineGraph do
  @moduledoc """
  Lays out the steps of a resolved pipeline (`MaveCore.Flow.Pipeline.resolve/2`)
  for the encoding editor.

  Stages run left to right in a few columns. Within a stage, steps of the same
  type share a card, which keeps a preset with dozens of steps readable. All
  positions are computed here so the connections of the selected step can be
  drawn without client-side measuring.
  """

  alias MaveCore.Flow.StepRegistry

  # Stages that share a column, in reading order. Stages a step type introduces
  # itself are appended to the last column.
  @columns [
    ~w(ingest audio),
    ~w(video),
    ~w(images subtitles audio_description),
    ~w(publish deliver)
  ]

  @column_width 175
  @column_gap 18
  @padding 14
  @stage_title 26
  @stage_gap 20
  @card_gap 8
  @card_header 26
  @row_height 24
  @card_padding 6
  @compact_height 32

  @sizes %{"SD" => "480p", "HD" => "720p", "FHD" => "1080p", "QHD" => "1440p", "UHD" => "4K"}

  @doc """
  Returns `%{width, height, stages, cards, links}` with pixel positions.

  `selected` is the id of the step whose direct connections become `links`.
  """
  def layout(steps, selected \\ nil) do
    by_stage = Enum.group_by(steps, & &1.stage)
    columns = columns(Map.keys(by_stage))

    {stages, cards, height} =
      columns
      |> Enum.with_index()
      |> Enum.reduce({[], [], 0}, fn {column_stages, index}, {stages, cards, height} ->
        x = @padding + index * (@column_width + @column_gap)

        {column_stages, column_cards, bottom} =
          Enum.reduce(column_stages, {[], [], @padding}, fn stage, {stages, cards, y} ->
            {stage_cards, bottom} =
              stage_cards(Map.get(by_stage, stage, []), steps, x, y + @stage_title)

            {stages ++ [%{stage: stage, x: x, y: y}], cards ++ stage_cards, bottom + @stage_gap}
          end)

        {stages ++ column_stages, cards ++ column_cards,
         max(height, bottom - @stage_gap + @padding)}
      end)

    %{
      width: 2 * @padding + length(columns) * @column_width + (length(columns) - 1) * @column_gap,
      height: height,
      column_width: @column_width,
      stages: stages,
      cards: cards,
      links: links(steps, cards, selected)
    }
  end

  @doc "A step name without the words its card title already shows."
  def short_label(name, title) do
    title_words = title |> String.downcase() |> String.split()

    case name |> String.split() |> Enum.reject(&(String.downcase(&1) in title_words)) do
      [] -> name
      words -> Enum.map_join(words, " ", &Map.get(@sizes, &1, &1))
    end
  end

  defp columns(stages) do
    known = List.flatten(@columns)

    extra =
      Enum.filter(StepRegistry.stages() ++ Enum.sort(stages), &(&1 in stages and &1 not in known))

    @columns
    |> List.update_at(-1, &(&1 ++ Enum.uniq(extra)))
    |> Enum.map(fn column -> Enum.filter(column, &(&1 in stages)) end)
    |> Enum.reject(&(&1 == []))
  end

  defp stage_cards(stage_steps, steps, x, top) do
    stage_steps
    |> Enum.group_by(& &1.type)
    |> Enum.map(fn {_type, members} -> members end)
    |> Enum.sort_by(fn members -> Enum.find_index(steps, &(&1.id == hd(members).id)) end)
    |> Enum.map_reduce(top, fn members, y ->
      card = card(members, x, y)
      {card, y + card.height + @card_gap}
    end)
    |> then(fn {cards, bottom} -> {cards, bottom - @card_gap} end)
  end

  defp card([step], x, y) do
    %{
      key: step.id,
      compact: true,
      title: step.type_name,
      x: x,
      y: y,
      height: @compact_height,
      members: [%{step: step, label: step.name, y: y + div(@compact_height, 2)}]
    }
  end

  defp card([first | _] = members, x, y) do
    rows =
      members
      |> Enum.with_index()
      |> Enum.map(fn {step, index} ->
        %{
          step: step,
          label: short_label(step.name, first.type_name),
          y: y + @card_header + index * @row_height + div(@row_height, 2)
        }
      end)

    %{
      key: first.id,
      compact: false,
      title: first.type_name,
      x: x,
      y: y,
      height: @card_header + length(members) * @row_height + @card_padding,
      members: rows
    }
  end

  defp links(_steps, _cards, nil), do: []

  defp links(steps, cards, selected) do
    anchors =
      for card <- cards, member <- card.members, into: %{} do
        {member.step.id, %{x: card.x, y: member.y}}
      end

    case Enum.find(steps, &(&1.id == selected)) do
      nil ->
        []

      step ->
        needs =
          for id <- step.dependencies,
              anchors[id],
              do: link(anchors[id], anchors[step.id], :needs, id)

        feeds =
          for id <- step.dependents,
              anchors[id],
              do: link(anchors[step.id], anchors[id], :feeds, id)

        needs ++ feeds
    end
  end

  defp link(from, to, kind, id) do
    %{
      id: "#{kind}-#{id}",
      kind: kind,
      path: path(from, to),
      from: start_point(from, to),
      to: end_point(from, to)
    }
  end

  defp start_point(from, to) do
    if to.x < from.x, do: {from.x, from.y}, else: {from.x + @column_width, from.y}
  end

  defp end_point(from, to) do
    cond do
      to.x > from.x -> {to.x, to.y}
      to.x < from.x -> {to.x + @column_width, to.y}
      true -> {to.x + @column_width, to.y}
    end
  end

  defp path(from, to) do
    {x1, y1} = start_point(from, to)
    {x2, y2} = end_point(from, to)

    if from.x == to.x do
      # Same column: loop out through the gap on the right.
      bend = @column_gap + 6
      "M #{x1} #{y1} C #{x1 + bend} #{y1}, #{x2 + bend} #{y2}, #{x2} #{y2}"
    else
      bend = div(abs(x2 - x1), 2) |> max(@column_gap)
      direction = if x2 > x1, do: 1, else: -1

      "M #{x1} #{y1} C #{x1 + direction * bend} #{y1}, #{x2 - direction * bend} #{y2}, #{x2} #{y2}"
    end
  end
end
