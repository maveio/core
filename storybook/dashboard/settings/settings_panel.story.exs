defmodule Storybook.Dashboard.Settings.SettingsPanel do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.settings_panel/1

  def description do
    "Dark-themed container for the video/embed settings sidebar panel."
  end

  def template do
    """
    <div class="bg-stone-900 p-4 rounded-lg min-h-[400px]">
      <.psb-variation/>
    </div>
    """
  end

  def variations do
    [
      %Variation{
        id: :default,
        description: "Settings panel with sample content",
        attributes: %{
          id: "demo_settings"
        },
        slots: [
          """
          <div class="p-3 text-stone-400 text-sm">
            Sample settings content goes here
          </div>
          """
        ]
      }
    ]
  end
end
