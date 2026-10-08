defmodule Storybook.Dashboard.SettingsOption do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.settings_option/1

  def description do
    "Selectable option card for settings. Uses stone-400 for text, stone-500 for icon borders (matching legacy)."
  end

  def template do
    """
    <div class="bg-stone-900 p-3 rounded-lg grid grid-cols-2 gap-3 w-56">
      <.psb-variation/>
    </div>
    """
  end

  def variations do
    [
      %Variation{
        id: :aspect_16_9_selected,
        description: "16:9 aspect ratio (selected)",
        attributes: %{
          label: "16:9",
          value: :r16_9,
          selected: true
        },
        slots: [
          """
          <div class="h-4 aspect-video border border-stone-500 mt-1.5 rounded-sm"></div>
          """
        ]
      },
      %Variation{
        id: :aspect_1_1_unselected,
        description: "1:1 aspect ratio (unselected)",
        attributes: %{
          label: "1:1",
          value: :r1_1,
          selected: false
        },
        slots: [
          """
          <div class="h-4 aspect-square border border-stone-500 mt-1.5 rounded-sm"></div>
          """
        ]
      },
      %Variation{
        id: :aspect_4_3_unselected,
        description: "4:3 aspect ratio (unselected)",
        attributes: %{
          label: "4:3",
          value: :r4_3,
          selected: false
        },
        slots: [
          """
          <div class="h-4 aspect-[4/3] border border-stone-500 mt-1.5 rounded-sm"></div>
          """
        ]
      },
      %Variation{
        id: :aspect_auto_unselected,
        description: "Auto aspect ratio (dashed border)",
        attributes: %{
          label: "auto",
          value: :auto,
          selected: false
        },
        slots: [
          """
          <div class="h-4 aspect-square border border-dashed border-stone-500 mt-1.5 rounded-sm"></div>
          """
        ]
      },
      %Variation{
        id: :controls_full_selected,
        description: "Full controls (selected)",
        attributes: %{
          label: "full",
          value: :full,
          selected: true
        },
        slots: [
          """
          <div class="h-4 aspect-video border border-stone-500 mt-1.5 rounded-sm flex">
            <div class="w-full h-1 mt-auto border-t border-stone-500"></div>
          </div>
          """
        ]
      },
      %Variation{
        id: :controls_big_unselected,
        description: "Big play button controls (unselected)",
        attributes: %{
          label: "big",
          value: :big,
          selected: false
        },
        slots: [
          """
          <div class="aspect-video h-4 border border-stone-500 mt-1.5 rounded-sm flex items-center justify-center text-stone-500">
            <svg class="w-1.5 h-1.5" xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="currentColor" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round">
              <polygon points="5 3 19 12 5 21 5 3"></polygon>
            </svg>
          </div>
          """
        ]
      }
    ]
  end
end
