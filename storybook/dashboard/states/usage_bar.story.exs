defmodule Storybook.Dashboard.States.UsageBar do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.usage_bar/1

  def description do
    "Usage/quota progress bar for billing and settings pages. Shows label, current value, max value, and a progress bar."
  end

  def template do
    """
    <div class="w-80 p-4">
      <.psb-variation/>
    </div>
    """
  end

  def variations do
    [
      %Variation{
        id: :low_usage,
        description: "Low usage (25%)",
        attributes: %{
          label: "Video embeds",
          current: "12,450 embeds",
          max: "50,000 embeds",
          percent: 25.0
        }
      },
      %Variation{
        id: :medium_usage,
        description: "Medium usage (50%)",
        attributes: %{
          label: "Bandwidth",
          current: "50 GB",
          max: "100 GB",
          percent: 50.0
        }
      },
      %Variation{
        id: :high_usage,
        description: "High usage (85%)",
        attributes: %{
          label: "Storage",
          current: "8.5 GB",
          max: "10 GB",
          percent: 85.0
        }
      },
      %Variation{
        id: :at_limit,
        description: "At limit (100%)",
        attributes: %{
          label: "API Calls",
          current: "10,000 calls",
          max: "10,000 calls",
          percent: 100.0
        }
      }
    ]
  end
end
