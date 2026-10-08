defmodule MaveCoreWeb.DashboardComponents.AnimatedIconTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias MaveCoreWeb.DashboardComponents.AnimatedIcon

  defmodule TestBackend do
    use Phoenix.Component

    def render(assigns) do
      ~H"""
      <span data-test-backend={@name} class={@class}></span>
      """
    end
  end

  setup do
    previous_backend = Application.get_env(:mave_core, :animated_icon_backend)

    on_exit(fn -> restore_backend(previous_backend) end)

    Application.delete_env(:mave_core, :animated_icon_backend)
    :ok
  end

  test "uses an OSS-safe fallback by default" do
    html = render_component(&AnimatedIcon.animated_icon/1, %{name: "upload", class: "size-8"})

    assert html =~ "hero-arrow-up-tray"
    assert html =~ "size-8"
    refute html =~ "lottie-player"
  end

  test "renders waves as subtle filled shapes without inherited text-colored strokes" do
    html = render_component(&AnimatedIcon.animated_icon/1, %{name: "waves", class: "opacity-20"})

    assert html =~ ~s(fill="#60a5fa")
    assert html =~ ~s(preserveAspectRatio="none")
    assert html =~ "opacity-20"
    refute html =~ "stroke="
    refute html =~ "lottie-player"
  end

  test "allows the host application to provide its licensed renderer" do
    Application.put_env(:mave_core, :animated_icon_backend, TestBackend)

    html = render_component(&AnimatedIcon.animated_icon/1, %{name: "warning", class: "size-10"})

    assert html =~ ~s(data-test-backend="warning")
    assert html =~ "size-10"

    waves = render_component(&AnimatedIcon.animated_icon/1, %{name: "waves"})
    assert waves =~ ~s(data-test-backend="waves")
    refute waves =~ "<svg"
  end

  defp restore_backend(nil), do: Application.delete_env(:mave_core, :animated_icon_backend)

  defp restore_backend(backend),
    do: Application.put_env(:mave_core, :animated_icon_backend, backend)
end
