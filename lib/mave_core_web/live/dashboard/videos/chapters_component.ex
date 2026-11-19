defmodule MaveCoreWeb.Dashboard.Videos.ChaptersComponent do
  @moduledoc """
  Review, edit and publish the chapters of a video.

  Edits are saved to the draft as they are made and shown on the preview
  player's timeline. Viewers only get them after **Publish**.
  """
  use MaveCoreWeb, :live_component

  import MaveCoreWeb.DashboardComponents, only: [dash_button: 1, video_data_section: 1]

  alias MaveCore.Assets.{ChapterSet, Video}
  alias MaveCore.Chapters
  alias MaveCore.UsageLimits

  @impl true
  def update(%{refresh: _token}, socket), do: {:ok, load(socket)}

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(Map.take(assigns, [:id, :embed, :player_dom_id, :current_space]))
     |> assign_new(:confirm_replace, fn -> false end)
     |> assign_new(:focus_row, fn -> nil end)
     |> assign_new(:error, fn -> nil end)
     |> assign(
       :can_suggest,
       UsageLimits.can_use_automatic_chapters?(assigns.current_space) == :ok
     )
     |> load()}
  end

  # Rows keep what was typed. They are rebuilt only when the stored draft is
  # no longer the one they were made from (a new suggestion, another session).
  defp load(socket) do
    video = current_video(socket.assigns.embed)
    set = video && Chapters.get_set(video.id)
    draft = (set && set.draft) || []
    synced = {video && video.id, draft}

    socket = assign(socket, video: video, set: set)

    if socket.assigns[:synced] == synced do
      socket
    else
      socket
      |> assign(:synced, synced)
      |> assign(:rows, Enum.map(draft, &row/1))
      |> assign(:error, nil)
    end
  end

  defp current_video(%{asset: %{current_video: %Video{} = video}}), do: video
  defp current_video(_embed), do: nil

  defp row(%{"start" => start, "title" => title}) do
    %{id: row_id(), start: start, time: format_time(start), title: title, error: nil}
  end

  defp row_id, do: "c#{System.unique_integer([:positive])}"

  # --- Events -------------------------------------------------------------

  @impl true
  def handle_event("change", %{"chapters" => params}, socket) do
    rows =
      Enum.map(socket.assigns.rows, fn row ->
        case params[row.id] do
          %{} = input -> edit_row(row, input)
          _ -> row
        end
      end)

    {:noreply, socket |> assign(:focus_row, nil) |> save(rows)}
  end

  def handle_event("change", _params, socket), do: {:noreply, socket}

  def handle_event("add_chapter", params, socket) do
    rows = socket.assigns.rows
    taken = MapSet.new(rows, &round_start(&1.start))
    start = params |> Map.get("time") |> new_start(socket.assigns.video, taken)

    new = %{
      id: row_id(),
      start: start,
      time: format_time(start),
      title: gettext("New chapter"),
      error: nil
    }

    {:noreply, socket |> assign(:focus_row, new.id) |> save(rows ++ [new])}
  end

  def handle_event("remove", %{"id" => id}, socket) do
    {:noreply, save(socket, Enum.reject(socket.assigns.rows, &(&1.id == id)))}
  end

  def handle_event("suggest", _params, socket) do
    if socket.assigns.rows == [] do
      {:noreply, request_suggestion(socket)}
    else
      {:noreply, assign(socket, :confirm_replace, true)}
    end
  end

  def handle_event("confirm_suggest", _params, socket) do
    {:noreply, socket |> assign(:confirm_replace, false) |> request_suggestion()}
  end

  def handle_event("cancel_suggest", _params, socket) do
    {:noreply, assign(socket, :confirm_replace, false)}
  end

  def handle_event("publish", _params, socket) do
    case Chapters.publish(socket.assigns.embed) do
      {:ok, _set} ->
        {:noreply, socket |> assign(:error, nil) |> load()}

      {:error, _reason} ->
        {:noreply, assign(socket, :error, gettext("Could not publish the chapters."))}
    end
  end

  def handle_event("unpublish", _params, socket) do
    case Chapters.unpublish(socket.assigns.embed) do
      {:ok, _set} ->
        {:noreply, socket |> assign(:error, nil) |> load()}

      {:error, _reason} ->
        {:noreply, assign(socket, :error, gettext("Could not unpublish the chapters."))}
    end
  end

  defp request_suggestion(socket) do
    case Chapters.request_suggestion(socket.assigns.embed) do
      {:ok, _set} ->
        socket |> assign(:error, nil) |> load()

      {:error, _reason} ->
        assign(socket, :error, gettext("Chapter suggestions aren't available for this video."))
    end
  end

  defp edit_row(row, input) do
    time = input |> Map.get("time", row.time) |> to_string() |> String.trim()
    title = input |> Map.get("title", row.title) |> to_string()

    # Suggested starts are more precise than the text shows; keep them unless
    # the time was edited.
    start = if time == row.time, do: row.start, else: parse_time(time)
    %{row | time: time, title: title, start: start}
  end

  defp save(socket, rows) do
    duration = socket.assigns.video && socket.assigns.video.duration
    rows = validate(rows, duration)

    if Enum.any?(rows, & &1.error) or is_nil(socket.assigns.video) do
      socket
      |> assign(:rows, rows)
      |> assign(:error, gettext("Not saved yet: fix the marked chapter."))
    else
      chapters = Enum.map(rows, &%{"start" => &1.start, "title" => &1.title})

      case Chapters.save_draft(socket.assigns.video, chapters) do
        {:ok, set} ->
          rows =
            rows
            |> Enum.sort_by(& &1.start)
            |> Enum.map(&%{&1 | time: format_time(&1.start), title: String.trim(&1.title)})

          socket
          |> assign(set: set, rows: rows, error: nil)
          |> assign(:synced, {socket.assigns.video.id, set.draft})

        {:error, _reason} ->
          socket
          |> assign(:rows, rows)
          |> assign(:error, gettext("Could not save the chapters."))
      end
    end
  end

  defp validate(rows, duration) do
    starts = rows |> Enum.map(&round_start(&1.start)) |> Enum.frequencies()

    Enum.map(rows, fn row ->
      error =
        cond do
          not is_number(row.start) ->
            gettext("Use a time like 1:30")

          is_number(duration) and duration > 0 and row.start >= duration ->
            gettext("After the end of the video")

          Map.get(starts, round_start(row.start), 0) > 1 ->
            gettext("Another chapter starts here")

          String.trim(row.title) == "" ->
            gettext("Add a title")

          String.length(row.title) > ChapterSet.max_title_length() ->
            gettext("Title is too long")

          true ->
            nil
        end

      %{row | error: error}
    end)
  end

  defp round_start(start) when is_number(start), do: Float.round(start * 1.0, 3)
  defp round_start(_start), do: nil

  # A new chapter starts at the playback position, at a whole second that is free.
  defp new_start(time, video, taken) do
    duration = (video && video.duration) || 0
    limit = if duration > 1, do: Float.floor(duration - 1), else: 0.0
    start = if is_number(time) and time > 0, do: Float.floor(time * 1.0), else: 0.0
    start = start |> min(limit) |> max(0.0)

    Stream.iterate(start, &(&1 + 1.0))
    |> Enum.find(&(not MapSet.member?(taken, round_start(&1))))
  end

  # --- Time ---------------------------------------------------------------

  @doc "Seconds as `m:ss` or `h:mm:ss`."
  def format_time(seconds) when is_number(seconds) do
    total = trunc(seconds)
    hours = div(total, 3600)
    minutes = total |> rem(3600) |> div(60)
    secs = total |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")

    if hours > 0,
      do: "#{hours}:#{minutes |> Integer.to_string() |> String.pad_leading(2, "0")}:#{secs}",
      else: "#{minutes}:#{secs}"
  end

  def format_time(_seconds), do: ""

  @doc "Seconds for `90`, `1:30`, `1:30.5` or `1:02:03`; `nil` when it isn't a time."
  def parse_time(text) when is_binary(text) do
    parts =
      text
      |> String.trim()
      |> String.replace(",", ".")
      |> String.split(":")
      |> Enum.map(&parse_number/1)

    if Enum.all?(parts, &is_number/1), do: seconds(parts)
  end

  def parse_time(_text), do: nil

  defp seconds([seconds]), do: seconds
  defp seconds([minutes, seconds]), do: seconds([0.0, minutes, seconds])

  defp seconds([hours, minutes, seconds]) do
    if whole?(hours) and whole?(minutes) and seconds < 60 and (hours == 0 or minutes < 60),
      do: hours * 3600 + minutes * 60 + seconds
  end

  defp seconds(_parts), do: nil

  defp parse_number(text) do
    if Regex.match?(~r/\A\d+(\.\d+)?\z/, text) do
      {value, ""} = Float.parse(text)
      value
    end
  end

  defp whole?(number), do: number == Float.floor(number)

  # --- Rendering ----------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:published_count, length((assigns.set && assigns.set.published) || []))
      |> assign(:generating, match?(%ChapterSet{status: "generating"}, assigns.set))
      |> assign(:dirty, Chapters.unpublished_changes?(assigns.set))
      |> assign(:valid, assigns.rows != [] and Enum.all?(assigns.rows, &is_nil(&1.error)))
      |> assign(
        :preview,
        for(
          %{start: start, title: title, error: nil} <- assigns.rows,
          do: %{start: start, title: title}
        )
      )

    ~H"""
    <div
      id={@id}
      phx-hook="chapters"
      data-player-container={@player_dom_id}
      data-duration={@video && @video.duration}
      data-chapters={Jason.encode!(@preview)}
    >
      <.video_data_section label={gettext("chapters")}>
        <div class="flex flex-wrap items-center gap-3 px-4 pt-4">
          <div id="chapters-status" class="grow text-sm text-stone-500">
            <span
              :if={@published_count > 0 and not @dirty}
              class="inline-flex items-center gap-1.5 text-green-700"
            >
              <span class="h-1.5 w-1.5 rounded-full bg-green-600"></span>
              {ngettext("Published · 1 chapter", "Published · %{count} chapters", @published_count)}
            </span>
            <span
              :if={@published_count > 0 and @dirty}
              class="inline-flex items-center gap-1.5 text-amber-700"
            >
              <span class="h-1.5 w-1.5 rounded-full bg-amber-500"></span>
              {gettext("Published, with changes that viewers don't see yet")}
            </span>
            <span :if={@published_count == 0 and @rows != []} class="inline-flex items-center gap-1.5">
              <span class="h-1.5 w-1.5 rounded-full bg-stone-300"></span>
              {gettext("Draft · not visible to viewers")}
            </span>
            <span :if={@published_count == 0 and @rows == []} class="text-stone-400">
              {gettext("No chapters yet")}
            </span>
          </div>

          <%= if @confirm_replace do %>
            <div id="chapters-confirm-replace" class="flex items-center gap-3 text-sm text-stone-500">
              <span>{gettext("Replace the draft with a new suggestion?")}</span>
              <.dash_button
                id="chapters-confirm-suggest"
                type="button"
                variant="primary"
                phx-click="confirm_suggest"
                phx-target={@myself}
              >
                {gettext("replace")}
              </.dash_button>
              <.dash_button
                id="chapters-cancel-suggest"
                type="button"
                phx-click="cancel_suggest"
                phx-target={@myself}
              >
                {gettext("keep")}
              </.dash_button>
            </div>
          <% else %>
            <.dash_button
              :if={@can_suggest}
              id="chapters-suggest"
              type="button"
              disabled={@generating}
              phx-click="suggest"
              phx-target={@myself}
            >
              {if @rows == [], do: gettext("suggest chapters"), else: gettext("suggest again")}
            </.dash_button>
            <.dash_button id="chapters-add" type="button" data-chapter-add>
              {gettext("add chapter")}
            </.dash_button>
            <.dash_button
              :if={@published_count > 0}
              id="chapters-unpublish"
              type="button"
              phx-click="unpublish"
              phx-target={@myself}
            >
              {gettext("unpublish")}
            </.dash_button>
            <.dash_button
              id="chapters-publish"
              type="button"
              variant="primary"
              disabled={not @valid or (@published_count > 0 and not @dirty)}
              phx-click="publish"
              phx-target={@myself}
            >
              {if @published_count > 0, do: gettext("publish changes"), else: gettext("publish")}
            </.dash_button>
          <% end %>
        </div>

        <div
          :if={@generating}
          id="chapters-generating"
          class="flex items-center gap-2 px-4 pt-4 text-sm text-stone-500"
        >
          <span class="h-3 w-3 rounded-full border-2 border-stone-300 border-t-blue-500 animate-spin"></span>
          {gettext("Suggesting chapters…")}
        </div>

        <div
          :if={notice(@set) && not @generating}
          id="chapters-notice"
          class="px-4 pt-4 text-sm text-stone-500"
        >
          {notice(@set)}
        </div>

        <div :if={@error} id="chapters-error" class="px-4 pt-4 text-sm text-red-600">{@error}</div>

        <form
          id="chapters-form"
          class="px-4 pt-4 pb-2"
          phx-change="change"
          phx-submit="change"
          phx-target={@myself}
        >
          <div
            :for={row <- @rows}
            id={"chapter-#{row.id}"}
            class="flex items-start gap-3 py-1.5"
            data-chapter-row
          >
            <button
              type="button"
              id={"chapter-seek-#{row.id}"}
              data-chapter-seek={row.start}
              disabled={not is_number(row.start)}
              title={gettext("Play from here")}
              aria-label={gettext("Play from here")}
              class="mt-1.5 flex h-7 w-7 flex-none items-center justify-center rounded-full text-stone-400 ring-1 ring-inset ring-stone-200 hover:text-blue-600 hover:ring-blue-500 disabled:opacity-40"
            >
              <svg
                xmlns="http://www.w3.org/2000/svg"
                viewBox="0 0 24 24"
                fill="currentColor"
                class="h-3 w-3"
              >
                <path d="M8 5v14l11-7z" />
              </svg>
            </button>
            <div class="w-24 flex-none">
              <input
                type="text"
                id={"chapter-time-#{row.id}"}
                name={"chapters[#{row.id}][time]"}
                value={row.time}
                inputmode="numeric"
                autocomplete="off"
                aria-label={gettext("Start time")}
                phx-debounce="blur"
                class={[
                  "w-full rounded-md border-0 px-3 py-2 text-sm tabular-nums text-stone-700 outline-none ring-1 ring-inset focus:ring-blue-500",
                  if(row.error, do: "ring-red-400", else: "ring-stone-200")
                ]}
              />
            </div>
            <div class="min-w-0 grow">
              <input
                type="text"
                id={"chapter-title-#{row.id}"}
                name={"chapters[#{row.id}][title]"}
                value={row.title}
                autocomplete="off"
                maxlength={ChapterSet.max_title_length()}
                aria-label={gettext("Chapter title")}
                phx-debounce="400"
                phx-mounted={@focus_row == row.id && JS.focus()}
                data-chapter-new={@focus_row == row.id}
                class={[
                  "w-full rounded-md border-0 px-3 py-2 text-sm text-stone-700 outline-none ring-1 ring-inset focus:ring-blue-500",
                  if(row.error, do: "ring-red-400", else: "ring-stone-200")
                ]}
              />
              <div :if={row.error} class="pt-1 text-xs text-red-600" data-chapter-error>
                {row.error}
              </div>
            </div>
            <button
              type="button"
              id={"chapter-remove-#{row.id}"}
              phx-click="remove"
              phx-value-id={row.id}
              phx-target={@myself}
              title={gettext("Remove chapter")}
              aria-label={gettext("Remove chapter")}
              class="mt-1.5 flex h-7 w-7 flex-none items-center justify-center rounded-full text-stone-400 hover:bg-red-50 hover:text-red-600"
            >
              <svg
                xmlns="http://www.w3.org/2000/svg"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="1.5"
                stroke-linecap="round"
                class="h-4 w-4"
              >
                <line x1="18" y1="6" x2="6" y2="18"></line>
                <line x1="6" y1="6" x2="18" y2="18"></line>
              </svg>
            </button>
          </div>
        </form>

        <div
          :if={provenance(@set) && @rows != []}
          id="chapters-provenance"
          class="px-4 pb-4 text-xs text-stone-400"
        >
          {provenance(@set)}
        </div>
        <div :if={!(provenance(@set) && @rows != [])} class="pb-2"></div>
      </.video_data_section>
    </div>
    """
  end

  defp notice(%ChapterSet{status: "failed", reason: "no_transcript"}),
    do:
      gettext(
        "Chapters are suggested from what is said. This video has no subtitles yet: add subtitles first, or add chapters yourself."
      )

  defp notice(%ChapterSet{status: "failed", reason: "too_short"}),
    do: gettext("This video is too short to suggest chapters. You can still add them yourself.")

  defp notice(%ChapterSet{status: "failed", reason: "no_topic_changes"}),
    do: gettext("No clear change of subject was found. You can still add chapters yourself.")

  defp notice(%ChapterSet{status: "failed"}),
    do: gettext("Suggesting chapters didn't work this time. Try again.")

  defp notice(_set), do: nil

  defp provenance(%ChapterSet{generated_at: %DateTime{}, generator: generator, inputs: inputs}) do
    source =
      if "scenes" in inputs,
        do: gettext("the transcript and scene cuts"),
        else: gettext("the transcript")

    case generator do
      "local" ->
        gettext(
          "Started from a suggestion based on %{source}. Suggested titles are keywords, picked without an AI model.",
          source: source
        )

      _ ->
        gettext(
          "Started from a suggestion based on %{source}. Check the titles and times before publishing.",
          source: source
        )
    end
  end

  defp provenance(_set), do: nil
end
