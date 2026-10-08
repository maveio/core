defmodule Storybook.Dashboard.DataTable.DataTableGrid do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.data_table_grid/1

  def imports do
    [
      {MaveCoreWeb.DashboardComponents,
       [
         data_table_grid_header_cell: 1,
         data_table_grid_row: 1,
         data_table_grid_cell: 1
       ]}
    ]
  end

  def template do
    """
    <.data_table_grid
      {assigns}
      columns="@5xl:grid-cols-[minmax(14rem,1.5fr)_minmax(10rem,1fr)_8rem]"
    >
      <:header>
        <.data_table_grid_header_cell>Space</.data_table_grid_header_cell>
        <.data_table_grid_header_cell>Usage</.data_table_grid_header_cell>
        <.data_table_grid_header_cell>Created</.data_table_grid_header_cell>
      </:header>

      <.data_table_grid_row
        id="storybook-space-1"
        columns="@5xl:grid-cols-[minmax(14rem,1.5fr)_minmax(10rem,1fr)_8rem]"
      >
        <.data_table_grid_cell label="Space">
          <div class="truncate text-stone-700">media.example.com</div>
          <div class="mt-1 truncate text-xs text-stone-400">4kp9eQ · Amsterdam</div>
          <div class="mt-2 flex gap-3 text-xs text-blue-400">
            <button type="button">Open</button>
            <button type="button">More actions</button>
          </div>
        </.data_table_grid_cell>
        <.data_table_grid_cell label="Usage">
          <div>128 / 500 videos</div>
          <div class="mt-1 text-xs text-stone-400">4 / 10 team members</div>
        </.data_table_grid_cell>
        <.data_table_grid_cell label="Created">
          <div class="text-xs text-stone-400">2026-07-30</div>
        </.data_table_grid_cell>
      </.data_table_grid_row>

      <.data_table_grid_row
        id="storybook-space-2"
        columns="@5xl:grid-cols-[minmax(14rem,1.5fr)_minmax(10rem,1fr)_8rem]"
      >
        <.data_table_grid_cell label="Space">
          <div class="truncate text-stone-700">studio.example.com</div>
          <div class="mt-1 truncate text-xs text-stone-400">8m2dAa · Helsinki</div>
        </.data_table_grid_cell>
        <.data_table_grid_cell label="Usage">
          <div>42 / 100 videos</div>
          <div class="mt-1 text-xs text-stone-400">2 / 5 team members</div>
        </.data_table_grid_cell>
        <.data_table_grid_cell label="Created">
          <div class="text-xs text-stone-400">2026-06-12</div>
        </.data_table_grid_cell>
      </.data_table_grid_row>
    </.data_table_grid>
    """
  end

  def variations do
    [
      %Variation{
        id: :responsive,
        description: "Container-aware grid that becomes labeled stacked rows below @5xl",
        attributes: %{
          id: "responsive-data-table"
        }
      }
    ]
  end
end
