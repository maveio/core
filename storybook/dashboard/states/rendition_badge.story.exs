defmodule Storybook.Dashboard.States.RenditionBadge do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.rendition_badge/1

  def description do
    "Small badge/pill showing codec, size, or format information for video renditions."
  end

  def template do
    """
    <div class="bg-stone-900 p-4 rounded-lg flex items-center gap-2">
      <.psb-variation/>
    </div>
    """
  end

  def variations do
    [
      %Variation{
        id: :codec,
        description: "Codec badge",
        attributes: %{
          label: "H.264"
        }
      },
      %Variation{
        id: :resolution,
        description: "Resolution badge (filled)",
        attributes: %{
          label: "1080p",
          variant: "filled"
        }
      },
      %Variation{
        id: :container,
        description: "Container format badge",
        attributes: %{
          label: "HLS"
        }
      },
      %Variation{
        id: :audio,
        description: "Audio codec badge",
        attributes: %{
          label: "AAC"
        }
      }
    ]
  end
end
