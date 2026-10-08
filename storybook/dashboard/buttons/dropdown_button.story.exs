defmodule Storybook.Dashboard.Buttons.DropdownButton do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.dropdown_button/1

  def variations do
    [
      %Variation{
        id: :default,
        description: "Dropdown with render, replace, and delete actions",
        attributes: %{
          id: "dropdown-default"
        },
        slots: [
          """
          <:item icon="render">(re)render</:item>
          <:item icon="replace">replace</:item>
          <:item icon="delete" danger>delete</:item>
          """
        ]
      },
      %Variation{
        id: :custom_actions,
        description: "Dropdown with custom actions",
        attributes: %{
          id: "dropdown-custom"
        },
        slots: [
          """
          <:item icon="render">Process</:item>
          <:item icon="replace">Update</:item>
          """
        ]
      }
    ]
  end
end
