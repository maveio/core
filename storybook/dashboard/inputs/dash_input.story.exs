defmodule Storybook.Dashboard.Inputs.DashInput do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.dash_input/1

  def template do
    """
    <div class="space-y-8">
      <.psb-variation/>
    </div>
    """
  end

  def variations do
    [
      %Variation{
        id: :default,
        description: "Default text input",
        attributes: %{
          placeholder: "Enter text here..."
        }
      },
      %Variation{
        id: :with_value,
        description: "Input with value",
        attributes: %{
          value: "example.com",
          placeholder: "Domain"
        }
      },
      %Variation{
        id: :disabled,
        description: "Disabled input",
        attributes: %{
          value: "Cannot edit",
          disabled: true
        }
      },
      %Variation{
        id: :with_error,
        description: "Input with error message",
        attributes: %{
          field: %Phoenix.HTML.FormField{
            id: "domain",
            name: "domain",
            value: "invalid",
            errors: [{"is invalid", []}],
            field: :domain,
            form: nil
          },
          placeholder: "yourdomain.com"
        }
      }
    ]
  end
end
