defmodule Storybook.Dashboard.Navigation.Title do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.title/1

  def imports, do: [{MaveCoreWeb.DashboardComponents, [dash_button: 1]}]

  def variations do
    [
      %Variation{
        id: :default,
        description: "Simple page title",
        attributes: %{
          title: "Videos"
        }
      },
      %Variation{
        id: :with_actions,
        description: "Title with action buttons",
        attributes: %{
          title: "Video Library"
        },
        slots: [
          """
          <.dash_button icon="hero-plus">create</.dash_button>
          """
        ]
      }
    ]
  end
end
