defmodule Storybook.Dashboard.Fields.PasswordAccess do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.password_access/1

  def variations do
    for protected <- [false, true] do
      %Variation{
        id: if(protected, do: :protected, else: :public),
        attributes: %{
          embed: %MaveCore.Embeds.Embed{password_protected: protected},
          form: Phoenix.Component.to_form(%{}, as: :playback)
        }
      }
    end
  end
end
