defmodule Storybook.Dashboard.VideoDetail.VideoMetricCard do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.video_metric_card/1

  def description do
    "Metric card used by the video detail analytics summary."
  end

  def variations do
    [
      %Variation{
        id: :today,
        attributes: %{
          label: "today",
          value: "7.4K"
        }
      }
    ]
  end
end
