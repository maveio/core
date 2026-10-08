defmodule Storybook.Dashboard.Settings.SettingsHeader do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.settings_header/1

  def description do
    "Section header row with optional toggle or add button for settings panels."
  end

  def template do
    """
    <div class="bg-stone-900 w-56 p-0">
      <.psb-variation/>
    </div>
    """
  end

  def variations do
    [
      %Variation{
        id: :default,
        description: "Basic header without controls",
        attributes: %{
          title: "dimensions"
        }
      },
      %Variation{
        id: :with_toggle_enabled,
        description: "Header with toggle switch (enabled)",
        attributes: %{
          title: "aspect ratio",
          toggable: true,
          toggle_enabled: true
        }
      },
      %Variation{
        id: :with_toggle_disabled,
        description: "Header with toggle switch (disabled)",
        attributes: %{
          title: "controls",
          toggable: true,
          toggle_enabled: false
        }
      },
      %Variation{
        id: :with_add_button,
        description: "Header with add button",
        attributes: %{
          title: "subtitles",
          addable: true
        }
      }
    ]
  end
end
