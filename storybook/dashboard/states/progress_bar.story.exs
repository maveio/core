defmodule Storybook.Dashboard.States.ProgressBar do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.progress_bar/1

  def description do
    "Encoding/processing progress bar with animated glow effect at the head."
  end

  def template do
    """
    <div class="bg-stone-900 p-4 rounded-lg w-64">
      <.psb-variation/>
    </div>
    """
  end

  def variations do
    [
      %Variation{
        id: :zero,
        description: "Progress at 0% (hidden bar)",
        attributes: %{
          progress: 0
        }
      },
      %Variation{
        id: :partial,
        description: "Progress at 45%",
        attributes: %{
          progress: 45
        }
      },
      %Variation{
        id: :mostly_complete,
        description: "Progress at 85%",
        attributes: %{
          progress: 85
        }
      },
      %Variation{
        id: :complete,
        description: "Progress at 100%",
        attributes: %{
          progress: 100
        }
      },
      %Variation{
        id: :medium_size,
        description: "Medium size progress bar",
        attributes: %{
          progress: 60,
          size: "md"
        }
      }
    ]
  end
end
