defmodule MaveCoreWeb.DashboardComponents.StatesTest do
  use ExUnit.Case, async: true
  use Phoenix.Component

  import MaveCoreWeb.DashboardComponents.States
  import Phoenix.LiveViewTest

  test "usage_bar renders normal usage as a blue partial bar" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.usage_bar label="Bandwidth" current="1 TB" max="4 TB" percent={25.0} />
      """)

    assert html =~ ~s(data-usage-segment="within-limit")
    assert html =~ ~s(style="width: 25.0%;")
    refute html =~ ~s(data-usage-segment="overage")
  end

  test "usage_bar shows the portion above the limit in red" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.usage_bar label="Bandwidth" current="4 TB" max="3 TB" percent={133.333333} />
      """)

    assert html =~ ~s(data-usage-segment="within-limit")
    assert html =~ ~s(style="width: 75.0%;")
    assert html =~ ~s(data-usage-segment="overage")
    assert html =~ "bg-red-500"
    assert html =~ ~s(style="width: 25.0%;")
  end
end
