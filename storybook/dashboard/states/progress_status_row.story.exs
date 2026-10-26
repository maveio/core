defmodule Storybook.Dashboard.States.ProgressStatusRow do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.progress_status_row/1
  def description, do: "Shared render and upload status row with a subtle entrance animation."
  def template, do: "<div class=\"w-56 bg-stone-900\"><.psb-variation/></div>"

  def variations do
    [
      %Variation{
        id: :queued,
        attributes: %{status: "queued"},
        slots: ["Queued"]
      },
      %Variation{
        id: :active,
        attributes: %{status: "active", progress: 45},
        slots: ["Encoding"]
      },
      %Variation{
        id: :completed,
        attributes: %{status: "completed", progress: 100},
        slots: ["Ready"]
      },
      %Variation{
        id: :failed,
        attributes: %{status: "failed", progress: 25},
        slots: ["Failed"]
      }
    ]
  end
end
