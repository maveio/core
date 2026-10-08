defmodule Storybook.Dashboard.VideoDetail.VideoDataSection do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.video_data_section/1

  def description do
    "Section wrapper used for analytics panels and other structured data blocks."
  end

  def variations do
    [
      %Variation{
        id: :default,
        attributes: %{
          label: "Sources"
        },
        slots: [
          """
          <div class="px-4 py-6 text-sm text-stone-400">
            Sample body content inside the shared data section shell.
          </div>
          """
        ]
      }
    ]
  end
end
