defmodule MaveCoreWeb.DashboardComponents.PlaybackAccess do
  @moduledoc false
  use Phoenix.Component
  use Gettext, backend: MaveCoreWeb.Gettext
  import MaveCoreWeb.CoreComponents, only: [icon: 1, input: 1]

  attr(:embed, :map, required: true)

  def guidance(assigns) do
    ~H"""
    <p
      :if={MaveCore.Playback.protected?(@embed)}
      id="private-playback-guide"
      class="flex items-start gap-2 px-6 py-3 text-xs text-stone-400"
    >
      <.icon name="hero-lock-closed" class="size-4 shrink-0" />
      <span :if={MaveCore.Playback.Password.protected?(@embed)}>
        {gettext(
          "Viewers enter the video password in the player. Removing it keeps this video private and revokes password sessions."
        )}
      </span>
      <span :if={not MaveCore.Playback.Password.protected?(@embed)}>
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

  attr(:embed, :map, required: true)
  attr(:form, :any, required: true)
  attr(:error, :string, default: nil)

  def password_access(assigns) do
    ~H"""
    <section id="video-password-access" class="my-6 rounded-xl border border-stone-200/10 p-5">
      <h3 class="text-sm font-medium text-stone-200">{gettext("Video password")}</h3>
      <p class="mt-1 text-sm text-stone-400">
        {if MaveCore.Playback.Password.protected?(@embed),
          do: gettext("A password is required to watch this video."),
          else: gettext("Set a password to protect this video and its media files.")}
      </p>
      <.form
        for={@form}
        id="video-password-form"
        phx-submit="set_playback_password"
        class="mt-4 flex flex-wrap items-end gap-3"
      >
        <.input
          field={@form[:password]}
          type="password"
          label={gettext("New video password")}
          autocomplete="new-password"
          required
          maxlength="1024"
        />
        <button
          id="save-video-password"
          type="submit"
          phx-disable-with={gettext("Saving…")}
          class="rounded-md bg-stone-100 px-3 py-2 text-sm text-stone-900 hover:bg-white transition-colors"
        >
          {if MaveCore.Playback.Password.protected?(@embed),
            do: gettext("Change password"),
            else: gettext("Set password")}
        </button>
        <button
          :if={MaveCore.Playback.Password.protected?(@embed)}
          id="remove-video-password"
          type="button"
          phx-click="remove_playback_password"
          class="rounded-md px-3 py-2 text-sm text-stone-300 hover:bg-stone-800 transition-colors"
        >
          {gettext("Remove password")}
        </button>
      </.form>
      <p :if={@error} id="video-password-error" role="alert" class="mt-2 text-sm text-red-400">
        {@error}
      </p>
    </section>
    """
  end
end
