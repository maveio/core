defmodule Storybook.Dashboard.VideoDetail.VideoUploadPanel do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.video_upload_panel/1

  def description do
    "Upload shell used for empty embeds before a source video has been added."
  end

  def template do
    """
    <div class="max-w-4xl bg-stone-900 rounded-lg overflow-hidden">
      <.psb-variation />
    </div>
    """
  end

  def variations do
    [
      %Variation{
        id: :default,
        attributes: %{
          token: "storybook-upload-token",
          dom_id: "storybook-upload",
          hook: ""
        }
      }
    ]
  end
end
