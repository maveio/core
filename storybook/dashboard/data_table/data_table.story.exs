defmodule Storybook.Dashboard.DataTable.Table do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.data_table/1

  def imports do
    [
      {MaveCoreWeb.DashboardComponents,
       [
         data_table_header_cell: 1,
         data_table_row: 1,
         data_table_cell: 1,
         data_avatar: 1
       ]}
    ]
  end

  def template do
    """
    <.data_table :let={_}>
      <:header>
        <.data_table_header_cell width="12rem">Name</.data_table_header_cell>
        <.data_table_header_cell width="16rem">Email</.data_table_header_cell>
        <.data_table_header_cell width="8rem" align="right">Role</.data_table_header_cell>
      </:header>
      <.data_table_row>
        <.data_avatar initials="JD" color="blue" />
        <.data_table_cell width="10rem">john.doe</.data_table_cell>
        <.data_table_cell width="16rem">john.doe@example.com</.data_table_cell>
        <.data_table_cell width="8rem">Admin</.data_table_cell>
      </.data_table_row>
      <.data_table_row>
        <.data_avatar initials="AB" color="green" />
        <.data_table_cell width="10rem">alice.bob</.data_table_cell>
        <.data_table_cell width="16rem">alice@example.com</.data_table_cell>
        <.data_table_cell width="8rem">Member</.data_table_cell>
      </.data_table_row>
      <.data_table_row>
        <.data_avatar initials="CS" color="purple" />
        <.data_table_cell width="10rem">charlie.smith</.data_table_cell>
        <.data_table_cell width="16rem">charlie.smith@example.com</.data_table_cell>
        <.data_table_cell width="8rem">Member</.data_table_cell>
      </.data_table_row>
    </.data_table>
    """
  end

  def variations do
    [
      %Variation{
        id: :team_list,
        description: "Team member list with avatars"
      }
    ]
  end
end
