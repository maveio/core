defmodule Storybook.Dashboard.Media.VideoListUpload do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.video_list_upload/1
  def description,
    do: "Full-surface grayscale dropzone with upload rows sharing the render status layout and entrance animation."
  def template, do: "<div class=\"relative flex h-[36rem] w-full min-w-72 flex-col overflow-hidden\"><.psb-variation/></div>"

  def variations do
    [
      %Variation{
        id: :root,
        attributes: %{id: "root-drop-preview", active: true, hook: nil},
        slots: ["<div class=\"p-10 text-sm text-stone-400\">Your video library</div>"]
      },
      %Variation{
        id: :folder,
        attributes: %{
          id: "folder-drop-preview",
          destination: "Campaigns",
          active: true,
          hook: nil
        },
        slots: ["<div class=\"p-10 text-sm text-stone-400\">Videos in Campaigns</div>"]
      },
      %Variation{
        id: :queue,
        attributes: %{
          id: "upload-queue-preview",
          hook: nil,
          uploads: [
            %{name: "Studio tour.mp4", destination: "Videos", state: "uploading", progress: 68},
            %{name: "Product launch.mp4", destination: "Campaigns", state: "uploading", progress: 24},
            %{name: "Brand film.mp4", destination: "Videos", state: "completed", progress: 100},
            %{name: "Behind the scenes.mp4", destination: "Campaigns", state: "queued"},
            %{name: "Interview.mp4", destination: "Videos", state: "error"}
          ]
        },
        slots: ["<div class=\"p-10 text-sm text-stone-400\">Your video library</div>"]
      }
    ]
  end
end
