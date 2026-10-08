defmodule Storybook.Dashboard.VideoDetail.VideoEmbedPanel do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.video_embed_panel/1

  def description do
    "Shared dark preview/snippet shell for the dashboard video detail page."
  end

  def template do
    """
    <div class="max-w-4xl">
      <.psb-variation />
    </div>
    """
  end

  def variations do
    [
      %Variation{
        id: :default,
        attributes: %{
          player_dom_id: "storybook-player",
          tabs: [
            %{name: :script, label: "Player", current: true},
            %{name: :clip, label: "Clip", current: false},
            %{name: :iframe, label: "iFrame", current: false},
            %{name: :react, label: "React", current: false},
            %{name: :vue, label: "Vue", current: false}
          ],
          snippet:
            ~S(<script type='module' src='https://components.example/dist/index.js'></script>
<mave-player embed='trialleUXMh0Ug7'></mave-player>),
          line_numbers: [1, 2]
        },
        slots: [
          """
          <:player>
            <div class="w-full aspect-video bg-stone-950"></div>
          </:player>
          """
        ]
      }
    ]
  end
end
