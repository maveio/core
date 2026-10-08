if Application.compile_env(:mave_core, :dev_routes, false) do
  defmodule MaveCoreWeb.Storybook do
    @moduledoc false

    use PhoenixStorybook,
      otp_app: :mave_core,
      content_path: Path.expand("../../storybook", __DIR__),
      # Assets path are remote paths, not local file-system paths
      css_path: "/assets/css/storybook.css",
      js_path: "/assets/js/storybook.js",
      sandbox_class: "mave-core",
      title: "Mave Component Library"
  end
end
