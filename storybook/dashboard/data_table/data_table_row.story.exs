defmodule Storybook.Dashboard.DataTable.DataTableRow do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.data_table_row/1

  def imports do
    [
      {MaveCoreWeb.DashboardComponents,
       [
         data_table_cell: 1,
         data_avatar: 1,
         dash_button: 1
       ]}
    ]
  end

  def template do
    """
    <div class="border rounded-md border-stone-200 border-opacity-50">
      <.data_table_row :let={_} {assigns}>
        <.data_avatar initials="JD" color="blue" />
        <.data_table_cell width="12rem">john.doe@example.com</.data_table_cell>
        <:actions>
          <div class="mr-2">
            <.dash_button icon="delete">remove</.dash_button>
          </div>
        </:actions>
      </.data_table_row>
    </div>
    """
  end

  def variations do
    [
      %Variation{
        id: :with_actions,
        description: "Row with action buttons",
        attributes: %{
          id: "member-1"
        }
      }
    ]
  end
end
