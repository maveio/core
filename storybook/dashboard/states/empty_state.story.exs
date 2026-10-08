defmodule Storybook.Dashboard.States.EmptyState do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.empty_state/1
  def imports, do: [{MaveCoreWeb.DashboardComponents, [dash_button: 1]}]

  def variations do
    [
      %Variation{
        id: :with_action,
        description: "Empty state with CTA",
        attributes: %{
          title: "Create your first video",
          icon: "upload"
        },
        slots: [
          """
          <:action>
            <.dash_button icon="create">create</.dash_button>
          </:action>
          """
        ]
      },
      %Variation{
        id: :archive_empty,
        description: "Empty archive",
        attributes: %{
          title: "Your archive is empty",
          icon: "folder"
        }
      },
      %Variation{
        id: :folder_empty,
        description: "Empty folder",
        attributes: %{
          title: "This folder is empty",
          icon: "folder"
        }
      }
    ]
  end
end
