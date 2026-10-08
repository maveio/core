defmodule MaveCoreWeb.FormatterTest do
  use ExUnit.Case, async: true

  alias MaveCoreWeb.Formatter

  test "formats numbers with dot thousands separators by default" do
    assert Formatter.format_number(1) == "1"
    assert Formatter.format_number(123) == "123"
    assert Formatter.format_number(1_234) == "1.234"
    assert Formatter.format_number(123_456_789) == "123.456.789"
    assert Formatter.format_number(-123_456_789) == "-123.456.789"
    assert Formatter.format_number(12_345.6789) == "12.345,6789"
  end

  test "allows separators to be overridden" do
    assert Formatter.format_number(123_456_789, thousands_separator: ",") == "123,456,789"

    assert Formatter.format_number(12_345.6789,
             decimal_separator: ".",
             thousands_separator: ","
           ) == "12,345.6789"
  end
end
