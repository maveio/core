defmodule Storybook.Dashboard.Info.InfoBox do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.info_box/1

  def variations do
    [
      %Variation{
        id: :default,
        description: "Info box with help text",
        slots: [
          "This domain will be linked to your video space. Make sure to configure DNS settings correctly."
        ]
      },
      %Variation{
        id: :short,
        description: "Short info message",
        slots: [
          "Changes will take effect within 24 hours."
        ]
      }
    ]
  end
end
