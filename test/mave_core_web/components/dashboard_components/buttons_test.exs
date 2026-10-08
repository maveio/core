defmodule MaveCoreWeb.DashboardComponents.ButtonsTest do
  use ExUnit.Case, async: true
  use Phoenix.Component

  import MaveCoreWeb.DashboardComponents.Buttons
  import Phoenix.LiveViewTest

  test "dash_button defaults to submit" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.dash_button>save</.dash_button>
      """)

    assert html =~ ~s(type="submit")
  end

  test "dash_button honors explicit button type" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.dash_button type="button">cancel</.dash_button>
      """)

    assert html =~ ~s(type="button")
    refute html =~ ~s(type="submit")
  end

  test "edit and delete icon buttons share their frame and color" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.dash_button icon="edit" icon_only type="button" />
      <.dash_button icon="delete" icon_only type="button" />
      """)

    assert html =~ "hero-pencil size-[1.125rem]"
    assert html =~ "flex size-9 items-center justify-center text-stone-500"
    assert html =~ ~s(class="w-4 h-4 transform-gpu")
    assert html =~ "p-2.5 text-stone-500"
  end

  test "dropdown_button keeps stacking and accepts menu sizing and hero icons" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.dropdown_button id="space-actions" menu_class="w-36">
        <:item icon="hero-lock-closed" phx-click="open_space">Open</:item>
      </.dropdown_button>
      """)

    assert html =~ "relative flex"
    assert html =~ "absolute right-0 top-10"
    assert html =~ "z-50"
    assert html =~ "w-36"
    assert html =~ "hero-lock-closed"
    refute html =~ "relative z-30 flex"
  end

  test "dropdown_button clickable rows use pointer cursors" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.dropdown_button id="space-actions">
        <:item phx-click="open_space">Open</:item>
      </.dropdown_button>
      """)

    assert html =~ "cursor-pointer hover:bg-stone-100"
    refute html =~ "pl-2 pr-4 cursor-pointer"
  end

  test "dropdown_button treats its trigger as part of the click-away area" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.dropdown_button id="space-actions">
        <:trigger><button type="button">Toggle</button></:trigger>
        <:item phx-click="open_space">Open</:item>
      </.dropdown_button>
      """)

    assert length(Regex.scan(~r/phx-click-away=/, html)) == 1
    assert html =~ ~r/<div class="relative flex[^"]*" phx-click-away=/

    refute html =~
             ~r/<div(?=[^>]*id="space-actions")(?=[^>]*phx-click-away=)[^>]*>/
  end
end
