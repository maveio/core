defmodule MaveCoreWeb.DashboardComponents.AnimatedIcon do
  @moduledoc """
  Renders semantic dashboard illustrations without coupling Core to proprietary assets.

  Host applications may configure an `:animated_icon_backend` that exports
  `render/1`. Core falls back to Heroicons and a small inline wave illustration.
  """

  use Phoenix.Component

  import MaveCoreWeb.CoreComponents, only: [icon: 1]

  @fallback_icons %{
    "avatar" => "hero-user-circle",
    "avatar_light" => "hero-user-circle",
    "checked" => "hero-check-circle",
    "cross" => "hero-x-circle",
    "envelope" => "hero-envelope",
    "globe" => "hero-globe-alt",
    "link" => "hero-link",
    "processing" => "hero-arrow-path",
    "stars" => "hero-sparkles",
    "upload" => "hero-arrow-up-tray",
    "warning" => "hero-exclamation-triangle"
  }

  attr :name, :string, required: true
  attr :class, :any, default: "size-6"
  attr :speed, :any, default: "1"
  attr :autoplay, :boolean, default: true
  attr :loop, :boolean, default: false
  attr :rest, :global

  def animated_icon(assigns) do
    case configured_backend() do
      nil -> render_fallback(assigns)
      backend -> backend.render(assigns)
    end
  end

  defp render_fallback(%{name: "waves"} = assigns) do
    ~H"""
    <svg
      class={@class}
      viewBox="0 0 120 48"
      preserveAspectRatio="none"
      fill="#60a5fa"
      aria-hidden="true"
      {@rest}
    >
      <path d="M0 0h120v31c-38 8-75-13-120-5Z" opacity="0.55" />
      <path d="M0 0h120v23C81 34 43 16 0 22Z" opacity="0.35" />
    </svg>
    """
  end

  defp render_fallback(assigns) do
    assigns =
      assign(
        assigns,
        :fallback_name,
        Map.get(@fallback_icons, assigns.name, "hero-question-mark-circle")
      )

    ~H"""
    <.icon
      name={@fallback_name}
      class={[
        @class,
        @name == "processing" && "motion-safe:animate-spin"
      ]}
      {@rest}
    />
    """
  end

  defp configured_backend do
    case Application.get_env(:mave_core, :animated_icon_backend) do
      backend when is_atom(backend) ->
        if Code.ensure_loaded?(backend) and function_exported?(backend, :render, 1),
          do: backend,
          else: nil

      _other ->
        nil
    end
  end
end
