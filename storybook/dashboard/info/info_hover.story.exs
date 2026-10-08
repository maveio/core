defmodule Storybook.Dashboard.Info.InfoHover do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.info_hover/1

  def variations do
    [
      %Variation{
        id: :default,
        description: "Info icon with tooltip (blue) - hover to see popup",
        slots: [
          "You can use a CNAME record to be able to share a link to individual files and folders through your own domain."
        ]
      },
      %Variation{
        id: :short,
        description: "Short tooltip message",
        slots: [
          "Contact support if you'd like this enabled."
        ]
      },
      %Variation{
        id: :danger,
        description: "Danger info (red icon)",
        attributes: %{color: "red"},
        slots: [
          "This will permanently delete your account and all data. This action cannot be undone."
        ]
      },
      %Variation{
        id: :left_position,
        description: "Tooltip on the left side",
        attributes: %{position: "left"},
        slots: [
          "This tooltip appears to the left of the icon."
        ]
      }
    ]
  end
end
