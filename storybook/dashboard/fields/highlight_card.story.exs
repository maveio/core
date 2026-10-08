defmodule Storybook.Dashboard.Fields.HighlightCard do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.highlight_card/1

  def description do
    "Card with optional blue highlight border for active states. Used for region selection and other selectable cards."
  end

  def variations do
    [
      %Variation{
        id: :default,
        description: "Default inactive state",
        slots: [
          """
          <div class="p-4">
            <div class="text-sm text-stone-600">Card content here</div>
          </div>
          """
        ]
      },
      %Variation{
        id: :active,
        description: "Active state with blue border",
        attributes: %{active: true},
        slots: [
          """
          <div class="p-4">
            <div class="text-sm text-stone-600">Selected card content</div>
          </div>
          """
        ]
      },
      %Variation{
        id: :active_with_label,
        description: "Active state with floating label",
        attributes: %{active: true, label: "current"},
        slots: [
          """
          <div class="p-4">
            <div class="text-sm text-stone-600">Card with label</div>
          </div>
          """
        ]
      },
      %Variation{
        id: :clickable,
        description: "Clickable card (hover shows blue border)",
        attributes: %{clickable: true},
        slots: [
          """
          <div class="p-4">
            <div class="text-sm text-stone-600">Hover over me</div>
          </div>
          """
        ]
      }
    ]
  end
end
