defmodule Storybook.Dashboard.VideoDetail.ReleaseNotice do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.release_notice/1

  def description do
    "Shown under the player while a scheduled release is pending."
  end

  def container, do: {:div, class: "bg-stone-900"}

  def variations do
    [
      %Variation{
        id: :scheduled,
        description: "Release time ahead: change or publish now",
        attributes: %{
          embed: %MaveCore.Embeds.Embed{release_at: ~U[2099-06-01 18:00:00.000000Z]}
        }
      },
      %Variation{
        id: :publishing,
        description: "Release time reached while storage becomes public",
        attributes: %{
          embed: %MaveCore.Embeds.Embed{release_at: ~U[2020-06-01 18:00:00.000000Z]}
        }
      }
    ]
  end
end
