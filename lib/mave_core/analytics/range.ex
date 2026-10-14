defmodule MaveCore.Analytics.Range do
  @moduledoc "Validated inclusive UTC calendar dates for analytics."

  @enforce_keys [:from, :to]
  defstruct [:from, :to, granularity: "day"]

  @error "Provide from and to as YYYY-MM-DD UTC dates, at most two calendar years apart, with granularity day, week or month."

  def parse(params) when is_map(params) do
    if Enum.any?(~w(from to granularity), &Map.has_key?(params, &1)) do
      parse_dates(params)
    else
      {:ok, nil}
    end
  end

  def error_message, do: @error

  def params(%__MODULE__{} = range) do
    %{
      "from" => Date.to_iso8601(range.from),
      "to" => Date.to_iso8601(range.to),
      "granularity" => range.granularity
    }
  end

  def bounds(%__MODULE__{} = range) do
    {DateTime.new!(range.from, ~T[00:00:00], "Etc/UTC"),
     DateTime.new!(Date.add(range.to, 1), ~T[00:00:00], "Etc/UTC")}
  end

  def buckets(%__MODULE__{} = range) do
    range.from
    |> Date.range(range.to)
    |> Enum.map(&bucket(&1, range.granularity))
    |> Enum.uniq()
  end

  defp parse_dates(params) do
    with from when is_binary(from) <- params["from"],
         to when is_binary(to) <- params["to"],
         true <- Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, from),
         true <- Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, to),
         {:ok, from} <- Date.from_iso8601(from),
         {:ok, to} <- Date.from_iso8601(to),
         true <- from.year <= 9997 and to.year <= 9998,
         false <- Date.compare(from, to) == :gt,
         false <- Date.compare(to, Date.shift(from, year: 2)) == :gt,
         granularity when granularity in ~w(day week month) <-
           Map.get(params, "granularity", "day") do
      {:ok, %__MODULE__{from: from, to: to, granularity: granularity}}
    else
      _ -> {:error, :invalid_range}
    end
  end

  defp bucket(date, "day"), do: date
  defp bucket(date, "week"), do: Date.beginning_of_week(date)
  defp bucket(date, "month"), do: Date.beginning_of_month(date)
end
