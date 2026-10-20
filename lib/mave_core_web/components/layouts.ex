defmodule MaveCoreWeb.Layouts do
  @moduledoc """
  Shared layout helpers used by the app's custom HEEx layouts.
  """
  use MaveCoreWeb, :html

  import MaveCoreWeb.DashboardComponents, except: [icon: 1]

  embed_templates "layouts/*"

  @doc """
  Renders a development-only alignment grid overlay, toggled with Ctrl+G.

  Renders nothing unless dev routes are enabled, so the overlay never ships
  in production builds.
  """
  if Application.compile_env(:mave_core, :dev_routes, false) do
    def dev_grid(assigns) do
      ~H"""
      <div
        id="dev-grid"
        aria-hidden="true"
        hidden
        class="pointer-events-none fixed inset-0 z-[9999]"
        style="background-image: linear-gradient(to right, rgb(255 0 80 / 0.22) 1px, transparent 1px), linear-gradient(to bottom, rgb(255 0 80 / 0.22) 1px, transparent 1px), linear-gradient(to right, rgb(255 0 80 / 0.08) 1px, transparent 1px), linear-gradient(to bottom, rgb(255 0 80 / 0.08) 1px, transparent 1px); background-size: 32px 32px, 32px 32px, 8px 8px, 8px 8px;"
      >
      </div>
      """
    end
  else
    def dev_grid(assigns) do
      ~H"""
      """
    end
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
