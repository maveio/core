defmodule Storybook.Dashboard.Media.MediaItem do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.media_item/1
  def imports, do: [{MaveCoreWeb.DashboardComponents, [media_badge: 1, dash_button: 1]}]

  def variations do
    [
      %Variation{
        id: :video_with_thumbnail,
        description: "Video embed with thumbnail",
        attributes: %{
          type: :video,
          name: "My Awesome Video",
          thumbnail: "https://picsum.photos/seed/video1/320/180",
          date: "20 January 2026"
        },
        slots: [
          """
          <:badges>
            <.media_badge>1080p</.media_badge>
            <.media_badge>30fps</.media_badge>
            <.media_badge>EN</.media_badge>
          </:badges>
          """
        ]
      },
      %Variation{
        id: :video_empty,
        description: "Empty video (no upload yet)",
        attributes: %{
          type: :video,
          name: "Empty embed"
        }
      },
      %Variation{
        id: :folder,
        description: "Folder/collection",
        attributes: %{
          type: :folder,
          name: "Marketing Videos"
        },
        slots: [
          """
          <:badges>
            <.media_badge>12 videos</.media_badge>
          </:badges>
          """
        ]
      },
      %Variation{
        id: :with_actions,
        description: "With action buttons",
        attributes: %{
          type: :video,
          name: "Video with Actions",
          thumbnail: "https://picsum.photos/seed/video2/320/180"
        },
        slots: [
          """
          <:badges>
            <.media_badge>720p</.media_badge>
          </:badges>
          <:actions>
            <.dash_button icon="link" icon_only />
          </:actions>
          """
        ]
      }
    ]
  end
end
