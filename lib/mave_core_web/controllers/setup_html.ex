defmodule MaveCoreWeb.SetupHTML do
  use MaveCoreWeb, :html

  import MaveCoreWeb.DashboardComponents,
    only: [dash_input: 1, dash_button: 1, info_box: 1, animated_icon: 1]

  embed_templates "setup_html/*"
end
