defmodule MaveCoreWeb.DashboardComponents.PlaybackAccess do
  @moduledoc false
  use Phoenix.Component
  use Gettext, backend: MaveCoreWeb.Gettext
  import MaveCoreWeb.CoreComponents, only: [icon: 1]

  attr(:embed, :map, required: true)

  def guidance(assigns) do
    ~H"""
    <p
      :if={MaveCore.Playback.protected?(@embed)}
      id="private-playback-guide"
      class="flex items-start gap-2 px-6 py-3 text-xs text-stone-400"
    >
      <.icon name="hero-lock-closed" class="size-4 shrink-0" />
      <span>
        {gettext(
          "Replace YOUR_PLAYBACK_TOKEN with a temporary JWT signed on your server using a read-only API key from your space. Dashboard previews work automatically."
        )}
        <.link
          href="https://www.mave.io/docs/secure-video-playback/"
          target="_blank"
          rel="noopener noreferrer"
          class="underline underline-offset-2 hover:text-stone-200"
        >
          {gettext("Secure video playback docs")}
        </.link>
      </span>
    </p>
    """
  end
end
