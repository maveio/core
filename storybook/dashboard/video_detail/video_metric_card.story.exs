defmodule Storybook.Dashboard.VideoDetail.VideoMetricCard do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.video_metric_card/1

  def description do
    "Metric card used by the video detail and data page analytics summaries."
  end

  def variations do
    [
      %Variation{
        id: :today,
        attributes: %{
          label: "today",
          value: "7.4K"
        }
      },
      %Variation{
        id: :with_comparison,
        description: "With a unit and a comparison to the previous period",
        attributes: %{
          label: "Watch time",
          unit: "hours",
          value: "126",
          delta: "▲ 5,9% vs previous 30 days",
          delta_tone: :up
        }
      }
    ]
  end
end
