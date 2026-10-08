defmodule Storybook.Dashboard.Modals.Modal do
  use PhoenixStorybook.Story, :component
  alias Phoenix.LiveView.JS

  def function, do: &MaveCoreWeb.DashboardComponents.modal/1

  def imports, do: [{MaveCoreWeb.DashboardComponents, [dash_input: 1, info_box: 1, dash_button: 1]}]

  def variations do
    [
      %Variation{
        id: :default,
        description: "Slide-in modal panel (matching ManageUI Link domain)",
        attributes: %{
          static: true,
          show: true,
          title: "Link domain",
          on_cancel: JS.push("cancel")
        },
        slots: [
          """
          <.info_box>
            Link the domain name of your preference to make the embed your own.
            Make sure the CNAME is pointing to domains.mave.io
          </.info_box>
          <div class="mt-8">
            <.dash_input placeholder="yourdomain.com" />
          </div>
          <div class="flex mt-8">
            <div class="flex-grow"></div>
            <.dash_button icon="link">link</.dash_button>
          </div>
          """
        ]
      },
      %Variation{
        id: :hidden,
        description: "Hidden modal (show=false)",
        attributes: %{
          static: true,
          show: false,
          title: "Hidden Modal",
          on_cancel: JS.push("cancel")
        },
        slots: ["This content is not visible."]
      }
    ]
  end
end
