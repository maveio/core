defmodule Storybook.Dashboard.DataTable.Toggle do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.toggle/1

  def variations do
    [
      %Variation{
        id: :enabled,
        description: "Toggle in enabled/on state",
        attributes: %{
          enabled: true
        }
      },
      %Variation{
        id: :disabled_off,
        description: "Toggle in disabled/off state",
        attributes: %{
          enabled: false
        }
      },
      %Variation{
        id: :disabled_on,
        description: "Toggle enabled but visually disabled (non-interactive)",
        attributes: %{
          enabled: true,
          disabled: true
        }
      },
      %Variation{
        id: :disabled_inactive,
        description: "Toggle off and visually disabled",
        attributes: %{
          enabled: false,
          disabled: true
        }
      }
    ]
  end
end
