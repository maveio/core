defmodule Storybook.Dashboard.States.LedIndicator do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.led_indicator/1

  def description do
    "Small LED status indicator dot showing processing state (complete, processing, queued, none)."
  end

  def template do
    """
    <div class="bg-stone-900 p-4 rounded-lg flex items-center gap-4">
      <.psb-variation/>
    </div>
    """
  end

  def variations do
    [
      %Variation{
        id: :complete,
        description: "Complete - green gradient",
        attributes: %{
          status: :complete
        }
      },
      %Variation{
        id: :processing,
        description: "Processing - animated spinning ring",
        attributes: %{
          status: :processing
        }
      },
      %Variation{
        id: :queued,
        description: "Queued - dark with ring",
        attributes: %{
          status: :queued
        }
      },
      %Variation{
        id: :none,
        description: "None/default state",
        attributes: %{
          status: :none
        }
      }
    ]
  end
end
