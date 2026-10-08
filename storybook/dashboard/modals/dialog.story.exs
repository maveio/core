defmodule Storybook.Dashboard.Modals.Dialog do
  use PhoenixStorybook.Story, :component
  alias JS

  def function, do: &MaveCoreWeb.DashboardComponents.dialog/1

  def variations do
    [
      %Variation{
        id: :default,
        description: "Default confirmation dialog",
        attributes: %{
          static: true,
          show: true,
          on_confirm: JS.push("confirm"),
          on_cancel: JS.push("cancel")
        },
        slots: ["This action cannot be reversed."]
      },
      %Variation{
        id: :with_title,
        description: "Dialog with custom title",
        attributes: %{
          static: true,
          show: true,
          title: "Delete Video?",
          on_confirm: JS.push("confirm"),
          on_cancel: JS.push("cancel")
        },
        slots: ["The video and all associated data will be permanently deleted."]
      },
      %Variation{
        id: :disabled,
        description: "Dialog with disabled buttons (processing)",
        attributes: %{
          static: true,
          show: true,
          title: "Processing...",
          disabled: true,
          on_confirm: JS.push("confirm"),
          on_cancel: JS.push("cancel")
        },
        slots: ["Please wait while we process your request."]
      }
    ]
  end
end
