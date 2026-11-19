defmodule MaveCoreWeb.Dashboard.Live.Components do
  @moduledoc false
  use Phoenix.Component
  use Gettext, backend: MaveCoreWeb.Gettext

  alias MaveCore.LiveStreams.LiveStream

  attr :status, :atom, required: true
  attr :id, :string, default: nil

  def status_badge(assigns) do
    ~H"""
    <span
      id={@id}
      data-status={@status}
      class={[
        "inline-flex flex-none items-center gap-1.5 rounded-full px-2.5 py-0.5 text-xs font-medium",
        badge_class(@status)
      ]}
    >
      <span class={["size-1.5 rounded-full", dot_class(@status)]}></span>
      {status_label(@status)}
    </span>
    """
  end

  def status_label(:live), do: gettext("Live")
  def status_label(:disconnected), do: gettext("Reconnecting")
  def status_label(:ended), do: gettext("Ended")
  def status_label(_status), do: gettext("Offline")

  defp badge_class(:live), do: "bg-red-50 text-red-600 ring-1 ring-inset ring-red-200"

  defp badge_class(:disconnected),
    do: "bg-amber-50 text-amber-700 ring-1 ring-inset ring-amber-200"

  defp badge_class(_status), do: "bg-stone-50 text-stone-400 ring-1 ring-inset ring-stone-200/70"

  defp dot_class(:live), do: "bg-red-500 motion-safe:animate-pulse"
  defp dot_class(:disconnected), do: "bg-amber-500"
  defp dot_class(_status), do: "bg-stone-300"

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  slot :action

  @doc "A labelled value with a copy button. Long values wrap instead of overflowing."
  def address_field(assigns) do
    ~H"""
    <div class="w-full border-b border-stone-100 p-3.5 last:border-none">
      <div class="mb-1.5 flex items-center text-xs text-stone-400">
        <div class="flex-grow">{@label}</div>
        {render_slot(@action)}
      </div>
      <div class="flex items-start rounded bg-stone-50 p-2.5 text-sm text-stone-400 select-text">
        <div id={@id} class="mr-2 min-w-0 flex-grow break-all font-mono text-xs leading-5">
          {@value}
        </div>
        <MaveCoreWeb.DashboardComponents.Fields.copy_button target={@id} />
      </div>
    </div>
    """
  end

  def stream_name(%LiveStream{name: name}) when is_binary(name) and name != "", do: name
  def stream_name(_stream), do: gettext("Untitled stream")

  @doc "Elapsed time as `m:ss` or `h:mm:ss`."
  def duration(seconds) when is_number(seconds) do
    seconds = max(trunc(seconds), 0)
    hours = div(seconds, 3600)
    minutes = seconds |> rem(3600) |> div(60)
    rest = seconds |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")

    if hours > 0,
      do: "#{hours}:#{minutes |> Integer.to_string() |> String.pad_leading(2, "0")}:#{rest}",
      else: "#{minutes}:#{rest}"
  end

  def duration(_seconds), do: nil
end
