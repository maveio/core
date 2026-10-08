defmodule Storybook.Dashboard.Fields.RegionCard do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.region_card/1

  def variations do
    [
      %Variation{
        id: :active,
        description: "Active region card",
        attributes: %{
          name: "Primary",
          provider: "S3-compatible storage",
          location: "Your selected location",
          active: true
        }
      },
      %Variation{
        id: :inactive,
        description: "Inactive region card",
        attributes: %{
          name: "Secondary",
          provider: "S3-compatible storage",
          location: "Another configured location",
          active: false
        }
      }
    ]
  end
end
