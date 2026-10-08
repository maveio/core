defmodule Storybook.Dashboard.Settings.SettingsToggle do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.settings_toggle/1

  def description do
    "Small dark-theme toggle switch (w-6 h-3) for settings panel. Different from the larger dashboard toggle (w-10) used in data tables."
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
        id: :enabled,
        description: "Toggle in enabled state",
        attributes: %{
          enabled: true
        }
      },
      %Variation{
        id: :disabled_state,
        description: "Toggle in disabled state",
        attributes: %{
          enabled: false
        }
      },
      %Variation{
        id: :disabled_interaction,
        description: "Toggle with disabled interaction",
        attributes: %{
          enabled: true,
          disabled: true
        }
      }
    ]
  end
end
