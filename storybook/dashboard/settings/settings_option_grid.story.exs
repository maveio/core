defmodule Storybook.Dashboard.Settings.SettingsOptionGrid do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.settings_option_grid/1

  def description do
    "Container grid for option cards in settings panel. Shows/hides with scale and opacity transitions."
  end

  def template do
    """
    <div class="bg-stone-900 w-56 p-0 rounded-lg">
      <.psb-variation/>
    </div>
    """
  end

  def variations do
    [
      %Variation{
        id: :visible_2_cols,
        description: "Visible grid (2 columns)",
        attributes: %{visible: true, cols: 2},
        slots: [
          """
          <div class="bg-stone-800 h-16 rounded-sm flex flex-col items-center justify-center text-stone-400 ring-1 ring-inset ring-blue-600">
            <div class="h-4 aspect-video border border-stone-500 mt-1.5 rounded-sm"></div>
            <div class="mt-1.5">16:9</div>
          </div>
          <div class="bg-stone-800 h-16 rounded-sm flex flex-col items-center justify-center text-stone-400 ring-1 ring-inset ring-transparent hover:ring-blue-600 cursor-pointer">
            <div class="h-4 aspect-square border border-stone-500 mt-1.5 rounded-sm"></div>
            <div class="mt-1.5">1:1</div>
          </div>
          <div class="bg-stone-800 h-16 rounded-sm flex flex-col items-center justify-center text-stone-400 ring-1 ring-inset ring-transparent hover:ring-blue-600 cursor-pointer">
            <div class="h-4 aspect-[4/3] border border-stone-500 mt-1.5 rounded-sm"></div>
            <div class="mt-1.5">4:3</div>
          </div>
          <div class="bg-stone-800 h-16 rounded-sm flex flex-col items-center justify-center text-stone-400 ring-1 ring-inset ring-transparent hover:ring-blue-600 cursor-pointer">
            <div class="h-4 aspect-square border border-dashed border-stone-500 mt-1.5 rounded-sm"></div>
            <div class="mt-1.5">auto</div>
          </div>
          """
        ]
      },
      %Variation{
        id: :visible_3_cols,
        description: "Visible grid (3 columns)",
        attributes: %{visible: true, cols: 3},
        slots: [
          """
          <div class="bg-stone-800 h-12 rounded-sm flex items-center justify-center text-stone-400 ring-1 ring-inset ring-blue-600 text-sm">Option 1</div>
          <div class="bg-stone-800 h-12 rounded-sm flex items-center justify-center text-stone-400 ring-1 ring-inset ring-transparent text-sm">Option 2</div>
          <div class="bg-stone-800 h-12 rounded-sm flex items-center justify-center text-stone-400 ring-1 ring-inset ring-transparent text-sm">Option 3</div>
          """
        ]
      },
      %Variation{
        id: :hidden,
        description: "Hidden grid (collapsed)",
        attributes: %{visible: false},
        slots: [
          """
          <div class="bg-stone-800 h-16 rounded-sm flex items-center justify-center text-stone-400">Hidden content</div>
          """
        ]
      }
    ]
  end
end
