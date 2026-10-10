defmodule Storybook.Dashboard.Buttons.DropdownButton do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.dropdown_button/1

  def variations do
    [
      %Variation{
        id: :public_video,
        description: "Public video actions",
        attributes: %{
          id: "dropdown-public-video",
          menu_class: "w-40"
        },
        slots: [
          """
          <:item icon="hero-lock-closed">private (token)</:item>
          <:item icon="replace">replace</:item>
          <:item icon="archive">archive</:item>
          <:item icon="delete" danger>delete</:item>
          """
        ]
      },
      %Variation{
        id: :private_video,
        description: "Private video actions",
        attributes: %{
          id: "dropdown-private-video",
          menu_class: "w-40"
        },
        slots: [
          """
          <:item icon="hero-lock-open">public</:item>
          <:item icon="replace">replace</:item>
          <:item icon="archive">archive</:item>
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
