defmodule MaveCoreWeb.DashboardComponents.DataTableTest do
  use ExUnit.Case, async: true
  use Phoenix.Component

  import MaveCoreWeb.DashboardComponents.DataTable
  import Phoenix.LiveViewTest

  test "data table grid stacks labeled rows instead of horizontally scrolling" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.data_table_grid id="spaces-table" columns="@5xl:grid-cols-[2fr_1fr]">
        <:header>
          <.data_table_grid_header_cell>Space</.data_table_grid_header_cell>
          <.data_table_grid_header_cell>Usage</.data_table_grid_header_cell>
        </:header>
        <.data_table_grid_row id="space-1" columns="@5xl:grid-cols-[2fr_1fr]">
          <.data_table_grid_cell label="Space">example.com</.data_table_grid_cell>
          <.data_table_grid_cell label="Usage">12 videos</.data_table_grid_cell>
        </.data_table_grid_row>
      </.data_table_grid>
      """)

    assert html =~ ~s(id="spaces-table")
    assert html =~ ~s(role="table")
    assert html =~ "@container relative w-full rounded-md bg-white"
    assert html =~ "hidden gap-4"
    assert html =~ "grid grid-cols-1"
    assert html =~ "@5xl:grid-cols-[2fr_1fr]"
    assert html =~ "@5xl:hidden"
    refute html =~ "overflow-"
  end
end
