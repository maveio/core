defmodule MaveCore.Analytics.RangeTest do
  use ExUnit.Case, async: true

  alias MaveCore.Analytics.Export
  alias MaveCore.Analytics.Range

  test "absent range leaves the legacy path unchanged" do
    assert {:ok, nil} = Range.parse(%{"space_hash" => "abcde"})
  end

  test "both dates are inclusive UTC dates and default to daily buckets" do
    assert {:ok, range} = Range.parse(%{"from" => "2024-02-28", "to" => "2024-03-01"})
    assert range.granularity == "day"
    assert Range.bounds(range) == {~U[2024-02-28 00:00:00Z], ~U[2024-03-02 00:00:00Z]}
    assert Range.buckets(range) == [~D[2024-02-28], ~D[2024-02-29], ~D[2024-03-01]]
  end

  test "calendar year bound handles leap dates" do
    assert {:ok, _} = Range.parse(%{"from" => "2024-02-29", "to" => "2026-02-28"})
    assert {:error, :invalid_range} = Range.parse(%{"from" => "2024-02-29", "to" => "2026-03-01"})
  end

  test "incomplete, inverted, malformed and invalid granularity combinations are rejected" do
    for params <- [
          %{"from" => "2024-01-01"},
          %{"to" => "2024-01-01"},
          %{"granularity" => "day"},
          %{"from" => "2024-01-02", "to" => "2024-01-01"},
          %{"from" => "2024-02-30", "to" => "2024-03-01"},
          %{"from" => "2024-01-01T00:00:00Z", "to" => "2024-01-02"},
          %{"from" => ["2024-01-01"], "to" => "2024-01-02"},
          %{"from" => "2024-01-01", "to" => "2024-01-02", "granularity" => "hour"}
        ] do
      assert {:error, :invalid_range} = Range.parse(params)
    end
  end

  test "weeks start Monday and months start on the first, with partial edge buckets" do
    assert Range.buckets(%Range{from: ~D[2024-02-29], to: ~D[2024-03-04], granularity: "week"}) ==
             [~D[2024-02-26], ~D[2024-03-04]]

    assert Range.buckets(%Range{from: ~D[2024-02-29], to: ~D[2024-03-04], granularity: "month"}) ==
             [~D[2024-02-01], ~D[2024-03-01]]
  end

  test "CSV escapes commas, quotes, newlines and formula prefixes, retaining numeric cells" do
    assert IO.iodata_to_binary(Export.row(["a,b", "a\"b\nc", 12, 1.5, nil])) ==
             "\"a,b\",\"a\"\"b\nc\",12,1.5,\r\n"

    for formula <- ["=1+1", "+SUM(A1)", "-1", "@sum", " \t=cmd", "\nhello", "\tfoo"] do
      assert IO.iodata_to_binary(Export.row([formula])) == "\"'#{formula}\"\r\n"
    end
  end
end
