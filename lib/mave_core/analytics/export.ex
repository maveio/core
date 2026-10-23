defmodule MaveCore.Analytics.Export do
  @moduledoc "Bounded video batches and CSV encoding shared by dashboard exports."

  import Ecto.Query

  alias MaveCore.Analytics.Range
  alias MaveCore.Analytics.RangeReport
  alias MaveCore.Embeds.Embed
  alias MaveCore.Repo
  alias MaveCore.Spaces.Space

  @batch_size 250

  def header, do: "embed_id,title,views,watch_seconds,completion_rate\r\n"

  def batches(%Space{} = space, %Range{} = range) do
    Stream.resource(fn -> nil end, &next_batch(space, range, &1), fn _ -> :ok end)
  end

  def row(values) do
    values |> Enum.map(&field/1) |> Enum.intersperse(",") |> then(&[&1, "\r\n"])
  end

  defp next_batch(_space, _range, :done), do: {:halt, :done}

  defp next_batch(space, range, after_id) do
    query =
      from(e in Embed,
        left_join: a in assoc(e, :asset),
        where: e.space_id == ^space.id and e.type == :video and is_nil(e.deleted_at),
        order_by: e.id,
        limit: @batch_size,
        select: %{id: e.id, hash: e.hash, title: a.name}
      )

    query = if after_id, do: where(query, [e], e.id > ^after_id), else: query
    videos = Repo.all(query)
    export_batch(space, range, videos)
  end

  defp export_batch(_space, _range, []), do: {:halt, :done}

  defp export_batch(space, range, videos) do
    case RangeReport.videos(space.hash, range, Enum.map(videos, & &1.hash)) do
      {:ok, metrics} ->
        rows = Enum.map(videos, &video_row(space.hash, &1, metrics))
        {[{:ok, rows}], List.last(videos).id}

      {:error, reason} ->
        {[{:error, reason}], :done}
    end
  end

  defp video_row(space_hash, video, metrics) do
    result = Map.get(metrics, video.hash, RangeReport.empty_metrics())

    row([
      space_hash <> video.hash,
      video.title || "",
      result.views,
      result.watch_seconds,
      result.completion_rate
    ])
  end

  defp field(nil), do: ""

  defp field(value) when is_binary(value) do
    # Quote every string and neutralize spreadsheet formulas, including values
    # prefixed by whitespace/control characters.
    safe = if value =~ ~r/^[\s\x00-\x1F]*[=+@-]|^[\t\r\n]/u, do: "'" <> value, else: value
    ["\"", String.replace(safe, "\"", "\"\""), "\""]
  end

  defp field(value), do: to_string(value)
end
