defmodule MaveCoreWeb.DevRoutes do
  @moduledoc false

  @enabled Application.compile_env(:mave_core, :dev_routes, false)

  # Quote optional imports only when enabled: imports expand even inside a
  # module-level `if`, before Elixir evaluates its condition.
  defmacro __using__(_opts) do
    if @enabled do
      quote do
        import Phoenix.LiveDashboard.Router
        import PhoenixStorybook.Router

        scope "/" do
          storybook_assets()
        end

        scope "/dev" do
          pipe_through :browser

          live_dashboard "/dashboard", metrics: MaveCoreWeb.Telemetry
          forward "/mailbox", Plug.Swoosh.MailboxPreview
        end

        # Storybook requires its own scope for internal path handling.
        scope "/" do
          pipe_through :browser
          live_storybook("/storybook", backend_module: MaveCoreWeb.Storybook)
        end
      end
    end
  end
end
