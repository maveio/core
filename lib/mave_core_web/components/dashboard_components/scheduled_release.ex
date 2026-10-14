defmodule MaveCoreWeb.DashboardComponents.ScheduledRelease do
  @moduledoc """
  Scheduled release notice and form for the video detail page.

  Times are stored in UTC. The `release_time_input` hook converts the viewer's
  local `datetime-local` value to UTC before submit, and `local_time` renders a
  stored time in the viewer's time zone.
  """
  use Phoenix.Component
  use Gettext, backend: MaveCoreWeb.Gettext

  import MaveCoreWeb.CoreComponents, only: [icon: 1]
  import MaveCoreWeb.DashboardComponents.Buttons, only: [dash_button: 1]
  import MaveCoreWeb.DashboardComponents.Inputs, only: [dash_input: 1]
  import MaveCoreWeb.DashboardComponents.Modals, only: [modal: 1]

  alias MaveCore.Embeds.Release
  alias Phoenix.LiveView.JS

  @doc "Notice shown under the player while a release is pending."
  attr :embed, :map, required: true
  attr :id, :string, default: "scheduled-release-notice"

  def release_notice(assigns) do
    assigns =
      assigns
      |> assign(:due, Release.due?(assigns.embed))
      |> assign(:securing, assigns.embed.playback_status == :protecting)

    ~H"""
    <div
      :if={Release.pending?(@embed)}
      id={@id}
      class="flex items-center gap-4 px-6 py-3 text-xs text-stone-400"
    >
      <.icon name="hero-clock" class="size-4 shrink-0 text-blue-400" />
      <p class="grow">
        <%= cond do %>
          <% @due -> %>
            {gettext("Release time reached. The video becomes available once storage is public.")}
          <% @securing -> %>
            {gettext("Making storage private for the release on")}
            <.local_time id={"#{@id}-time"} at={@embed.release_at} class="text-stone-200" />…
          <% true -> %>
            {gettext("Scheduled for release on")}
            <.local_time id={"#{@id}-time"} at={@embed.release_at} class="text-stone-200" />. {gettext(
              "Viewers see a countdown. The video, thumbnails and downloads stay unavailable until then."
            )}
        <% end %>
      </p>
      <button
        :if={!@due}
        type="button"
        id={"#{@id}-change"}
        phx-click="open_release_form"
        class="shrink-0 underline underline-offset-2 hover:text-stone-200"
      >
        {gettext("change")}
      </button>
      <button
        :if={!@due}
        type="button"
        id={"#{@id}-publish"}
        phx-click="release_now"
        class="shrink-0 underline underline-offset-2 hover:text-stone-200 phx-click-loading:opacity-50"
      >
        {gettext("publish now")}
      </button>
    </div>
    """
  end

  @doc "Slide-in form to schedule or reschedule a release."
  attr :show, :boolean, required: true
  attr :embed, :map, required: true
  attr :id, :string, default: "release-modal"

  def release_form(assigns) do
    ~H"""
    <.modal
      id={@id}
      show={@show}
      title={
        if Release.pending?(@embed), do: gettext("Change release"), else: gettext("Schedule release")
      }
      on_cancel={JS.push("close_release_form")}
    >
      <.form
        for={%{}}
        as={:release}
        id="release-form"
        phx-submit="schedule_release"
        phx-hook="release_time_input"
        data-release-at={Release.release_unix(@embed)}
        class="flex flex-col gap-6"
      >
        <p class="text-sm text-stone-500">
          {gettext(
            "Until this moment the video is private in storage. Embeds show a countdown and start playing automatically once it ends."
          )}
        </p>
        <p class="text-xs text-stone-400">
          {gettext(
            "Schedule before you share the embed: anything viewers already loaded, such as cached thumbnails, cannot be recalled."
          )}
        </p>
        <%!-- Ignored so re-renders keep the picked time; the hook fills release[at]. --%>
        <div id="release-inputs" phx-update="ignore" class="flex flex-col gap-2">
          <label for="release-local" class="text-sm font-medium text-stone-600">
            {gettext("Release date and time")}
          </label>
          <.dash_input type="datetime-local" name="release-local" />
          <p data-role="time-zone" class="text-xs text-stone-400"></p>
          <input type="hidden" name="release[at]" id="release-at" value="" />
        </div>
        <div class="flex items-center justify-end">
          <.dash_button id="release-submit" variant="primary" loading_on_submit>
            {if Release.pending?(@embed), do: gettext("save"), else: gettext("schedule")}
          </.dash_button>
        </div>
      </.form>
    </.modal>
    """
  end

  @doc "A UTC time rendered in the viewer's time zone (UTC without JavaScript)."
  attr :id, :string, required: true
  attr :at, DateTime, required: true
  attr :class, :string, default: nil

  def local_time(assigns) do
    ~H"""
    <time
      id={@id}
      datetime={DateTime.to_iso8601(@at)}
      phx-hook="local_time"
      class={@class}
    >
      {Calendar.strftime(@at, "%Y-%m-%d %H:%M UTC")}
    </time>
    """
  end
end
