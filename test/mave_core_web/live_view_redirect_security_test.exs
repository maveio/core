defmodule MaveCoreWeb.LiveViewRedirectSecurityTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView
  alias Phoenix.LiveView.Socket

  test "rejects local redirects obscured by browser-stripped whitespace" do
    for target <- ["/%09/example.com", "/\t/example.com", "/example.com/\n", "/example.com\r"] do
      assert_raise ArgumentError, ~r/unsafe characters detected/, fn ->
        LiveView.redirect(%Socket{}, to: target)
      end
    end
  end

  test "keeps ordinary local redirects working" do
    assert %Socket{redirected: {:redirect, %{status: 302, to: "/videos"}}} =
             LiveView.redirect(%Socket{}, to: "/videos")
  end
end
