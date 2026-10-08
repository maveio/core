defmodule Storybook.Dashboard.Media.MediaBadge do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.media_badge/1

  def variations do
    [
      %Variation{
        id: :resolution,
        description: "Resolution badge",
        slots: ["1080p"]
      },
      %Variation{
        id: :framerate,
        description: "Framerate badge",
        slots: ["30fps"]
      },
      %Variation{
        id: :language,
        description: "Language badge",
        slots: ["EN"]
      },
      %Variation{
        id: :count,
        description: "Video count badge",
        slots: ["12 videos"]
      },
      %Variation{
        id: :custom,
        description: "Custom info",
        slots: ["HDR"]
      }
    ]
  end
end
