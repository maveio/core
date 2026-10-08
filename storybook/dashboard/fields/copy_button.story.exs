defmodule Storybook.Dashboard.Fields.CopyButton do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.copy_button/1

  def template do
    """
    <div class="flex items-center gap-2">
      <div id="copy-target">some text to copy</div>
      <.psb-variation/>
    </div>
    """
  end

  def variations do
    [
      %Variation{
        id: :default,
        description: "Copy button targeting an element",
        attributes: %{
          target: "copy-target"
        }
      }
    ]
  end
end
