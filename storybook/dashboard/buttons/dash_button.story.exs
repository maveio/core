defmodule Storybook.Dashboard.Buttons.DashButton do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.dash_button/1

  def variations do
    [
      %Variation{
        id: :default,
        description: "Default button style",
        slots: ["save"]
      },
      %Variation{
        id: :primary,
        description: "Primary action button",
        attributes: %{variant: "primary"},
        slots: ["create"]
      },
      %Variation{
        id: :ghost,
        description: "Ghost/text button",
        attributes: %{variant: "ghost"},
        slots: ["cancel"]
      },
      %Variation{
        id: :danger,
        description: "Destructive action button",
        attributes: %{variant: "danger"},
        slots: ["delete"]
      },
      %Variation{
        id: :with_icon,
        description: "Button with icon (create)",
        attributes: %{icon: "create"},
        slots: ["create"]
      },
      %Variation{
        id: :with_icon_link,
        description: "Button with icon (link)",
        attributes: %{icon: "link"},
        slots: ["link"]
      },
      %Variation{
        id: :disabled,
        description: "Disabled button",
        attributes: %{disabled: true},
        slots: ["disabled"]
      }
    ]
  end
end
