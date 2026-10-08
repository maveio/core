defmodule Storybook.Dashboard.Settings.ColorPicker do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.color_picker/1

  def description do
    "Color picker with preset swatches dropdown. Toggle/dismiss handled client-side via JS."
  end

  def template do
    """
    <div class="bg-stone-900 p-4 rounded-lg min-h-[200px]">
      <.psb-variation/>
    </div>
    """
  end

  def variations do
    [
      %Variation{
        id: :with_color,
        description: "With a selected color (click to toggle dropdown)",
        attributes: %{
          id: "color-picker-1",
          color: "2563eb",
          opacity: 100,
          on_select: %Phoenix.LiveView.JS{}
        }
      },
      %Variation{
        id: :transparent,
        description: "Transparent/no color selected (click to toggle dropdown)",
        attributes: %{
          id: "color-picker-2",
          color: nil,
          opacity: 100,
          on_select: %Phoenix.LiveView.JS{}
        }
      },
      %Variation{
        id: :open_dropdown,
        description: "With dropdown open (click colors or outside to close)",
        attributes: %{
          id: "color-picker-3",
          color: "ef4444",
          opacity: 100,
          on_select: %Phoenix.LiveView.JS{}
        }
      }
    ]
  end
end
