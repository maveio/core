defmodule Storybook.Dashboard.Navigation.SectionTitle do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.section_title/1

  def variations do
    [
      %Variation{
        id: :default,
        description: "Section divider title",
        attributes: %{
          label: "Account Settings"
        }
      },
      %Variation{
        id: :billing,
        description: "Billing section",
        attributes: %{
          label: "Payment Methods"
        }
      }
    ]
  end
end
