defmodule Storybook.Dashboard.Navigation.Subtitle do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.subtitle/1

  def variations do
    [
      %Variation{
        id: :default,
        description: "Simple subtitle",
        attributes: %{
          label: "General Settings"
        }
      },
      %Variation{
        id: :with_icon,
        description: "Subtitle with icon",
        attributes: %{
          icon: "general",
          label: "Configuration"
        }
      },
      %Variation{
        id: :domains,
        description: "Domains section",
        attributes: %{
          icon: "domain",
          label: "Domains"
        }
      },
      %Variation{
        id: :team,
        description: "Team section",
        attributes: %{
          icon: "team",
          label: "Team Members"
        }
      }
    ]
  end
end
