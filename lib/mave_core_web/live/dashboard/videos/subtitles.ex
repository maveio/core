defmodule MaveCoreWeb.Dashboard.Videos.Subtitles do
  @moduledoc """
  Subtitle editor for one subtitle track of a video.

  The LiveView owns the cues, their checks and the undo history. The
  `subtitle_editor` hook owns playback, the timeline and caret handling, and
  reads cue text and timing from the rendered rows.
  """

  use MaveCoreWeb, :live_view
  import MaveCoreWeb.DashboardComponents, except: [icon: 1]

  alias MaveCore.Assets
  alias MaveCore.Assets.Subtitle
  alias MaveCore.Assets.SubtitleDocument
  alias MaveCore.Embeds
  alias MaveCore.Embeds.Embed
  alias MaveCore.Languages
  alias MaveCoreWeb.DashboardRoutes

  @history 100
  @edit_burst_ms 1_500

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Subtitles"))
     |> assign(:settings_open, true)
     |> assign(:route_scope, :unscoped)
     |> assign(:pause_while_typing, true)
     |> assign(:show_original, false)
     |> assign(:confirm, nil)
     |> assign(:loaded, false)}
  end

  @impl true
  def handle_params(%{"id" => id, "subtitle_id" => subtitle_id} = params, _url, socket) do
    scope =
      case params do
        %{"space_id" => space_id} when is_binary(space_id) and space_id != "" -> :scoped
        _ -> :unscoped
      end

    {:noreply, socket |> assign(:route_scope, scope) |> load(id, subtitle_id)}
  end

  defp load(socket, id, subtitle_id) do
    space = socket.assigns.current_space

    with {:ok, %Embed{type: :video} = embed} <- Embeds.resolve_dashboard_embed(space, id),
         %{} = video <- Embeds.video_editing_preview(space, embed),
         {:subtitle, %Subtitle{} = subtitle} <-
           {:subtitle, Assets.get_subtitle_for_embed(subtitle_id, embed)},
         {:document, {:ok, document}} <-
           {:document, Assets.read_subtitle_document(embed, subtitle)} do
      subtitles = Assets.all_subtitles_for_video(subtitle.video_id)

      socket
      |> assign(:loaded, true)
      |> assign(:embed, embed)
      |> assign(:video, video)
      |> assign(:subtitle, subtitle)
      |> assign(:subtitles, Enum.map(subtitles, &%{id: &1.id, label: language_label(&1)}))
      |> assign(:original_subtitle, original_subtitle(embed, subtitle, subtitles))
      |> assign(:original_cues, nil)
      |> assign(:show_original, false)
      |> assign(:published_vtt, SubtitleDocument.to_vtt(document))
      |> assign(:selected_id, nil)
      |> assign(:undo, [])
      |> assign(:redo, [])
      |> assign(:last_edit, nil)
      |> assign(:confirm, nil)
      |> put_document(document)
    else
      {step, _reason} when step in [:subtitle, :document] ->
        socket
        |> put_flash(:error, gettext("These subtitles can't be edited here."))
        |> push_navigate(to: video_path(socket, id))

      _ ->
        push_navigate(socket,
          to: DashboardRoutes.videos_path(space, :all, scope: socket.assigns.route_scope)
        )
    end
  end

  @impl true
  def handle_event("select", %{"id" => id}, socket) do
    {:noreply, select(socket, id)}
  end

  def handle_event("show", %{"id" => id}, socket) do
    {:noreply, socket |> select(id) |> push_cue(id, seek: true)}
  end

  def handle_event("edit", %{"id" => id, "text" => text}, socket) when is_binary(text) do
    document = socket.assigns.document

    case SubtitleDocument.cue(document, id) do
      %{text: ^text} ->
        {:noreply, socket}

      %{} ->
        now = System.monotonic_time(:millisecond)

        socket =
          case socket.assigns.last_edit do
            {^id, at} when now - at < @edit_burst_ms -> socket
            _ -> remember(socket)
          end

        {:noreply,
         socket
         |> assign(:last_edit, {id, now})
         |> assign(:redo, [])
         |> put_document(SubtitleDocument.put_text(document, id, text))}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("split", %{"id" => id, "before" => before, "after" => rest}, socket)
      when is_binary(before) and is_binary(rest) do
    {document, new_id} =
      socket.assigns.document
      |> SubtitleDocument.put_text(id, before <> rest)
      |> SubtitleDocument.split(id, String.length(before))

    if new_id do
      {:noreply,
       socket
       |> commit(document)
       |> select(new_id)
       |> push_cue(id, focus: false)
       |> push_cue(new_id, focus: true, offset: 0)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("merge", %{"id" => id, "direction" => direction} = params, socket)
      when direction in ["previous", "next"] do
    document =
      case params do
        %{"text" => text} when is_binary(text) ->
          SubtitleDocument.put_text(socket.assigns.document, id, text)

        _ ->
          socket.assigns.document
      end

    {document, kept_id, offset} =
      if direction == "previous",
        do: SubtitleDocument.merge_with_previous(document, id),
        else: SubtitleDocument.merge_with_next(document, id)

    if kept_id do
      {:noreply,
       socket
       |> commit(document)
       |> select(kept_id)
       |> push_cue(kept_id, focus: true, offset: offset)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("add", params, socket) do
    after_id = params["id"] || socket.assigns.selected_id

    {document, new_id} =
      SubtitleDocument.insert_after(
        socket.assigns.document,
        after_id,
        socket.assigns.video.duration
      )

    {:noreply,
     socket
     |> commit(document)
     |> select(new_id)
     |> push_cue(new_id, focus: true, offset: 0, seek: true)}
  end

  def handle_event("delete", _params, %{assigns: %{selected_id: id}} = socket)
      when is_binary(id) do
    {document, neighbour_id} = SubtitleDocument.delete(socket.assigns.document, id)

    socket = socket |> commit(document) |> assign(:selected_id, neighbour_id)

    {:noreply,
     if(neighbour_id, do: push_cue(socket, neighbour_id, focus: true, offset: 0), else: socket)}
  end

  def handle_event("delete", _params, socket), do: {:noreply, socket}

  def handle_event("retime", %{"id" => id, "start" => start_time, "end" => end_time}, socket)
      when is_number(start_time) and is_number(end_time) do
    {:noreply, socket |> retime(id, start_time, end_time) |> select(id)}
  end

  def handle_event("set_timing", %{"timing" => %{"id" => id} = timing}, socket) do
    with %{} = cue <- SubtitleDocument.cue(socket.assigns.document, id),
         start_time when is_float(start_time) <-
           typed_time(timing["start_minutes"], timing["start_seconds"], cue.start),
         end_time when is_float(end_time) <-
           typed_time(timing["end_minutes"], timing["end_seconds"], cue.end),
         true <- start_time != cue.start or end_time != cue.end do
      {:noreply, retime(socket, id, start_time, end_time)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("undo", _params, socket), do: {:noreply, travel(socket, :undo, :redo)}
  def handle_event("redo", _params, socket), do: {:noreply, travel(socket, :redo, :undo)}

  def handle_event("toggle_original", _params, socket) do
    show? = !socket.assigns.show_original and not is_nil(socket.assigns.original_subtitle)

    original_cues =
      cond do
        not show? ->
          socket.assigns.original_cues

        is_list(socket.assigns.original_cues) ->
          socket.assigns.original_cues

        true ->
          case Assets.read_subtitle_document(
                 socket.assigns.embed,
                 socket.assigns.original_subtitle
               ) do
            {:ok, document} -> document.cues
            _ -> []
          end
      end

    {:noreply,
     socket
     |> assign(:show_original, show?)
     |> assign(:original_cues, original_cues)
     |> assign_original_texts()}
  end

  def handle_event("toggle_pause_while_typing", _params, socket) do
    {:noreply, update(socket, :pause_while_typing, &(!&1))}
  end

  def handle_event("publish", _params, %{assigns: %{dirty: true}} = socket) do
    %{embed: embed, subtitle: subtitle, document: document} = socket.assigns

    case Assets.publish_subtitle_document(embed, subtitle, document) do
      {:ok, subtitle} ->
        {:noreply,
         socket
         |> assign(:subtitle, subtitle)
         |> assign(:published_vtt, SubtitleDocument.to_vtt(document))
         |> assign(:dirty, false)
         |> put_flash(:info, gettext("Subtitles published"))}

      {:error, :empty_subtitle} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Add text to at least one cue before publishing.")
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not publish subtitles"))}
    end
  end

  def handle_event("publish", _params, socket), do: {:noreply, socket}

  def handle_event("discard", _params, socket) do
    case SubtitleDocument.parse(socket.assigns.published_vtt) do
      {:ok, document} ->
        socket = socket |> commit(document) |> assign(:selected_id, nil)
        {:noreply, push_event(socket, "subtitles:reset", %{})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("download", _params, socket) do
    {:noreply,
     push_event(socket, "subtitles:download", %{
       filename: download_filename(socket.assigns.subtitle),
       body: SubtitleDocument.to_vtt(socket.assigns.document)
     })}
  end

  def handle_event("switch", %{"id" => id}, socket) do
    {:noreply, leave(socket, editor_path(socket, id))}
  end

  def handle_event("leave", %{"to" => to}, socket) when is_binary(to) do
    if String.starts_with?(to, "/") and not String.starts_with?(to, "//") do
      {:noreply, leave(socket, to)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("confirm", _params, %{assigns: %{confirm: to}} = socket) when is_binary(to) do
    {:noreply, socket |> assign(:confirm, nil) |> assign(:dirty, false) |> push_navigate(to: to)}
  end

  def handle_event("confirm", _params, socket), do: {:noreply, socket}
  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, :confirm, nil)}

  defp leave(%{assigns: %{dirty: true}} = socket, to), do: assign(socket, :confirm, to)
  defp leave(socket, to), do: push_navigate(socket, to: to)

  defp select(socket, id) do
    if SubtitleDocument.cue(socket.assigns.document, id),
      do: assign(socket, :selected_id, id),
      else: socket
  end

  defp retime(socket, id, start_time, end_time) do
    document =
      SubtitleDocument.put_timing(
        socket.assigns.document,
        id,
        start_time,
        end_time,
        socket.assigns.video.duration
      )

    commit(socket, document)
  end

  defp remember(socket) do
    snapshot = {socket.assigns.document, socket.assigns.selected_id}
    assign(socket, :undo, Enum.take([snapshot | socket.assigns.undo], @history))
  end

  defp commit(socket, %SubtitleDocument{} = document) do
    socket
    |> remember()
    |> assign(:redo, [])
    |> assign(:last_edit, nil)
    |> put_document(document)
  end

  defp travel(socket, from, to) do
    case socket.assigns[from] do
      [{document, selected_id} | rest] ->
        current = {socket.assigns.document, socket.assigns.selected_id}

        socket =
          socket
          |> assign(from, rest)
          |> assign(to, Enum.take([current | socket.assigns[to]], @history))
          |> assign(:last_edit, nil)
          |> assign(:selected_id, selected_id)
          |> put_document(document)

        if selected_id && SubtitleDocument.cue(document, selected_id),
          do: push_cue(socket, selected_id, focus: true),
          else: push_event(socket, "subtitles:reset", %{})

      _ ->
        socket
    end
  end

  defp put_document(socket, %SubtitleDocument{} = document) do
    socket
    |> assign(:document, document)
    |> assign(:issues, SubtitleDocument.issues(document))
    |> assign(:dirty, SubtitleDocument.to_vtt(document) != socket.assigns.published_vtt)
    |> assign_original_texts()
  end

  # Tells the hook which cue to bring into view. The text travels along because
  # LiveView never replaces the value of the field that has focus.
  defp push_cue(socket, id, opts) do
    case SubtitleDocument.cue(socket.assigns.document, id) do
      nil ->
        socket

      cue ->
        offset = Keyword.get(opts, :offset)

        push_event(socket, "subtitles:cue", %{
          id: id,
          text: cue.text,
          offset: offset && utf16_length(String.slice(cue.text, 0, offset)),
          focus: Keyword.get(opts, :focus, false),
          seek: Keyword.get(opts, :seek, false)
        })
    end
  end

  defp utf16_length(text) do
    text |> :unicode.characters_to_binary(:utf8, :utf16) |> byte_size() |> div(2)
  end

  # The fields show hundredths. A field that still shows the current time keeps
  # the exact time instead of its rounded display value.
  defp typed_time(minutes, seconds, current) do
    with {minutes, _} <- Integer.parse(blank_zero(minutes)),
         {seconds, _} <- Float.parse(blank_zero(seconds)),
         true <- minutes >= 0 and seconds >= 0 do
      typed = minutes * 60.0 + seconds
      if abs(typed - Float.round(current, 2)) < 0.0005, do: current, else: typed
    else
      _ -> nil
    end
  end

  defp blank_zero(value) do
    case value |> to_string() |> String.trim() do
      "" -> "0"
      value -> String.replace(value, ",", ".")
    end
  end

  defp original_subtitle(%Embed{asset: %{current_video: %{language: language}}}, subtitle, all)
       when is_binary(language) do
    language = Languages.normalize_media_language(language)

    Enum.find(all, fn candidate ->
      candidate.id != subtitle.id and
        Languages.normalize_media_language(candidate.language) == language
    end)
  end

  defp original_subtitle(_embed, _subtitle, _all), do: nil

  defp assign_original_texts(%{assigns: %{show_original: true, document: document}} = socket) do
    originals = socket.assigns.original_cues || []

    texts =
      Map.new(document.cues, fn cue ->
        text =
          originals
          |> Enum.filter(fn original ->
            middle = (original.start + original.end) / 2
            middle >= cue.start and middle < cue.end
          end)
          |> Enum.map_join(" ", &String.replace(&1.text, "\n", " "))

        {cue.id, text}
      end)

    assign(socket, :original_texts, texts)
  end

  defp assign_original_texts(socket), do: assign(socket, :original_texts, %{})

  defp language_label(%Subtitle{language: language}) do
    Languages.spoken_language(language) || String.upcase(language || "")
  end

  defp download_filename(%Subtitle{language: language}) do
    case String.replace(String.trim(language || ""), ~r/[^A-Za-z0-9_-]/, "_") do
      "" -> "subtitle.vtt"
      name -> "#{name}.vtt"
    end
  end

  defp video_path(socket, id) do
    DashboardRoutes.video_path(socket.assigns.current_space, id, :all,
      scope: socket.assigns.route_scope
    )
  end

  defp editor_path(socket, subtitle_id) do
    DashboardRoutes.subtitle_editor_path(
      socket.assigns.current_space,
      socket.assigns.video.id,
      subtitle_id,
      scope: socket.assigns.route_scope
    )
  end

  @impl true
  def render(%{loaded: false} = assigns) do
    ~H"""
    <div class="h-full"></div>
    """
  end

  def render(assigns) do
    selected = SubtitleDocument.cue(assigns.document, assigns.selected_id)

    assigns =
      assigns
      |> assign(:selected, selected)
      |> assign(
        :selected_number,
        selected && Enum.find_index(assigns.document.cues, &(&1.id == selected.id)) + 1
      )
      |> assign(
        :flagged,
        Enum.filter(assigns.document.cues, &Map.has_key?(assigns.issues, &1.id))
      )
      |> assign(
        :numbers,
        assigns.document.cues |> Enum.with_index(1) |> Map.new(fn {cue, n} -> {cue.id, n} end)
      )
      |> assign(:last_id, assigns.document.cues |> List.last() |> then(&(&1 && &1.id)))

    ~H"""
    <div
      id="subtitle-editor"
      phx-hook="subtitle_editor"
      data-duration={@video.duration}
      data-dirty={to_string(@dirty)}
      data-pause-while-typing={to_string(@pause_while_typing)}
      class="h-full flex flex-col mr-56"
    >
      <.title title={gettext("Subtitles")}>
        <div class="flex items-center gap-4">
          <div
            id="subtitle-languages"
            class="flex items-center rounded-full bg-stone-100 ring-1 ring-inset ring-stone-200 overflow-hidden text-sm"
          >
            <button
              :for={track <- @subtitles}
              id={"subtitle-language-#{track.id}"}
              type="button"
              phx-click={track.id != @subtitle.id && "switch"}
              phx-value-id={track.id}
              class={[
                "px-3 py-1.5 transition-colors",
                track.id == @subtitle.id && "bg-white text-blue-500 shadow-sm cursor-default",
                track.id != @subtitle.id && "text-stone-400 cursor-pointer hover:text-stone-500"
              ]}
            >
              {track.label}
            </button>
          </div>

          <.dropdown_button id="subtitle-actions" menu_class="w-44">
            <:item id="subtitle-download" icon="render" phx-click="download">
              {gettext("download")}
            </:item>
            <:item id="subtitle-discard" icon="delete" danger disabled={!@dirty} phx-click="discard">
              {gettext("discard changes")}
            </:item>
          </.dropdown_button>
        </div>
      </.title>

      <.breadcrumb_bar>
        <:item
          navigate={DashboardRoutes.videos_path(@current_space, :all, scope: @route_scope)}
          label={gettext("Videos")}
        />
        <:item
          navigate={DashboardRoutes.video_path(@current_space, @video.id, :all, scope: @route_scope)}
          label={@video.name || gettext("Untitled")}
        />
        <:item label={gettext("Subtitles")} />
      </.breadcrumb_bar>

      <div class="flex-1 min-h-0 overflow-hidden">
        <div class="max-w-screen-xl mx-auto px-16 pt-12 pb-6 h-full">
          <div class="w-full h-full bg-stone-900 flex">
            <div class="w-[29rem] flex-none flex flex-col min-h-0 select-none">
              <div
                id="subtitle-player"
                phx-update="ignore"
                data-sources={Jason.encode!(@video.sources)}
                class="relative aspect-video flex-none bg-black overflow-hidden"
              >
                <video
                  playsinline
                  preload="metadata"
                  poster={@video.poster}
                  class="absolute inset-0 w-full h-full object-contain"
                ></video>
                <div
                  data-caption
                  class="pointer-events-none absolute inset-x-0 bottom-4 px-6 text-center text-white text-[0.9rem] leading-[1.5rem] font-medium"
                >
                </div>
              </div>

              <div
                id="subtitle-transport"
                phx-update="ignore"
                class="h-11 flex-none flex items-center px-3.5 gap-3"
              >
                <button
                  type="button"
                  data-play
                  aria-label={gettext("Play or pause")}
                  class="text-stone-300 flex items-center cursor-pointer outline-none hover:text-white focus-visible:text-white"
                >
                  <.icon name="hero-play-solid" class="w-4 h-4 [[data-playing]_&]:hidden" />
                  <.icon name="hero-pause-solid" class="w-4 h-4 hidden [[data-playing]_&]:block" />
                </button>
                <div class="font-mono text-xs text-stone-400 tabular-nums">
                  <span data-clock>0:00.0</span><span class="text-stone-600"> / {clock(
                    @video.duration
                  )}</span>
                </div>
                <div data-seek class="flex-grow h-6 flex items-center cursor-pointer">
                  <div class="w-full h-0.5 rounded-full bg-black/40">
                    <div data-progress class="h-full w-0 bg-blue-600 rounded-full"></div>
                  </div>
                </div>
                <button
                  type="button"
                  data-rate
                  aria-label={gettext("Playback speed")}
                  class="h-6 px-2 bg-stone-800 rounded-sm text-sm text-stone-400 flex items-center cursor-pointer outline-none hover:text-stone-300 tabular-nums"
                >
                  <span data-rate-value>1</span><span class="text-xs text-stone-500 ml-0.5">×</span>
                </button>
              </div>

              <div class="w-full h-8 px-3 border-y border-stone-800 font-semibold flex items-center text-xs uppercase text-stone-500 cursor-default">
                <div class="flex-grow pb-0.5">{gettext("timeline")}</div>
                <button
                  :for={
                    {zoom, label, path} <- [
                      {"out", gettext("Zoom out"), "M19.5 12h-15"},
                      {"in", gettext("Zoom in"), "M12 4.5v15m7.5-7.5h-15"}
                    ]
                  }
                  id={"subtitle-zoom-#{zoom}"}
                  type="button"
                  data-zoom={zoom}
                  aria-label={label}
                  class="h-[1.125rem] w-[1.125rem] bg-stone-800 mx-[0.1875rem] rounded-full flex items-center justify-center cursor-pointer hover:bg-stone-700 outline-none"
                >
                  <svg
                    xmlns="http://www.w3.org/2000/svg"
                    fill="none"
                    viewBox="0 0 24 24"
                    stroke-width="2"
                    stroke="currentColor"
                    class="w-4 h-4 border-transparent border-b-[0.5px]"
                  >
                    <path stroke-linecap="round" stroke-linejoin="round" d={path} />
                  </svg>
                </button>
              </div>

              <div id="subtitle-timeline" phx-update="ignore" class="flex-none px-3 pt-3 pb-2.5">
                <div data-strip class="relative h-12 w-full cursor-pointer">
                  <div class="flex h-full w-full overflow-hidden rounded-sm bg-stone-800">
                    <div
                      :for={frame <- @video.frames}
                      class="h-full flex-1 bg-center bg-cover bg-no-repeat"
                      style={"background-image: url(#{frame.src})"}
                    >
                    </div>
                  </div>
                  <div class="pointer-events-none absolute inset-0 rounded-sm ring-1 ring-inset ring-white/10">
                  </div>
                  <div
                    data-window
                    class="pointer-events-none absolute top-0 left-0 h-full rounded-sm border border-white shadow shadow-black"
                  >
                  </div>
                </div>
                <div
                  data-lane
                  class="relative mt-1.5 h-7 w-full overflow-hidden rounded-sm bg-black/20"
                >
                </div>
                <div data-ruler class="relative h-4 w-full mt-1"></div>
              </div>

              <.settings_header title={gettext("checks")} />
              <div
                id="subtitle-checks"
                class="flex-1 min-h-0 overflow-y-auto py-1.5 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
              >
                <div
                  :for={cue <- @flagged}
                  id={"subtitle-check-#{cue.id}"}
                  phx-click="show"
                  phx-value-id={cue.id}
                  class="flex items-center pl-3.5 pr-2 py-1.5 cursor-pointer hover:bg-stone-800/60"
                >
                  <.led tone={:warn} />
                  <div class="w-full text-sm text-stone-500 mb-0.5 h-[1.225rem] truncate">
                    {gettext("Cue")} {@numbers[cue.id]} <span class="text-stone-600">·</span>
                    {issue_label(hd(@issues[cue.id]))}
                  </div>
                  <.badge tone={:warn}>{issue_badge(hd(@issues[cue.id]))}</.badge>
                </div>
                <div
                  :if={length(@document.cues) > length(@flagged)}
                  id="subtitle-checks-ok"
                  class="flex items-center pl-3.5 pr-2 py-1.5"
                >
                  <.led tone={:ok} />
                  <div class="w-full text-sm text-stone-500 mb-0.5 h-[1.225rem]">
                    {ok_label(length(@document.cues) - length(@flagged), @flagged != [])}
                  </div>
                  <.badge>OK</.badge>
                </div>
              </div>
            </div>

            <div
              id="subtitle-cues"
              class="flex-1 min-w-0 border-l border-stone-800 overflow-y-auto py-2 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
            >
              <.cue
                :for={cue <- @document.cues}
                :key={cue.id}
                cue={cue}
                number={@numbers[cue.id]}
                selected={cue.id == @selected_id}
                issue={List.first(@issues[cue.id] || [])}
                original={@show_original && Map.get(@original_texts, cue.id, "")}
                last={cue.id == @last_id}
              />
              <div
                :if={@document.cues == []}
                id="subtitle-cues-empty"
                class="px-5 py-3 text-sm text-stone-500"
              >
                <button
                  type="button"
                  phx-click="add"
                  class="cursor-pointer text-stone-400 hover:text-stone-200"
                >
                  {gettext("Add the first cue")}
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>

      <.settings_panel id="subtitle-panel" class="fixed top-0 right-0 h-screen z-50">
        <.settings_header title={
          if @selected, do: "#{gettext("cue")} #{@selected_number}", else: gettext("cue")
        } />
        <div :if={!@selected} class="p-3 text-sm text-stone-500">
          {gettext("Select a line to set its timing.")}
        </div>
        <form
          :if={@selected}
          id="subtitle-timing-form"
          phx-change="set_timing"
          phx-submit="set_timing"
          class="p-3 space-y-3"
        >
          <input type="hidden" name="timing[id]" value={@selected.id} />
          <div
            :for={
              {label, field, value} <- [
                {gettext("in"), "start", @selected.start},
                {gettext("out"), "end", @selected.end}
              ]
            }
            class="flex gap-[1px]"
          >
            <div class="w-9 flex-none bg-stone-800 rounded-sm text-xs text-stone-500 flex items-center justify-center">
              {label}
            </div>
            <.time_field
              id={"subtitle-timing-#{field}-minutes"}
              name={"timing[#{field}_minutes]"}
              value={minutes(value)}
              label="M"
              step="1"
            />
            <.time_field
              id={"subtitle-timing-#{field}-seconds"}
              name={"timing[#{field}_seconds]"}
              value={seconds(value)}
              label="S"
              step="0.01"
              wide
            />
          </div>
        </form>

        <.settings_header :if={@selected} title={gettext("reading")} />
        <div :if={@selected} id="subtitle-reading" class="px-3 py-1.5">
          <% reading = SubtitleDocument.reading(@selected) %>
          <.meter
            :for={{count, index} <- Enum.with_index(reading.lines, 1)}
            label={"#{gettext("line")} #{index}"}
            value={count}
            max={SubtitleDocument.max_line_length()}
          />
          <.meter
            label={gettext("speed")}
            value={reading.speed}
            max={SubtitleDocument.max_reading_speed()}
            unit={" " <> gettext("per second")}
          />
        </div>

        <.settings_header title={gettext("edit")} />
        <.settings_option_grid class={!@selected && "opacity-50 pointer-events-none"}>
          <.settings_option
            id="subtitle-split"
            label={gettext("split")}
            value={:split}
            data-action="split"
            data-keep-focus
          >
            <.icon name="hero-scissors" class="w-5 h-5 text-stone-500 mt-1" />
          </.settings_option>
          <.settings_option
            id="subtitle-merge"
            label={gettext("merge")}
            value={:merge}
            disabled={is_nil(@selected) or @selected.id == @last_id}
            phx-click={JS.push("merge", value: %{id: @selected_id, direction: "next"})}
            data-keep-focus
          >
            <.icon name="hero-arrows-pointing-in" class="w-5 h-5 text-stone-500 mt-1" />
          </.settings_option>
          <.settings_option id="subtitle-add" label={gettext("add")} value={:add} phx-click="add">
            <.icon name="hero-plus" class="w-5 h-5 text-stone-500 mt-1" />
          </.settings_option>
          <.settings_option
            id="subtitle-delete"
            label={gettext("delete")}
            value={:delete}
            phx-click="delete"
          >
            <.icon name="hero-trash" class="w-5 h-5 text-red-400/80 mt-1" />
          </.settings_option>
        </.settings_option_grid>

        <.settings_header
          :if={@original_subtitle}
          title={gettext("show original")}
          toggable
          toggle_enabled={@show_original}
          phx-click="toggle_original"
        />
        <.settings_header
          title={gettext("pause while typing")}
          toggable
          toggle_enabled={@pause_while_typing}
          phx-click="toggle_pause_while_typing"
        />

        <.settings_header title={gettext("keys")} />
        <div class="py-1.5">
          <div
            :for={
              {label, key} <- [
                {gettext("Split"), "enter"},
                {gettext("New line"), "shift enter"},
                {gettext("Merge"), "backspace"},
                {gettext("Undo"), "ctrl z"}
              ]
            }
            class="flex items-center pl-3 pr-2 py-1.5"
          >
            <div class="w-full text-sm text-stone-500 mb-0.5 h-[1.225rem]">{label}</div>
            <.badge>{key}</.badge>
          </div>
        </div>

        <:footer>
          <div
            id="subtitle-publish"
            phx-click="publish"
            class={[
              "w-full h-[calc(4rem+1px)] p-3 border-t border-stone-700/40 bg-stone-900",
              !@dirty && "hidden"
            ]}
          >
            <div class="w-full h-full bg-blue-600 hover:ring-1 ring-inset hover:ring-blue-500 active:bg-blue-700 rounded-sm flex items-center justify-center text-white pb-0.5 text-sm select-none cursor-pointer">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                fill="none"
                viewBox="0 0 24 24"
                stroke-width="1"
                stroke="currentColor"
                class="w-5 h-5 ml-2 mt-0.5 opacity-70"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M12 19.5v-15m0 0l-6.75 6.75M12 4.5l6.75 6.75"
                />
              </svg>
              <div class="flex-grow text-center mr-7">{gettext("publish")}</div>
            </div>
          </div>
        </:footer>
      </.settings_panel>

      <.dialog
        id="subtitle-leave-dialog"
        show={not is_nil(@confirm)}
        on_confirm={JS.push("confirm")}
        on_cancel={JS.push("cancel")}
      >
        {gettext("Leave without publishing? Your changes to these subtitles will be lost.")}
      </.dialog>

      <.footer extra_padding />
    </div>
    """
  end

  attr :cue, :map, required: true
  attr :number, :integer, required: true
  attr :selected, :boolean, default: false
  attr :issue, :any, default: nil
  attr :original, :any, default: false
  attr :last, :boolean, default: false

  defp cue(assigns) do
    ~H"""
    <div
      id={"subtitle-cue-#{@cue.id}"}
      data-cue={@cue.id}
      data-start={@cue.start}
      data-end={@cue.end}
      data-warn={to_string(not is_nil(@issue))}
      data-selected={to_string(@selected)}
      class="group relative px-2"
    >
      <div
        data-cue-dot
        class="pointer-events-none absolute left-[0.15rem] top-[1.05rem] h-1 w-1 rounded-full bg-blue-500 opacity-0"
      >
      </div>
      <div class={[
        "flex items-start rounded-sm py-2 pr-1.5 ring-1 ring-inset cursor-text",
        @selected && "bg-stone-800 ring-blue-600",
        !@selected && "ring-transparent"
      ]}>
        <div
          data-cue-number
          class={[
            "flex-none w-9 pr-3 text-right font-mono text-[84%] leading-5 select-none",
            if(@selected, do: "text-blue-500", else: "text-stone-600")
          ]}
        >
          {@number}
        </div>
        <div class="flex-1 min-w-0">
          <textarea
            id={"subtitle-cue-text-#{@cue.id}"}
            data-cue-text
            rows={@cue.text |> String.split("\n") |> length()}
            spellcheck="true"
            aria-label={"#{gettext("Cue")} #{@number}"}
            class={[
              "block w-full resize-none overflow-hidden border-0 bg-transparent p-0 text-sm leading-5 outline-none focus:ring-0 [field-sizing:content]",
              if(@selected, do: "text-stone-200", else: "text-stone-400")
            ]}
          >{Phoenix.HTML.Form.normalize_value("textarea", @cue.text)}</textarea>
          <div
            :if={@original}
            class="mt-1 text-[0.8rem] leading-[1.15rem] text-stone-600 select-none"
          >
            {@original}
          </div>
        </div>
        <div class="flex-none pl-2 flex items-center h-5 select-none">
          <.badge :if={@issue} tone={:warn}>{issue_badge(@issue)}</.badge>
          <div :if={!@issue} class="font-mono text-[0.7rem] text-stone-600 tabular-nums mr-1">
            {clock(@cue.start)}
          </div>
        </div>
      </div>
      <div class={[
        "absolute z-10 left-11 -bottom-[0.6rem] items-center gap-1.5",
        if(@selected, do: "flex", else: "hidden group-hover:flex")
      ]}>
        <button
          type="button"
          id={"subtitle-cue-add-#{@cue.id}"}
          tabindex="-1"
          phx-click="add"
          phx-value-id={@cue.id}
          title={gettext("add a cue here")}
          class="h-[1.125rem] w-[1.125rem] bg-stone-700 rounded-full flex items-center justify-center text-stone-300 ring-2 ring-stone-900 cursor-pointer hover:bg-stone-600 outline-none"
        >
          <.icon name="hero-plus" class="w-3 h-3" />
        </button>
        <button
          :if={!@last}
          type="button"
          id={"subtitle-cue-merge-#{@cue.id}"}
          tabindex="-1"
          phx-click={JS.push("merge", value: %{id: @cue.id, direction: "next"})}
          title={gettext("merge these cues")}
          class="h-[1.125rem] w-[1.125rem] bg-stone-800 rounded-full flex items-center justify-center text-stone-500 ring-2 ring-stone-900 cursor-pointer hover:bg-stone-700 hover:text-stone-300 outline-none"
        >
          <.icon name="hero-arrows-pointing-in" class="w-3 h-3" />
        </button>
      </div>
    </div>
    """
  end

  attr :tone, :atom, default: :ok

  defp led(assigns) do
    ~H"""
    <div class={[
      "w-2 h-2 rounded-full bg-gradient-to-b mr-2.5 flex-none",
      @tone == :ok && "from-green-400 to-green-600",
      @tone == :warn && "from-amber-300 to-amber-500"
    ]}>
    </div>
    """
  end

  attr :tone, :atom, default: :plain
  slot :inner_block, required: true

  defp badge(assigns) do
    ~H"""
    <div class={[
      "min-w-10 flex-none text-center whitespace-nowrap rounded text-xs ring-1 ring-inset shadow px-1 pt-[0.02rem] pb-[0.09rem] mr-1 tabular-nums",
      @tone == :plain && "text-stone-600/80 ring-stone-700/50",
      @tone == :warn && "text-amber-500/80 ring-amber-500/30"
    ]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, required: true
  attr :step, :string, required: true
  attr :wide, :boolean, default: false

  defp time_field(assigns) do
    ~H"""
    <div class={["relative", if(@wide, do: "flex-grow", else: "w-12 flex-none")]}>
      <input
        id={@id}
        type="number"
        min="0"
        step={@step}
        name={@name}
        value={@value}
        phx-debounce="blur"
        class="w-full h-6 bg-stone-800 px-2 py-0.5 text-sm text-stone-400 outline-none focus:ring-blue-600 ring-1 rounded-sm ring-transparent tabular-nums [appearance:textfield] [&::-webkit-inner-spin-button]:appearance-none"
        placeholder="0"
      />
      <div class="absolute h-full flex items-center right-1 top-0 text-xs text-stone-500 px-1">
        {@label}
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :max, :integer, required: true
  attr :unit, :string, default: ""

  defp meter(assigns) do
    scale = max(max(assigns.value, assigns.max), 1)

    assigns =
      assigns
      |> assign(:over, assigns.value > assigns.max)
      |> assign(:within, Float.round(min(assigns.value, assigns.max) / scale * 100, 1))
      |> assign(:excess, Float.round(max(assigns.value - assigns.max, 0) / scale * 100, 1))

    ~H"""
    <div class="py-1.5">
      <div class="flex items-center text-xs text-stone-500">
        <div class="flex-grow">{@label}</div>
        <div class="tabular-nums">
          <span class={@over && "text-amber-500"}>{@value}</span>
          <span class="text-stone-600">/ {@max}{@unit}</span>
        </div>
      </div>
      <div class="flex w-full h-0.5 overflow-hidden rounded-full bg-black/40 mt-2.5 mb-1">
        <div class="h-full bg-blue-600" style={"width: #{@within}%"}></div>
        <div :if={@over} class="h-full bg-amber-500" style={"width: #{@excess}%"}></div>
      </div>
    </div>
    """
  end

  defp issue_label(:empty), do: gettext("no text")
  defp issue_label({:line_length, _}), do: gettext("line too long")
  defp issue_label({:lines, _}), do: gettext("too many lines")
  defp issue_label({:reading_speed, _}), do: gettext("reads too fast")
  defp issue_label(:overlap), do: gettext("overlaps previous cue")

  defp issue_badge(:empty), do: gettext("empty")
  defp issue_badge({:line_length, count}), do: "#{count}/#{SubtitleDocument.max_line_length()}"
  defp issue_badge({:lines, count}), do: "#{count}/#{SubtitleDocument.max_lines()}"
  defp issue_badge({:reading_speed, speed}), do: "#{speed}/s"
  defp issue_badge(:overlap), do: gettext("overlap")

  defp ok_label(count, true),
    do: ngettext("%{count} other cue", "%{count} other cues", count, count: count)

  defp ok_label(count, false), do: ngettext("%{count} cue", "%{count} cues", count, count: count)

  defp clock(seconds) when is_number(seconds) do
    tenths = round(seconds * 10)
    minutes = div(tenths, 600)
    rest = rem(tenths, 600)

    "#{minutes}:#{String.pad_leading(to_string(div(rest, 10)), 2, "0")}.#{rem(rest, 10)}"
  end

  defp clock(_seconds), do: "0:00.0"

  defp minutes(seconds), do: to_string(div(round(seconds * 1000), 60_000))

  defp seconds(seconds) do
    millis = rem(round(seconds * 1000), 60_000)
    :erlang.float_to_binary(millis / 1000, decimals: 2)
  end
end
