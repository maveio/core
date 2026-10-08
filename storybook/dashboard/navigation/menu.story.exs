defmodule Storybook.Dashboard.Navigation.Menu do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.Navigation.menu/1

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
        id: :default,
        attributes: %{
          current_user: %{email: "user@mave.io"},
          current_space: %{id: "1"}
        }
      }
    ]
  end
end
