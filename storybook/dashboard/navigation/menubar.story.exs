defmodule Storybook.Dashboard.Navigation.Menubar do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.menubar/1

  def imports, do: [{MaveCoreWeb.DashboardComponents, [menubar_item: 1]}]

  def variations do
    [
      %Variation{
        id: :default,
        description: "Settings page menubar with all tabs",
        slots: [
          """
          <.menubar_item icon="general" path="/settings" active={true}>General</.menubar_item>
          <.menubar_item icon="team" path="/settings/team" active={false}>Team</.menubar_item>
          <.menubar_item icon="billing" path="/settings/billing" active={false}>Billing</.menubar_item>
          <.menubar_item icon="developer" path="/settings/developer" active={false}>Developer</.menubar_item>
          <.menubar_item icon="support" path="/settings/support" active={false}>Support</.menubar_item>
          """
        ]
      },
      %Variation{
        id: :developer_active,
        description: "Developer tab active",
        slots: [
          """
          <.menubar_item icon="general" path="/settings" active={false}>General</.menubar_item>
          <.menubar_item icon="team" path="/settings/team" active={false}>Team</.menubar_item>
          <.menubar_item icon="billing" path="/settings/billing" active={false}>Billing</.menubar_item>
          <.menubar_item icon="developer" path="/settings/developer" active={true}>Developer</.menubar_item>
          """
        ]
      },
      %Variation{
        id: :minimal,
        description: "Minimal menubar (2 tabs)",
        slots: [
          """
          <.menubar_item icon="general" path="/settings" active={true}>Settings</.menubar_item>
          <.menubar_item icon="developer" path="/settings/developer" active={false}>Developer</.menubar_item>
          """
        ]
      }
    ]
  end
end
