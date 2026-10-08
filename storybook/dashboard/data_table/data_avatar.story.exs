defmodule Storybook.Dashboard.DataTable.DataAvatar do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.data_avatar/1

  def variations do
    [
      %Variation{
        id: :default,
        description: "Default blue avatar",
        attributes: %{
          initials: "JD"
        }
      },
      %Variation{
        id: :red,
        description: "Red avatar",
        attributes: %{
          initials: "AB",
          color: "red"
        }
      },
      %Variation{
        id: :green,
        description: "Green avatar",
        attributes: %{
          initials: "CD",
          color: "green"
        }
      },
      %Variation{
        id: :purple,
        description: "Purple avatar",
        attributes: %{
          initials: "EF",
          color: "purple"
        }
      },
      %Variation{
        id: :amber,
        description: "Amber avatar",
        attributes: %{
          initials: "GH",
          color: "amber"
        }
      },
      %VariationGroup{
        id: :all_colors,
        description: "All color options",
        variations:
          for color <- ~w(red orange amber yellow lime green emerald teal cyan sky blue indigo violet purple fuchsia pink rose stone) do
            %Variation{
              id: String.to_atom(color),
              attributes: %{
                initials: String.upcase(String.slice(color, 0, 2)),
                color: color
              }
            }
          end
      }
    ]
  end
end
