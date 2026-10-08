defmodule MaveCoreWeb.DashboardComponents.NavigationTest do
  use ExUnit.Case, async: false
  use Phoenix.Component

  import MaveCoreWeb.DashboardComponents.Navigation
  import Phoenix.LiveViewTest

  setup do
    original_items = Application.get_env(:mave_core, :extra_dashboard_items)

    on_exit(fn ->
      if is_nil(original_items) do
        Application.delete_env(:mave_core, :extra_dashboard_items)
      else
        Application.put_env(:mave_core, :extra_dashboard_items, original_items)
      end
    end)

    :ok
  end

  test "standalone menu has no footer links by default" do
    document = menu_document()

    assert Enum.map(LazyHTML.query(document, "a"), &(&1 |> LazyHTML.text() |> String.trim())) ==
             ["Video", "Data", "Settings"]

    assert Enum.empty?(LazyHTML.query(document, "#dashboard-menu-footer"))
  end

  test "configured footer links support space-aware paths and external URLs" do
    Application.put_env(:mave_core, :extra_dashboard_items, [
      %{label: "Tools", path: "/tools"},
      %{
        label: "Preferences",
        path: {MaveCoreWeb.DashboardRoutes, :settings_path, [:general]},
        placement: :menu_footer
      },
      %{label: "Reference", href: "https://example.com", placement: :menu_footer},
      %{label: "Hidden", path: "/hidden", placement: :menu_footer, visible?: false}
    ])

    document = menu_document()
    footer = LazyHTML.query(document, "#dashboard-menu-footer")

    assert Enum.map(LazyHTML.query(footer, "a"), &(&1 |> LazyHTML.text() |> String.trim())) ==
             ["Preferences", "Reference"]

    assert Enum.count(LazyHTML.query(document, "a[href='/tools'][data-phx-link='redirect']")) == 1

    assert Enum.count(
             LazyHTML.query(footer, "a[href='/space-id/settings'][data-phx-link='redirect']")
           ) == 1

    assert Enum.count(LazyHTML.query(footer, "a[href='https://example.com'][target='_blank']")) ==
             1
  end

  test "footer separator is absent when all configured footer links are hidden" do
    Application.put_env(:mave_core, :extra_dashboard_items, [
      %{label: "Hidden", path: "/hidden", placement: :menu_footer, visible?: false}
    ])

    assert Enum.empty?(LazyHTML.query(menu_document(), "#dashboard-menu-footer"))
  end

  test "sidebar_usage shows bandwidth above the limit in red" do
    assigns = %{
      usage: %{
        embeds_used: 1,
        embeds_percentage: 10.0,
        bandwidth_used_gb: 4_000,
        bandwidth_percentage: 133.333333
      }
    }

    html =
      rendered_to_string(~H"""
      <.sidebar_usage usage={@usage} />
      """)

    assert html =~ ~s(data-usage-segment="within-limit")
    assert html =~ ~s(style="width: 75.0%;")
    assert html =~ ~s(data-usage-segment="overage")
    assert html =~ "bg-red-500"
    assert html =~ ~s(style="width: 25.0%;")
  end

  test "sidebar_usage keeps bandwidth below the limit entirely blue" do
    assigns = %{
      usage: %{
        embeds_used: 1,
        embeds_percentage: 10.0,
        bandwidth_used_gb: 1_000,
        bandwidth_percentage: 25.0
      }
    }

    html =
      rendered_to_string(~H"""
      <.sidebar_usage usage={@usage} />
      """)

    assert html =~ ~s(data-usage-segment="within-limit")
    assert html =~ ~s(style="width: 25.0%;")
    refute html =~ ~s(data-usage-segment="overage")
  end

  test "menu only shows a vertical scrollbar when its content overflows" do
    assigns = %{
      current_user: %{email: "user@mave.io"},
      current_space: %{id: "space-id"}
    }

    html =
      rendered_to_string(~H"""
      <.menu current_user={@current_user} current_space={@current_space} />
      """)

    assert html =~ "overflow-y-auto"
    refute html =~ "overflow-y-scroll"
  end

  defp menu_document do
    render_component(&menu/1,
      current_user: %{id: "user-id", email: "user@example.com"},
      current_space: %{id: "space-id"}
    )
    |> LazyHTML.from_fragment()
  end
end
