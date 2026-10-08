defmodule Storybook.Dashboard.Navigation.Footer do
  use PhoenixStorybook.Story, :component

  def function, do: &MaveCoreWeb.DashboardComponents.footer/1

  def variations do
    [
      %Variation{
        id: :default,
        description: "Simple footer bar",
        attributes: %{
          static: true
        }
      },
      %Variation{
        id: :with_pagination,
        description: "Footer with pagination",
        attributes: %{
          static: true,
          page: 1,
          total_pages: 5
        }
      },
      %Variation{
        id: :last_page,
        description: "Footer on last page",
        attributes: %{
          static: true,
          page: 5,
          total_pages: 5
        }
      }
    ]
  end
end
