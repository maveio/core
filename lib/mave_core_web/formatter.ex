defmodule MaveCoreWeb.Formatter do
  @moduledoc false

  @number_regex ~r/\A(?<sign>-?)(?<int>\d+)(?:\.(?<frac>\d+))?\z/

  def format_number(number, options \\ []) do
    thousands_separator = Keyword.get(options, :thousands_separator, ".")
    decimal_separator = Keyword.get(options, :decimal_separator, ",")

    case Regex.named_captures(@number_regex, to_string(number)) do
      %{"sign" => sign, "int" => int, "frac" => frac} ->
        [sign, format_int(int, thousands_separator), format_fraction(frac, decimal_separator)]
        |> IO.iodata_to_binary()

      nil ->
        to_string(number)
    end
  end

  defp format_int(int, thousands_separator) do
    int
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map_join(thousands_separator, &Enum.join/1)
    |> String.reverse()
  end

  defp format_fraction(nil, _decimal_separator), do: ""
  defp format_fraction("", _decimal_separator), do: ""
  defp format_fraction(fraction, decimal_separator), do: [decimal_separator, fraction]
end
