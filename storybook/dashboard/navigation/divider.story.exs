defmodule Storybook.Dashboard.Navigation.Divider do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.divider/1

  def description do
    "Simple horizontal divider for separating sections. Thin centered line with spacing."
  end

  def template do
    """
    <div class="w-full py-4">
      <div class="text-sm text-stone-400 text-center mb-4">Content above</div>
      <.psb-variation/>
      <div class="text-sm text-stone-400 text-center mt-4">Content below</div>
    </div>
    """
  end

  def variations do
    [
      %Variation{
        id: :default,
        description: "Default divider"
      },
      %Variation{
        id: :custom_spacing,
        description: "With custom spacing",
        attributes: %{class: "my-8"}
      }
    ]
  end
end
