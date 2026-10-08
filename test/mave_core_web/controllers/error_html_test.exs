defmodule MaveCoreWeb.ErrorHTMLTest do
  use ExUnit.Case, async: true

  alias MaveCoreWeb.ErrorHTML
  alias Phoenix.HTML.Safe

  defp render_error(template) do
    template
    |> ErrorHTML.render(%{})
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  test "renders the styled bad request page" do
    html = render_error("400.html")

    assert html =~ "<!DOCTYPE html>"
    assert html =~ "<title>Bad request</title>"
    assert html =~ "Bad request"
    assert html =~ "/assets/css/app.css"
    assert html =~ "/images/glyph.svg"
  end

  test "renders the styled internal server error page" do
    html = render_error("500.html")

    assert html =~ "<!DOCTYPE html>"
    assert html =~ "<title>Server error</title>"
    assert html =~ "Server error"
    assert html =~ "Something went wrong while loading this page."
  end

  test "renders the styled not found page" do
    html = render_error("404.html")

    assert html =~ "<!DOCTYPE html>"
    assert html =~ "<title>Page not found</title>"
    assert html =~ "Page not found"
  end

  test "keeps Phoenix status text fallback for uncustomized errors" do
    assert render_error("401.html") == "Unauthorized"
  end
end
