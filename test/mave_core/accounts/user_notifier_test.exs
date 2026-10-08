defmodule MaveCore.Accounts.UserNotifierTest do
  use ExUnit.Case, async: false

  alias MaveCore.Accounts.UserNotifier

  setup do
    previous = Application.fetch_env(:mave_core, :email_branding)
    Application.delete_env(:mave_core, :email_branding)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:mave_core, :email_branding, value)
        :error -> Application.delete_env(:mave_core, :email_branding)
      end
    end)
  end

  test "default email layout is independent of any hosted service" do
    html = UserNotifier.email_layout("<td>Welcome</td>")

    assert html =~ "<td>Welcome</td>"
    assert html =~ "Sent automatically by Mave Core."
    refute html =~ "mave.io"
    refute html =~ "subscription"
  end

  test "a host can supply an email layout without changing the inner content" do
    Application.put_env(:mave_core, :email_branding, layout: __MODULE__)

    assert UserNotifier.email_layout("<td>Welcome</td>") == "Custom: <td>Welcome</td>"
  end

  test "custom product names are escaped in the default layout" do
    Application.put_env(:mave_core, :email_branding, %{"product_name" => "Video <Team>"})

    assert UserNotifier.email_layout("") =~ "Video &lt;Team&gt;"
  end

  def render(content), do: "Custom: " <> content
end
