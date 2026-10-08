defmodule Storybook.Dashboard.Fields.CopyableField do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.copyable_field/1

  def variations do
    [
      %Variation{
        id: :default,
        description: "Copyable field with a value",
        attributes: %{
          id: "story-copyable",
          value: "sp_a1b2c3d4e5f6"
        }
      },
      %Variation{
        id: :api_key,
        description: "Copyable field with an API key",
        attributes: %{
          id: "story-api-key",
          value: "sk_live_a1b2••••••••c3d4"
        }
      }
    ]
  end
end
