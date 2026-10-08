defmodule Storybook.Dashboard.Navigation.Breadcrumb do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.breadcrumb/1

  def variations do
    [
      %Variation{
        id: :two_levels,
        description: "Video > Archive",
        slots: [
          """
          <:item label="Video" navigate="/videos" />
          <:item label="Archive" />
          """
        ]
      },
      %Variation{
        id: :three_levels,
        description: "Video > Archive > Folder",
        slots: [
          """
          <:item label="Video" navigate="/videos" />
          <:item label="Archive" navigate="/videos/archive" />
          <:item label="Marketing" />
          """
        ]
      }
    ]
  end
end
