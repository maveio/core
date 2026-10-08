defmodule MaveCoreWeb.Dashboard.Videos.VideoSettingsComponent do
  @moduledoc false

  use MaveCoreWeb, :live_component

  import MaveCoreWeb.DashboardComponents.Settings
  import MaveCoreWeb.DashboardComponents.States, only: [progress_bar: 1]

  alias MaveCore.Assets
  alias MaveCore.Embeds
  alias MaveCore.Embeds.Embed
  alias MaveCore.Embeds.SettingsSerializer
  alias MaveCore.Flow.Definition
  alias MaveCore.Languages
  alias MaveCore.Spaces
  alias MaveCore.Spaces.Space
  alias MaveCore.Uploads.Token
  alias MaveCoreWeb.DashboardRoutes
  alias MaveCoreWeb.Plugs.Maintenance
  alias Phoenix.LiveView.JS

  @show_flow_info false
  @hls_packaging_phase_start_progress 85

  @impl true
  def update(assigns, socket) do
    same_embed? = match?(%{id: id} when id == assigns.embed.id, socket.assigns[:embed])
    incoming_settings = Map.get(assigns, :persisted_settings, %{})

    incoming_settings =
      if same_embed? and (assigns[:uploading_poster] || socket.assigns[:uploading_poster]) do
        Map.put(incoming_settings, :poster, :upload)
      else
        incoming_settings
      end

    socket =
      socket
      |> maybe_allow_poster_upload()
      |> maybe_allow_audio_track_upload()
      |> maybe_allow_subtitle_upload()
      |> assign(assigns)
      |> MaveCoreWeb.SpaceLiveAuth.attach_component()
      |> assign_new(:current_tab, fn -> :options end)
      |> assign_new(:settings, fn -> incoming_settings end)
      |> assign_new(:persisted_settings, fn -> incoming_settings end)
      |> assign_new(:has_changes, fn -> false end)
      |> assign_new(:uploading_poster, fn -> false end)
      |> assign(:show_flow_info, @show_flow_info)
      |> assign_new(:show_flow_details, fn -> false end)
      |> assign_new(:audio_track_form, fn -> nil end)
      |> assign_new(:subtitle_form, fn -> nil end)

    socket =
      cond do
        not same_embed? ->
          socket
          |> assign(:settings, incoming_settings)
          |> assign(:persisted_settings, incoming_settings)
          |> assign(:has_changes, false)
          |> assign(:uploading_poster, false)
          |> assign(:show_flow_details, false)
          |> assign(:audio_track_form, nil)
          |> assign(:subtitle_form, nil)

        socket.assigns.has_changes ->
          assign(socket, :persisted_settings, incoming_settings)

        true ->
          socket
          |> assign(:settings, incoming_settings)
          |> assign(:persisted_settings, incoming_settings)
          |> assign(:has_changes, false)
          |> assign(:audio_track_form, nil)
          |> assign(:subtitle_form, nil)
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("change_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :current_tab, String.to_existing_atom(tab))}
  end

  def handle_event("toggle_flow_details", _params, socket) do
    {:noreply, update(socket, :show_flow_details, &(!&1))}
  end

  def handle_event(
        "retry_flow_step",
        %{"flow_run_id" => flow_run_id, "step_id" => step_id},
        socket
      ) do
    notify_parent({:retry_flow_step, flow_run_id, step_id})
    {:noreply, socket}
  end

  def handle_event("toggle", %{"title" => title}, socket) do
    field = String.to_existing_atom("#{title}_enabled")
    settings = Map.update!(socket.assigns.settings, field, &(!&1))
    {:noreply, push_settings(socket, settings)}
  end

  def handle_event("select_option", %{"title" => title, "label" => label}, socket) do
    field = String.to_existing_atom(title)
    value = String.to_existing_atom(label)
    settings = Map.put(socket.assigns.settings, field, value)
    {:noreply, push_settings(socket, settings)}
  end

  def handle_event("change_color", %{"color" => "transparent"}, socket) do
    settings =
      socket.assigns.settings
      |> Map.put(:color, nil)
      |> Map.put(:opacity, 100)

    {:noreply, push_settings(socket, settings)}
  end

  def handle_event("change_color", %{"color" => color}, socket) do
    settings =
      socket.assigns.settings
      |> Map.put(:color, String.trim_leading(color || "", "#"))
      |> Map.put_new(:opacity, 100)

    {:noreply, push_settings(socket, settings)}
  end

  def handle_event("change_settings", %{"settings" => params}, socket) do
    settings =
      socket.assigns.settings
      |> maybe_put_string(:width, params["width"])
      |> maybe_put_string(:height, params["height"])
      |> maybe_put_string(:color, normalize_color(params["color"]))
      |> maybe_put_integer(:opacity, params["opacity"])
      |> maybe_put_integer(:poster_time_hour, params["poster_time_hour"])
      |> maybe_put_integer(:poster_time_minute, params["poster_time_minute"])
      |> maybe_put_float(:poster_time_second, params["poster_time_second"])
      |> normalize_poster_time()

    {:noreply, push_settings(socket, settings)}
  end

  def handle_event("delete_external_poster", _params, socket) do
    case Embeds.delete_external_poster(socket.assigns.embed) do
      {:ok, embed} ->
        settings =
          socket.assigns.settings
          |> Map.put(:external_poster, nil)
          |> Map.put(:poster, :upload)

        notify_parent({:settings_published, embed})

        {:noreply,
         socket
         |> assign(:settings, settings)
         |> assign(:persisted_settings, settings)
         |> assign(:has_changes, false)
         |> assign(:uploading_poster, false)}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  def handle_event("publish", _params, socket) do
    case Embeds.publish_settings(socket.assigns.embed, socket.assigns.settings) do
      {:ok, embed} ->
        notify_parent({:settings_published, embed})

        {:noreply,
         socket
         |> assign(:persisted_settings, socket.assigns.settings)
         |> assign(:has_changes, false)
         |> assign(:uploading_poster, false)}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  def handle_event("add_audio_track", _params, socket) do
    {:noreply,
     assign(socket, :audio_track_form, %{
       mode: :new,
       audio_track_id: nil,
       label: gettext("Audio track"),
       language: ""
     })}
  end

  def handle_event("replace_audio_track", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.video.audio_tracks || [], &("#{&1.id}" == id)) do
      nil ->
        {:noreply, socket}

      track ->
        {:noreply,
         assign(socket, :audio_track_form, %{
           mode: :replace,
           audio_track_id: track.id,
           label: track.label || gettext("Audio track"),
           language: track.language || "",
           picker_ref: System.unique_integer([:positive])
         })}
    end
  end

  def handle_event("cancel_audio_track", _params, socket) do
    {:noreply, assign(socket, :audio_track_form, nil)}
  end

  def handle_event("change_new_audio_track", %{"audio_track" => params}, socket) do
    {:noreply,
     assign(socket, :audio_track_form, %{
       mode: Map.get(socket.assigns.audio_track_form || %{}, :mode, :new),
       audio_track_id: Map.get(socket.assigns.audio_track_form || %{}, :audio_track_id),
       label: Map.get(params, "label", ""),
       language: Map.get(params, "language", "")
     })}
  end

  def handle_event("change_audio_track", %{"audio_track" => %{"id" => id} = params}, socket) do
    case scoped_audio_track(socket, id) do
      nil ->
        {:noreply, socket}

      track ->
        case Assets.update_audio_track(track, %{
               label: blank_to_nil(Map.get(params, "label")),
               language: blank_to_nil(Map.get(params, "language"))
             }) do
          {:ok, _track} ->
            refresh_audio_outputs(socket)

          {:error, _reason} ->
            {:noreply, socket}
        end
    end
  end

  def handle_event("blur_audio_track_label", %{"id" => id, "value" => label}, socket) do
    handle_event(
      "blur_audio_track_label",
      %{"id" => id, "audio_track" => %{"label" => label}},
      socket
    )
  end

  def handle_event("blur_audio_track_label", %{"id" => id, "audio_track" => params}, socket) do
    update_audio_track_if_changed(socket, id, :label, blank_to_nil(Map.get(params, "label")))
  end

  def handle_event("change_audio_track_language", %{"id" => id, "value" => language}, socket) do
    handle_event(
      "change_audio_track_language",
      %{"id" => id, "audio_track" => %{"language" => language}},
      socket
    )
  end

  def handle_event("change_audio_track_language", %{"id" => id, "audio_track" => params}, socket) do
    update_audio_track_if_changed(
      socket,
      id,
      :language,
      blank_to_nil(Map.get(params, "language"))
    )
  end

  def handle_event("delete_audio_track", %{"id" => id}, socket) do
    case scoped_audio_track(socket, id) do
      %{} = track ->
        case Assets.delete_audio_track(track) do
          {:ok, _track} ->
            refresh_audio_outputs(socket)

          {:error, _reason} ->
            {:noreply, socket}
        end

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("add_subtitle", _params, socket) do
    {:noreply,
     assign(socket, :subtitle_form, %{
       mode: :new,
       subtitle_id: nil,
       language: ""
     })}
  end

  def handle_event("replace_subtitle", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.video.subtitles || [], &("#{&1.id}" == id)) do
      nil ->
        {:noreply, socket}

      subtitle ->
        {:noreply,
         assign(socket, :subtitle_form, %{
           mode: :replace,
           subtitle_id: subtitle.id,
           language: subtitle.language || "",
           picker_ref: System.unique_integer([:positive])
         })}
    end
  end

  def handle_event("cancel_subtitle", _params, socket) do
    {:noreply, assign(socket, :subtitle_form, nil)}
  end

  def handle_event("change_new_subtitle", %{"subtitle" => params}, socket) do
    {:noreply,
     assign(socket, :subtitle_form, %{
       mode: Map.get(socket.assigns.subtitle_form || %{}, :mode, :new),
       subtitle_id: Map.get(socket.assigns.subtitle_form || %{}, :subtitle_id),
       language: Map.get(params, "language", "")
     })}
  end

  def handle_event("change_subtitle", %{"subtitle" => %{"id" => id} = params}, socket) do
    case scoped_subtitle(socket, id) do
      nil ->
        {:noreply, socket}

      subtitle ->
        case Assets.update_subtitle_outputs(socket.assigns.embed, subtitle, %{
               language: blank_to_nil(Map.get(params, "language"))
             }) do
          {:ok, _subtitle} ->
            notify_parent(:subtitles_updated)
            {:noreply, socket}

          {:error, _reason} ->
            {:noreply, socket}
        end
    end
  end

  def handle_event("delete_subtitle", %{"id" => id}, socket) do
    case scoped_subtitle(socket, id) do
      nil ->
        {:noreply, socket}

      subtitle ->
        case Assets.delete_subtitle_outputs(socket.assigns.embed, subtitle) do
          {:ok, _subtitle} ->
            notify_parent(:subtitles_updated)
            {:noreply, socket}

          {:error, _reason} ->
            {:noreply, socket}
        end
    end
  end

  @impl true
  def handle_event("noop", _params, socket), do: {:noreply, socket}

  def handle_progress(:poster_image, entry, socket) do
    socket =
      if entry.done? do
        consume_uploaded_entries(socket, :poster_image, fn _meta, _entry -> {:ok, :uploaded} end)

        socket
        |> assign(:uploading_poster, true)
        |> assign(:has_changes, false)
      else
        socket
      end

    if entry.done? do
      notify_parent(:poster_uploaded)
    end

    {:noreply, socket}
  end

  def handle_progress(:audio_track_file, entry, socket) do
    pending_track = pending_audio_track_upload(socket)

    socket =
      if entry.done? do
        consume_uploaded_entries(socket, :audio_track_file, fn _meta, _entry ->
          {:ok, :uploaded}
        end)

        socket
        |> assign(:audio_track_form, nil)
      else
        socket
      end

    if entry.done? do
      notify_parent({:audio_track_uploaded, pending_track})
    end

    {:noreply, socket}
  end

  def handle_progress(:subtitle_file, entry, socket) do
    pending_subtitle = pending_subtitle_upload(socket)

    socket =
      if entry.done? do
        consume_uploaded_entries(socket, :subtitle_file, fn _meta, _entry -> {:ok, :uploaded} end)

        socket
        |> assign(:subtitle_form, nil)
      else
        socket
      end

    if entry.done? do
      notify_parent({:subtitle_uploaded, pending_subtitle})
    end

    {:noreply, socket}
  end

  def presign_upload(_entry, socket) do
    notify_parent(:poster_upload_started)

    options = %{
      uploader: "cdn",
      custom_thumbnail: true,
      token:
        upload_token(
          socket.assigns.current_space,
          socket.assigns.embed,
          socket.assigns.current_user,
          socket.assigns[:space_access_context]
        ),
      entrypoint:
        :mave_core
        |> Application.get_env(:upload, [])
        |> Keyword.get(:endpoint, "http://localhost:1080/files")
    }

    {:ok, options, socket}
  end

  def presign_audio_track_upload(_entry, socket) do
    form = socket.assigns.audio_track_form || %{}

    options = %{
      uploader: "cdn",
      custom_audio_track: true,
      audio_track_id: Map.get(form, :audio_track_id),
      label: blank_to_nil(Map.get(form, :label)),
      language: blank_to_nil(Map.get(form, :language)),
      token:
        upload_token(
          socket.assigns.current_space,
          socket.assigns.embed,
          socket.assigns.current_user,
          socket.assigns[:space_access_context]
        ),
      entrypoint:
        :mave_core
        |> Application.get_env(:upload, [])
        |> Keyword.get(:endpoint, "http://localhost:1080/files")
    }

    {:ok, options, socket}
  end

  def presign_subtitle_upload(_entry, socket) do
    form = socket.assigns.subtitle_form || %{}

    options = %{
      uploader: "cdn",
      custom_subtitle: true,
      subtitle_id: Map.get(form, :subtitle_id),
      language: blank_to_nil(Map.get(form, :language)),
      token:
        upload_token(
          socket.assigns.current_space,
          socket.assigns.embed,
          socket.assigns.current_user,
          socket.assigns[:space_access_context]
        ),
      entrypoint:
        :mave_core
        |> Application.get_env(:upload, [])
        |> Keyword.get(:endpoint, "http://localhost:1080/files")
    }

    {:ok, options, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <.settings_panel class="fixed top-0 right-0 h-screen z-50">
        <div
          id="video-settings-tab-content"
          class="relative min-h-full phx-click-loading:cursor-wait"
        >
          <div class="phx-click-loading:opacity-25 phx-click-loading:saturate-0 transition-opacity duration-150">
            <.info_tab
              :if={@current_tab == :info}
              video={@video}
              show_flow_info={@show_flow_info}
              show_flow_details={@show_flow_details}
              myself={@myself}
            />

            <.options_tab
              :if={@current_tab == :options}
              settings={@settings}
              video={@video}
              uploads={@uploads}
              uploading_poster={@uploading_poster}
              audio_track_form={@audio_track_form}
              subtitle_form={@subtitle_form}
              processing_uploaded_audio_track={@processing_uploaded_audio_track}
              processing_uploaded_subtitle={@processing_uploaded_subtitle}
              current_space={@current_space}
              myself={@myself}
            />
          </div>
          <.settings_tab_skeleton />
        </div>

        <:footer>
          <.encoding_section
            :if={!match?(%{original: %{audio_only: true}}, @video)}
            renditions={@video.renditions}
          />
          <.publish_button has_changes={@has_changes} myself={@myself} />
          <.tab_navigation current_tab={@current_tab} myself={@myself} />
        </:footer>
      </.settings_panel>
    </div>
    """
  end

  attr :video, :map, required: true
  attr :show_flow_info, :boolean, required: true
  attr :show_flow_details, :boolean, required: true
  attr :myself, :any, required: true

  defp info_tab(assigns) do
    assigns =
      assign(
        assigns,
        :show_video_metadata,
        not assigns.video.original.audio_only and assigns.video.original.width > 0 and
          assigns.video.original.height > 0
      )

    ~H"""
    <div class="h-full">
      <.settings_header title="original" />
      <div class="text-sm text-stone-500 select-none px-3 py-3">
        <div
          id="original-media-info"
          class="bg-stone-800 py-3 rounded-sm flex flex-col items-center justify-center"
        >
          <div :if={@video.original.audio_only || @show_video_metadata} class="flex w-full mb-2">
            <div
              :if={@video.original.audio_only}
              id="original-media-kind"
              class="flex-grow text-center"
            >
              Audio only
            </div>
            <div :if={@show_video_metadata} id="original-resolution" class="flex-grow text-center">
              {@video.original.width}
              <span class="opacity-70 text-xs">x</span> {@video.original.height}
            </div>
          </div>
          <div class="flex w-full">
            <div
              :if={@video.original.file_size > 0}
              id="original-file-size"
              class="flex-grow text-center"
            >
              {format_file_size(@video.original.file_size)}
              <span class="opacity-70">{file_size_unit(@video.original.file_size)}</span>
            </div>
            <div
              :if={@show_video_metadata && @video.original.fps > 0}
              id="original-frame-rate"
              class="flex-grow text-center"
            >
              {@video.original.fps} <span class="opacity-70">FPS</span>
            </div>
            <div
              :if={@show_video_metadata && @video.original.bitrate > 0}
              id="original-bitrate"
              class="flex-grow text-center"
            >
              {@video.original.bitrate} <span class="opacity-70">Mbit</span>
            </div>
          </div>
        </div>
      </div>

      <.renditions_section
        audio_only={@video.original.audio_only}
        renditions={@video.renditions}
        audio_tracks={@video.audio_tracks}
        subtitles={@video.subtitles}
      />

      <.settings_header
        :if={@show_flow_info && @video.flow}
        title="flow"
        disclosable
        expanded={@show_flow_details}
        phx-click="toggle_flow_details"
        phx-target={@myself}
      />

      <.flow_section
        :if={@show_flow_info && @show_flow_details}
        flow={@video.flow}
        myself={@myself}
      />
    </div>
    """
  end

  attr :flow, :map, default: nil
  attr :myself, :any, default: nil

  defp flow_section(%{flow: nil} = assigns) do
    ~H"""
    """
  end

  defp flow_section(assigns) do
    flow_summary = normalize_flow_summary(assigns.flow.summary)
    flow_steps = normalize_flow_steps(assigns.flow.steps)

    assigns =
      assigns
      |> assign(:flow_summary, flow_summary)
      |> assign(:completed_count, flow_completed_count(flow_summary))
      |> assign(:completion_percent, flow_completion_percent(flow_summary))
      |> assign(:visual_steps, flow_visual_steps(flow_steps, assigns.flow.status))

    ~H"""
    <div class="px-3 pb-3">
      <div class="overflow-hidden rounded-sm ring-1 ring-inset ring-stone-800/80 bg-stone-900/40">
        <div class="border-b border-stone-800/80 px-3 py-2 text-xs text-stone-400">
          <div class="min-w-0">
            <div class="truncate text-sm text-stone-300">
              {@flow.template_slug || "custom"}
              <span class="text-stone-500">v{@flow.version || 1}</span>
            </div>
            <div class="mt-1 flex items-center gap-2 text-xs text-stone-600">
              <span>{@completed_count} of {@flow_summary.total} complete</span>
              <div class="h-1 w-16 overflow-hidden rounded-full bg-stone-800">
                <div
                  class="h-full rounded-full bg-stone-600 transition-all duration-200"
                  style={"width: #{@completion_percent}%"}
                >
                </div>
              </div>
            </div>
          </div>
          <div :if={@flow.active_step} class="mt-2 text-xs text-stone-500">
            Active: <span class="text-stone-300">{@flow.active_step.name}</span>
          </div>
        </div>

        <div class="py-1.5">
          <div :for={step <- @visual_steps} class="group px-3 py-1.5">
            <div class="flex items-center gap-2">
              <div
                class="relative h-5 flex-none"
                style={"width: #{flow_step_indent_width(step.depth)}rem"}
              >
                <div
                  :if={step.depth > 0}
                  class="absolute top-0 bottom-1/2 border-l border-stone-800/90"
                  style={"left: #{flow_step_connector_offset(step.depth)}rem"}
                >
                </div>
                <div
                  :if={step.depth > 0}
                  class="absolute top-1/2 h-px bg-stone-700/80"
                  style={"left: #{flow_step_connector_offset(step.depth)}rem; width: 0.65rem"}
                >
                </div>
              </div>
              <.flow_step_led status={step.status} />
              <div class="min-w-0 flex-1 truncate text-xs text-stone-400">{step.name}</div>
              <button
                :if={step.retryable}
                id={"retry-flow-step-#{step.id}"}
                type="button"
                phx-click="retry_flow_step"
                phx-target={@myself}
                phx-value-flow_run_id={@flow.id}
                phx-value-step_id={step.id}
                title="Retry step"
                aria-label="Retry step"
                class="invisible pointer-events-none flex h-4 w-4 flex-none cursor-pointer items-center justify-center rounded-full text-stone-500 opacity-0 group-hover:visible group-hover:pointer-events-auto group-hover:opacity-100 hover:bg-stone-800 hover:text-stone-300 focus:visible focus:pointer-events-auto focus:opacity-100"
              >
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  viewBox="0 0 20 20"
                  fill="currentColor"
                  class="h-3.5 w-3.5"
                >
                  <path
                    fill-rule="evenodd"
                    d="M15.312 11.424a5.5 5.5 0 1 1-1.26-5.847.75.75 0 1 1-1.141.974 4 4 0 1 0 .915 4.25h-1.576a.75.75 0 0 1 0-1.5h3a.75.75 0 0 1 .75.75v3a.75.75 0 0 1-1.5 0v-1.627Z"
                    clip-rule="evenodd"
                  />
                </svg>
              </button>
            </div>
            <div
              :if={step.status == "failed" && step.error}
              class="mt-0.5 truncate text-xs text-red-400/80"
              style={"margin-left: #{flow_error_indent(step.depth)}rem"}
            >
              {step.error}
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp flow_visual_steps(steps, flow_status) do
    step_lookup = Map.new(steps, &{&1.id, &1})
    retryable_ids = flow_retryable_step_ids(steps, flow_status)

    Enum.map(steps, fn step ->
      step
      |> Map.put(:depth, flow_step_depth(step, step_lookup, MapSet.new()))
      |> Map.put(:retryable, MapSet.member?(retryable_ids, step.id))
    end)
  end

  defp flow_retryable_step_ids(_steps, "cancelled"), do: MapSet.new()

  defp flow_retryable_step_ids(steps, _flow_status) do
    step_lookup = Map.new(steps, &{&1.id, &1})

    dependents_by_id =
      Enum.reduce(steps, %{}, fn step, acc ->
        Enum.reduce(step.depends_on || [], acc, fn dependency, inner_acc ->
          Map.update(inner_acc, dependency.id, [step.id], &[step.id | &1])
        end)
      end)

    steps
    |> Enum.filter(fn step ->
      Definition.terminal_step_status?(step.status) and
        retry_subtree_resettable?(step.id, step_lookup, dependents_by_id, MapSet.new())
    end)
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  defp retry_subtree_resettable?(step_id, step_lookup, dependents_by_id, seen) do
    if MapSet.member?(seen, step_id) do
      true
    else
      next_seen = MapSet.put(seen, step_id)

      case Map.get(step_lookup, step_id) do
        %{status: status} when is_binary(status) ->
          status != "executing" and
            resettable_dependents?(step_id, step_lookup, dependents_by_id, next_seen)

        _ ->
          false
      end
    end
  end

  defp resettable_dependents?(step_id, step_lookup, dependents_by_id, next_seen) do
    dependents_by_id
    |> Map.get(step_id, [])
    |> Enum.all?(fn dependent_id ->
      retry_subtree_resettable?(dependent_id, step_lookup, dependents_by_id, next_seen)
    end)
  end

  defp flow_step_depth(step, step_lookup, seen) do
    if MapSet.member?(seen, step.id) do
      0
    else
      case step.depends_on || [] do
        [] ->
          0

        depends_on ->
          dependency_depths(depends_on, step_lookup, MapSet.put(seen, step.id))
      end
    end
  end

  defp dependency_depths(depends_on, step_lookup, next_seen) do
    depends_on
    |> Enum.map(&dependency_depth(&1, step_lookup, next_seen))
    |> Enum.max(fn -> 0 end)
  end

  defp dependency_depth(dependency, step_lookup, next_seen) do
    case Map.get(step_lookup, dependency.id) do
      nil -> 0
      dependency_step -> flow_step_depth(dependency_step, step_lookup, next_seen) + 1
    end
  end

  defp flow_step_indent_width(depth) when depth <= 0, do: 0.25
  defp flow_step_indent_width(depth), do: 0.35 + depth * 0.75

  defp flow_step_connector_offset(depth) when depth <= 0, do: 0.0
  defp flow_step_connector_offset(depth), do: (depth - 1) * 0.75 + 0.1

  defp flow_error_indent(depth), do: 1.125 + flow_step_indent_width(depth)

  defp flow_completed_count(summary) do
    Enum.reduce([:succeeded, :failed, :skipped, :cancelled], 0, fn key, acc ->
      acc + Map.get(summary, key, 0)
    end)
  end

  defp flow_completion_percent(summary) do
    total = Map.get(summary, :total, 0)

    if total > 0 do
      flow_completed_count(summary)
      |> Kernel./(total)
      |> Kernel.*(100)
      |> round()
    else
      0
    end
  end

  defp normalize_flow_summary(nil), do: %{total: 0}

  defp normalize_flow_summary(summary) when is_map(summary) do
    %{
      total: Map.get(summary, :total, 0) || 0,
      succeeded: Map.get(summary, :succeeded, 0) || 0,
      failed: Map.get(summary, :failed, 0) || 0,
      skipped: Map.get(summary, :skipped, 0) || 0,
      cancelled: Map.get(summary, :cancelled, 0) || 0
    }
  end

  defp normalize_flow_summary(_summary), do: %{total: 0}

  defp normalize_flow_steps(steps) when is_list(steps), do: steps
  defp normalize_flow_steps(_steps), do: []

  attr :settings, :map, required: true
  attr :video, :map, default: nil
  attr :uploads, :map, required: true
  attr :uploading_poster, :boolean, required: true
  attr :audio_track_form, :map, default: nil
  attr :subtitle_form, :map, default: nil
  attr :processing_uploaded_audio_track, :map, default: nil
  attr :processing_uploaded_subtitle, :map, default: nil
  attr :current_space, :map, required: true
  attr :myself, :any, required: true

  defp options_tab(assigns) do
    assigns =
      assigns
      |> assign(
        :show_audio_tracks_section,
        show_audio_tracks_section?(
          assigns.video,
          assigns.audio_track_form,
          assigns.processing_uploaded_audio_track
        )
      )
      |> assign(
        :show_subtitles_section,
        show_subtitles_section?(
          assigns.video,
          assigns.subtitle_form,
          assigns.processing_uploaded_subtitle
        )
      )

    ~H"""
    <div class="h-full pb-20">
      <.dimensions_section settings={@settings} myself={@myself} />
      <.aspect_ratio_section
        :if={!match?(%{original: %{audio_only: true}}, @video)}
        settings={@settings}
        myself={@myself}
      />
      <.style_section settings={@settings} myself={@myself} />
      <.thumbnail_section
        settings={@settings}
        video={@video}
        uploads={@uploads}
        uploading_poster={@uploading_poster}
        myself={@myself}
      />
      <.audio_tracks_options_section
        :if={@show_audio_tracks_section}
        tracks={@video.audio_tracks}
        audio_track_form={@audio_track_form}
        processing_uploaded_audio_track={@processing_uploaded_audio_track}
        uploads={@uploads}
        myself={@myself}
      />
      <.subtitles_options_section
        :if={@show_subtitles_section}
        video={@video}
        subtitles={@video.subtitles || []}
        subtitle_form={@subtitle_form}
        processing_uploaded_subtitle={@processing_uploaded_subtitle}
        uploads={@uploads}
        current_space={@current_space}
        myself={@myself}
      />
      <.controls_section settings={@settings} myself={@myself} />
      <.autoplay_section settings={@settings} myself={@myself} />
      <.loop_section settings={@settings} myself={@myself} />
    </div>
    """
  end

  attr :settings, :map, required: true
  attr :myself, :any, required: true

  defp dimensions_section(assigns) do
    ~H"""
    <div>
      <.settings_header title="dimensions" />
      <form
        id="settings-dimensions-form"
        phx-change="change_settings"
        phx-target={@myself}
        class="grid grid-cols-2 gap-3 p-3"
      >
        <.dimension_input
          name="settings[width]"
          value={@settings.width}
          label="W"
          disabled={@settings.aspect_ratio_enabled}
        />
        <.dimension_input
          name="settings[height]"
          value={@settings.height}
          label="H"
          disabled={@settings.aspect_ratio_enabled}
        />
      </form>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, required: true
  attr :disabled, :boolean, default: false

  defp dimension_input(assigns) do
    ~H"""
    <div class="relative">
      <input
        type="text"
        name={@name}
        value={@value}
        class={[
          "w-full h-6 bg-stone-800 border-b border-stone-800 px-2 py-0.5 text-sm text-stone-400",
          "outline-none focus:ring-blue-600 ring-1 rounded-sm ring-transparent",
          @disabled && "opacity-50 pointer-events-none"
        ]}
      />
      <div class="absolute h-full flex items-center right-1 top-0 text-xs text-stone-500 px-1">
        {@label}
      </div>
    </div>
    """
  end

  attr :settings, :map, required: true
  attr :myself, :any, required: true

  defp aspect_ratio_section(assigns) do
    ~H"""
    <div>
      <.settings_header
        title="aspect ratio"
        toggable
        toggle_enabled={@settings.aspect_ratio_enabled}
        phx-click="toggle"
        phx-target={@myself}
        phx-value-title="aspect_ratio"
      />
      <.settings_option_grid visible={@settings.aspect_ratio_enabled}>
        <.aspect_ratio_option
          label="16:9"
          value={:r16_9}
          selected={@settings.aspect_ratio == :r16_9}
          myself={@myself}
        >
          <div class="h-4 aspect-video border border-stone-500 mt-1.5 rounded-sm"></div>
        </.aspect_ratio_option>
        <.aspect_ratio_option
          label="1:1"
          value={:r1_1}
          selected={@settings.aspect_ratio == :r1_1}
          myself={@myself}
        >
          <div class="h-4 aspect-square border border-stone-500 mt-1.5 rounded-sm"></div>
        </.aspect_ratio_option>
        <.aspect_ratio_option
          label="4:3"
          value={:r4_3}
          selected={@settings.aspect_ratio == :r4_3}
          myself={@myself}
        >
          <div class="h-4 aspect-[4/3] border border-stone-500 mt-1.5 rounded-sm"></div>
        </.aspect_ratio_option>
        <.aspect_ratio_option
          label="auto"
          value={:auto}
          selected={@settings.aspect_ratio == :auto}
          myself={@myself}
        >
          <div class="h-4 aspect-square border border-dashed border-stone-500 mt-1.5 rounded-sm">
          </div>
        </.aspect_ratio_option>
      </.settings_option_grid>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :atom, required: true
  attr :selected, :boolean, required: true
  attr :myself, :any, required: true
  slot :inner_block, required: true

  defp aspect_ratio_option(assigns) do
    ~H"""
    <.settings_option
      label={@label}
      value={@value}
      selected={@selected}
      phx-click="select_option"
      phx-target={@myself}
      phx-value-title="aspect_ratio"
      phx-value-label={@value}
    >
      {render_slot(@inner_block)}
    </.settings_option>
    """
  end

  attr :settings, :map, required: true
  attr :myself, :any, required: true

  defp style_section(assigns) do
    ~H"""
    <div>
      <.settings_header title="style" />
      <div class="p-3 w-full flex items-center">
        <.color_picker
          id="video-color"
          color={@settings.color}
          opacity={@settings.opacity || 100}
          on_select={JS.push("change_color", target: @myself)}
        />
        <form
          id="settings-style-form"
          phx-change="change_settings"
          phx-target={@myself}
          class="flex ml-3 flex-grow"
        >
          <div class={["relative flex-grow", is_nil(@settings.color) && "opacity-50"]}>
            <input
              type="text"
              name="settings[color]"
              value={@settings.color}
              class="w-full bg-stone-800 border-b border-stone-800 pl-4 pr-2 py-0.5 text-sm text-stone-400 outline-none focus:ring-blue-600 ring-1 rounded-sm ring-transparent"
            />
            <div class="absolute h-full flex items-center left-0.5 top-0 text-xs text-stone-500 px-1">
              #
            </div>
          </div>
          <div class={["relative ml-3", is_nil(@settings.color) && "opacity-50"]}>
            <input
              type="number"
              name="settings[opacity]"
              value={@settings.opacity}
              class="appearance-none w-12 bg-stone-800 border-b border-stone-800 px-2 py-0.5 text-sm text-stone-400 outline-none focus:ring-blue-600 ring-1 rounded-sm ring-transparent"
            />
            <div class="absolute h-full flex items-center right-1 top-0 text-xs text-stone-500 px-1">
              %
            </div>
          </div>
        </form>
      </div>
    </div>
    """
  end

  attr :settings, :map, required: true
  attr :video, :map, default: nil
  attr :uploads, :map, required: true
  attr :uploading_poster, :boolean, required: true
  attr :myself, :any, required: true

  defp thumbnail_section(assigns) do
    assigns =
      assign(assigns, :audio_only, match?(%{original: %{audio_only: true}}, assigns.video))

    ~H"""
    <div>
      <.settings_header title="thumb" />
      <.settings_option_grid visible={true}>
        <.settings_option
          label="upload"
          value={:upload}
          selected={@settings.poster == :upload}
          phx-click="select_option"
          phx-target={@myself}
          phx-value-title="poster"
          phx-value-label="upload"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            fill="none"
            viewBox="0 0 24 24"
            stroke-width="0.9"
            stroke="currentColor"
            class="w-7 h-7 -mb-1.5 text-stone-500"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M12 16.5V9.75m0 0l3 3m-3-3l-3 3M6.75 19.5a4.5 4.5 0 01-1.41-8.775 5.25 5.25 0 0110.233-2.33 3 3 0 013.758 3.848A3.752 3.752 0 0118 19.5H6.75z"
            />
          </svg>
        </.settings_option>
        <.settings_option
          :if={!@audio_only}
          label="timestamp"
          value={:timecode}
          selected={@settings.poster == :timecode}
          phx-click="select_option"
          phx-target={@myself}
          phx-value-title="poster"
          phx-value-label="timecode"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            fill="none"
            viewBox="0 0 24 24"
            stroke-width="0.9"
            stroke="currentColor"
            class="w-7 h-7 -mb-1.5 text-stone-500"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M12 6v6h4.5m4.5 0a9 9 0 11-18 0 9 9 0 0118 0z"
            />
          </svg>
        </.settings_option>
      </.settings_option_grid>

      <div :if={@settings.poster == :upload} class="relative w-full px-3 pb-3">
        <% entry = poster_upload_entry(@uploads) %>
        <div
          id="droparea"
          phx-drop-target={
            if !is_binary(@settings.external_poster) or @settings.external_poster == "",
              do: @uploads.poster_image.ref
          }
          class="relative w-full aspect-video bg-stone-800 rounded-sm flex flex-col items-center justify-center overflow-hidden bg-cover bg-center"
          style={poster_upload_style(poster_upload_preview(@settings, @video))}
        >
          <%= if !is_binary(@settings.external_poster) or @settings.external_poster == "" do %>
            <form
              id="settings-poster-upload-form"
              phx-change="noop"
              phx-target={@myself}
              class="absolute inset-0 z-20"
            >
              <.live_file_input
                upload={@uploads.poster_image}
                class="absolute inset-0 opacity-0 cursor-pointer"
              />
            </form>
          <% end %>

          <div class="absolute inset-0 pointer-events-none bg-stone-950/15"></div>
          <div class="relative z-10 w-full max-w-[11rem] px-4 flex flex-col items-center pointer-events-none">
            <%= cond do %>
              <% entry && entry.progress < 100 -> %>
                <div class="w-full">
                  <.progress_bar progress={round(entry.progress)} size="md" class="w-full" />
                </div>
                <div class="text-sm text-stone-200 mt-3">{gettext("uploading poster")}</div>
                <div class="text-xs text-stone-400 mt-1">{round(entry.progress)}%</div>
              <% @uploading_poster -> %>
                <div
                  id="poster-processing"
                  class="h-4 w-4 animate-spin rounded-full border border-stone-300/60 border-t-transparent"
                >
                </div>
                <div class="text-sm text-stone-200 mt-3">{gettext("processing poster")}</div>
              <% is_binary(@settings.external_poster) and @settings.external_poster != "" -> %>
                <div></div>
              <% true -> %>
                <div class="text-sm text-stone-200 mt-1">{gettext("drop file here")}</div>
                <div class="text-sm text-stone-500 mt-2.5 px-2 leading-5 pb-[0.15rem] bg-stone-900 rounded-full ring-1 ring-white/5 shadow">
                  {gettext("browse")}
                </div>
            <% end %>
          </div>
        </div>

        <div
          :if={entry && poster_upload_errors(@uploads, entry) != []}
          class="mt-2 text-xs text-red-400"
        >
          {poster_upload_error(@uploads, entry)}
        </div>

        <form
          :if={is_binary(@settings.external_poster) and @settings.external_poster != ""}
          id="settings-poster-upload-form"
          phx-change="noop"
          phx-target={@myself}
          class="absolute -top-1 right-10 z-30"
        >
          <label class="group relative flex h-5 w-5 cursor-pointer items-center justify-center overflow-hidden rounded-full bg-stone-800/95 text-stone-300 ring-1 ring-stone-700 shadow-black transition-all duration-75 ease-in active:scale-100 hover:scale-110 hover:text-white hover:shadow">
            <.live_file_input
              upload={@uploads.poster_image}
              class="pointer-events-none absolute inset-0 z-10 h-full w-full opacity-0"
            />
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="pointer-events-none h-3.5 w-3.5 transform-gpu"
              width="24"
              height="24"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.9"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <path d="M3 12a9 9 0 0 1 15.3-6.364L21 8" />
              <path d="M21 3v5h-5" />
              <path d="M21 12a9 9 0 0 1-15.3 6.364L3 16" />
              <path d="M8 16H3v5" />
            </svg>
          </label>
        </form>

        <button
          :if={is_binary(@settings.external_poster) and @settings.external_poster != ""}
          type="button"
          phx-click="delete_external_poster"
          phx-target={@myself}
          class="absolute -top-1 right-3 z-30 h-5 w-5 bg-blue-600 ring-2 ring-blue-600 rounded-full text-white cursor-pointer active:scale-100 hover:scale-110 hover:shadow shadow-black transition-all duration-75 ease-in flex items-center justify-center"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            class="w-3.5 h-3.5 transform-gpu"
            width="24"
            height="24"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
          >
            <path stroke-linecap="round" stroke-linejoin="round" d="M6 18 18 6M6 6l12 12" />
          </svg>
        </button>
      </div>

      <div :if={!@audio_only and @settings.poster == :timecode} class="px-3 pb-3">
        <.thumbnail_preview
          :if={thumbnail_preview_available?(@video)}
          video={@video}
          settings={@settings}
        />

        <div
          :if={!thumbnail_preview_available?(@video)}
          class="rounded-sm bg-stone-800/70 px-3 py-2 text-xs text-stone-500"
        >
          {gettext("Preview becomes available once the original or first video rendition is ready.")}
        </div>
      </div>

      <form
        :if={!@audio_only and @settings.poster == :timecode}
        id="settings-poster-time-form"
        phx-change="change_settings"
        phx-target={@myself}
        class="px-3 pb-3 pt-0"
      >
        <div class="flex gap-[1px]">
          <div class="border-t-[0.11rem] border-stone-900 bg-stone-800 px-2 text-stone-500 flex items-center justify-center">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              fill="none"
              viewBox="0 0 24 24"
              stroke-width="1.6"
              stroke="currentColor"
              class="w-4 h-4"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                d="M12 6v6h4.5m4.5 0a9 9 0 11-18 0 9 9 0 0118 0z"
              />
            </svg>
          </div>
          <.time_input
            name="settings[poster_time_hour]"
            label="H"
            value={time_value(@settings.poster_time_hour)}
          />
          <.time_input
            name="settings[poster_time_minute]"
            label="M"
            value={time_value(@settings.poster_time_minute)}
          />
          <.time_input
            name="settings[poster_time_second]"
            label="S"
            value={time_value(@settings.poster_time_second)}
          />
        </div>
      </form>
    </div>
    """
  end

  attr :video, :map, required: true
  attr :settings, :map, required: true

  defp thumbnail_preview(assigns) do
    preview = assigns.video.thumbnail_preview
    selected_time = normalize_seconds(assigns.settings.poster_time_seconds || 0.0)

    assigns =
      assigns
      |> assign(:preview, preview)
      |> assign(:selected_time, selected_time)

    ~H"""
    <div
      id="thumbnail-preview"
      phx-hook="thumbnail_preview"
      data-preview-src={@preview.preferred_src}
      data-fallback-src={@preview.fallback_src}
      data-selected-time={@selected_time}
      class="mb-3"
    >
      <div id="scrub_area" class="relative h-20 w-full">
        <div class="flex h-full w-full overflow-hidden rounded-sm bg-stone-800">
          <div
            :for={frame <- @preview.frame_srcs}
            class="h-full flex-1 bg-center bg-cover bg-no-repeat"
            style={"background-image: url(#{frame.src})"}
          >
          </div>
        </div>

        <div class="pointer-events-none absolute inset-0 rounded-sm ring-1 ring-inset ring-white/10">
        </div>

        <div
          id="video_container"
          class="absolute top-0 left-0 h-full w-1/4 cursor-pointer overflow-hidden rounded-sm border border-white bg-stone-950 shadow shadow-black transition-transform duration-75 ease-out active:scale-105 active:cursor-col-resize"
        >
          <video
            muted
            playsinline
            preload="metadata"
            poster={@video.preview_poster}
            class="h-full w-full bg-black object-cover"
          ></video>
        </div>
      </div>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true

  defp time_input(assigns) do
    ~H"""
    <div class="relative flex-grow">
      <input
        type="number"
        step="0.01"
        name={@name}
        value={@value}
        class="w-full h-6 bg-stone-800 px-2 py-0.5 text-sm text-stone-400 outline-none focus:ring-blue-600 ring-1 rounded-sm ring-transparent"
        placeholder="0"
      />
      <div class="absolute h-full flex items-center right-1 top-0 text-xs text-stone-500 px-1">
        {@label}
      </div>
    </div>
    """
  end

  attr :settings, :map, required: true
  attr :myself, :any, required: true

  defp controls_section(assigns) do
    ~H"""
    <div>
      <.settings_header
        title="controls"
        toggable
        toggle_enabled={@settings.controls_enabled}
        phx-click="toggle"
        phx-target={@myself}
        phx-value-title="controls"
      />
      <.settings_option_grid visible={@settings.controls_enabled}>
        <.settings_option
          label="full"
          value={:full}
          selected={@settings.controls == :full}
          phx-click="select_option"
          phx-target={@myself}
          phx-value-title="controls"
          phx-value-label="full"
        >
          <div class="h-4 aspect-video border border-stone-500 mt-1.5 rounded-sm flex">
            <div class="w-full h-1 mt-auto border-t border-stone-500"></div>
          </div>
        </.settings_option>
        <.settings_option
          label="big"
          value={:big}
          selected={@settings.controls == :big}
          phx-click="select_option"
          phx-target={@myself}
          phx-value-title="controls"
          phx-value-label="big"
        >
          <div class="aspect-video h-4 border border-stone-500 mt-1.5 rounded-sm flex items-center justify-center">
            <svg
              class="w-1.5 h-1.5"
              xmlns="http://www.w3.org/2000/svg"
              viewBox="0 0 24 24"
              fill="currentColor"
            >
              <polygon points="5 3 19 12 5 21 5 3"></polygon>
            </svg>
          </div>
        </.settings_option>
      </.settings_option_grid>
    </div>
    """
  end

  attr :settings, :map, required: true
  attr :myself, :any, required: true

  defp autoplay_section(assigns) do
    ~H"""
    <div>
      <.settings_header
        title="autoplay"
        toggable
        toggle_enabled={@settings.autoplay_enabled}
        phx-click="toggle"
        phx-target={@myself}
        phx-value-title="autoplay"
      />
      <.settings_option_grid visible={@settings.autoplay_enabled}>
        <.settings_option
          label="lazy"
          value={:on_show}
          selected={@settings.autoplay == :on_show}
          phx-click="select_option"
          phx-target={@myself}
          phx-value-title="autoplay"
          phx-value-label="on_show"
        >
          <svg
            class="w-full h-6 text-stone-500 -mb-1"
            width="24"
            height="24"
            stroke-width="1"
            viewBox="0 0 24 24"
            fill="none"
            xmlns="http://www.w3.org/2000/svg"
          >
            <path
              d="M4.5 12.5C7.5 6 16.5 6 19.5 12.5"
              stroke="currentColor"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
            <path
              d="M12 16C10.8954 16 10 15.1046 10 14C10 12.8954 10.8954 12 12 12C13.1046 12 14 12.8954 14 14C14 15.1046 13.1046 16 12 16Z"
              stroke="currentColor"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
          </svg>
        </.settings_option>
        <.settings_option
          label="always"
          value={:always}
          selected={@settings.autoplay == :always}
          phx-click="select_option"
          phx-target={@myself}
          phx-value-title="autoplay"
          phx-value-label="always"
        >
          <svg
            class="w-full h-6 text-stone-500 -mb-1"
            width="24"
            height="24"
            stroke-width="1"
            viewBox="0 0 24 24"
            fill="none"
            xmlns="http://www.w3.org/2000/svg"
          >
            <path
              d="M4.5 8C7.5 14.5 16.5 14.5 19.5 8"
              stroke="currentColor"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
            <path
              d="M16.8162 11.3175L19.5 15"
              stroke="currentColor"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
            <path
              d="M12 12.875V16.5"
              stroke="currentColor"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
            <path
              d="M7.18383 11.3175L4.5 15"
              stroke="currentColor"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
          </svg>
        </.settings_option>
      </.settings_option_grid>
    </div>
    """
  end

  attr :settings, :map, required: true
  attr :myself, :any, required: true

  defp loop_section(assigns) do
    ~H"""
    <.settings_header
      title="loop"
      toggable
      toggle_enabled={@settings.loop_enabled}
      phx-click="toggle"
      phx-target={@myself}
      phx-value-title="loop"
    />
    """
  end

  attr :track, :map, required: true
  attr :language_options, :list, required: true

  defp processing_audio_track_row(assigns) do
    ~H"""
    <div class="relative w-full flex items-center my-1.5 pointer-events-none">
      <div class="flex-grow border-r border-stone-900 pr-2">
        <div class="flex flex-col space-y-1.5">
          <input
            type="text"
            value={Map.get(@track, :label) || gettext("Audio track")}
            class="w-full h-6 bg-stone-800 border-b border-stone-800 px-2 py-0.5 text-sm text-stone-400 outline-none ring-1 rounded-sm ring-transparent"
            disabled
          />
          <div class="relative">
            <select
              class="w-full h-6 bg-stone-800 border-b border-stone-800 px-2 py-0.5 pr-7 text-sm text-stone-400 outline-none ring-1 rounded-sm ring-transparent appearance-none"
              disabled
            >
              {Phoenix.HTML.Form.options_for_select(
                @language_options,
                Map.get(@track, :language) || ""
              )}
            </select>
            <div class="absolute right-0 top-0 w-6 h-6 bg-stone-800 flex items-center justify-center text-stone-500 opacity-60 pointer-events-none">
              <svg
                class="w-3"
                width="24"
                height="24"
                stroke-width="2.5"
                viewBox="0 0 24 24"
                fill="none"
                xmlns="http://www.w3.org/2000/svg"
              >
                <path
                  d="M6 9L12 15L18 9"
                  stroke="currentColor"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                />
              </svg>
            </div>
          </div>
        </div>
      </div>

      <div class="relative flex-none h-6 px-1 text-sm bg-stone-800 text-stone-400 outline-none overflow-hidden rounded-sm flex items-center justify-center">
        <.media_spinner />
      </div>

      <div class="border-l border-stone-900 flex-none h-6 px-1 text-sm outline-none overflow-hidden rounded-sm flex items-center justify-end">
        <.remove_icon />
      </div>
    </div>
    """
  end

  attr :subtitle, :map, required: true
  attr :language_options, :list, required: true

  defp processing_subtitle_row(assigns) do
    ~H"""
    <div class="relative w-full flex items-center my-1.5 pointer-events-none">
      <div class="relative flex-grow flex border-r border-stone-900 pr-2">
        <div class="w-full">
          <div class="relative">
            <select
              class="w-full h-6 bg-stone-800 border-b border-stone-800 px-2 py-0.5 pr-7 text-sm text-stone-400 outline-none ring-1 rounded-sm ring-transparent appearance-none"
              disabled
            >
              {Phoenix.HTML.Form.options_for_select(
                @language_options,
                Map.get(@subtitle, :language) || ""
              )}
            </select>
            <div class="absolute right-0 top-0 w-6 h-6 bg-stone-800 flex items-center justify-center text-stone-500 opacity-60 pointer-events-none">
              <svg
                class="w-3"
                width="24"
                height="24"
                stroke-width="2.5"
                viewBox="0 0 24 24"
                fill="none"
                xmlns="http://www.w3.org/2000/svg"
              >
                <path
                  d="M6 9L12 15L18 9"
                  stroke="currentColor"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                />
              </svg>
            </div>
          </div>
        </div>
      </div>

      <div class="relative flex-none h-6 px-1 text-sm bg-stone-800 text-stone-400 outline-none overflow-hidden rounded-sm flex items-center justify-center">
        <.download_icon />
      </div>

      <div class="relative ml-px flex-none h-6 px-1 text-sm bg-stone-800 text-stone-400 outline-none overflow-hidden rounded-sm flex items-center justify-center">
        <.media_spinner />
      </div>

      <div class="border-l border-stone-900 flex-none h-6 px-1 text-sm outline-none overflow-hidden rounded-sm flex items-center justify-end">
        <.remove_icon />
      </div>
    </div>
    """
  end

  defp download_icon(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="1.5"
      stroke="currentColor"
      class="w-4 h-4"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M12 4.5v15m0 0l6.75-6.75M12 19.5l-6.75-6.75"
      />
    </svg>
    """
  end

  defp replace_icon(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="2"
      stroke="currentColor"
      class="h-3.5 w-3.5"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M16.023 9.348h4.992v-.001M2.985 19.644v-4.992m0 0h4.992m-4.992 0 3.181 3.183a8.25 8.25 0 0 0 13.803-3.7M4.031 9.865a8.25 8.25 0 0 1 13.803-3.7l3.181 3.182"
      />
    </svg>
    """
  end

  defp remove_icon(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="2"
      stroke="currentColor"
      class="h-4 w-4 rotate-45"
    >
      <path stroke-linecap="round" stroke-linejoin="round" d="M12 4.5v15m7.5-7.5h-15" />
    </svg>
    """
  end

  defp media_spinner(assigns) do
    ~H"""
    <div class="h-4 w-4 animate-spin rounded-full border border-stone-500 border-t-transparent"></div>
    """
  end

  attr :tracks, :list, required: true
  attr :audio_track_form, :map, default: nil
  attr :processing_uploaded_audio_track, :map, default: nil
  attr :uploads, :map, required: true
  attr :myself, :any, required: true

  defp audio_tracks_options_section(assigns) do
    assigns = assign(assigns, :language_options, language_options())
    has_tracks = Enum.any?(assigns.tracks || [])
    assigns = assign(assigns, :has_tracks, has_tracks)

    ~H"""
    <div>
      <.settings_header title="audio tracks" addable phx-click="add_audio_track" phx-target={@myself} />
      <div class="pl-3 pr-2.5 py-1.5 text-sm text-stone-400">
        <div
          :if={!@has_tracks and is_nil(@audio_track_form) and !@processing_uploaded_audio_track}
          class="h-1"
        >
        </div>
        <div
          :for={track <- @tracks}
          class={[
            "relative w-full flex items-center my-1.5",
            processing_audio_track?(@processing_uploaded_audio_track, track) && "pointer-events-none"
          ]}
        >
          <div class="flex-grow border-r border-stone-900 pr-2">
            <div class="flex flex-col space-y-1.5">
              <input
                name="audio_track[label]"
                type="text"
                value={track.label}
                placeholder="Audio track"
                class="w-full h-6 bg-stone-800 border-b border-stone-800 px-2 py-0.5 text-sm text-stone-400 outline-none focus:ring-blue-600 ring-1 rounded-sm ring-transparent"
                phx-blur="blur_audio_track_label"
                phx-target={@myself}
                phx-value-id={track.id}
              />
              <div class="relative">
                <select
                  name="audio_track[language]"
                  class="w-full h-6 bg-stone-800 border-b border-stone-800 px-2 py-0.5 pr-7 text-sm text-stone-400 outline-none focus:ring-blue-600 ring-1 rounded-sm ring-transparent appearance-none"
                  phx-change="change_audio_track_language"
                  phx-target={@myself}
                  phx-value-id={track.id}
                >
                  {Phoenix.HTML.Form.options_for_select(@language_options, track.language || "")}
                </select>
                <div class="absolute right-0 top-0 w-6 h-6 bg-stone-800 flex items-center justify-center text-stone-500 opacity-60 pointer-events-none">
                  <svg
                    class="w-3"
                    width="24"
                    height="24"
                    stroke-width="2.5"
                    viewBox="0 0 24 24"
                    fill="none"
                    xmlns="http://www.w3.org/2000/svg"
                  >
                    <path
                      d="M6 9L12 15L18 9"
                      stroke="currentColor"
                      stroke-linecap="round"
                      stroke-linejoin="round"
                    />
                  </svg>
                </div>
              </div>
            </div>
          </div>

          <div class={
              "relative flex-none h-6 px-1 text-sm bg-stone-800 text-stone-400 outline-none overflow-hidden rounded-sm flex items-center justify-center #{if active_audio_upload_target?(@audio_track_form, track), do: "hover:bg-stone-600", else: "cursor-pointer hover:bg-stone-600"}"
            }>
            <%= if active_audio_upload_target?(@audio_track_form, track) do %>
              <form
                id={"audio-track-picker-#{track.id}-#{@audio_track_form[:picker_ref]}"}
                phx-change="noop"
                phx-target={@myself}
                class="absolute inset-0"
                phx-hook="auto_open_file_picker"
                data-picker-ref={@audio_track_form[:picker_ref]}
              >
                <.live_file_input
                  upload={@uploads.audio_track_file}
                  class="absolute inset-0 opacity-0 cursor-pointer"
                />
              </form>
            <% end %>

            <%= if (@uploads.audio_track_file.entries != [] and active_audio_upload_target?(@audio_track_form, track)) or
                      processing_audio_track?(@processing_uploaded_audio_track, track) do %>
              <.media_spinner />
            <% else %>
              <button
                type="button"
                class="flex h-full items-center justify-center cursor-pointer"
                phx-click="replace_audio_track"
                phx-target={@myself}
                phx-value-id={track.id}
              >
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke-width="2"
                  stroke="currentColor"
                  class="h-3.5 w-3.5"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    d="M16.023 9.348h4.992v-.001M2.985 19.644v-4.992m0 0h4.992m-4.992 0 3.181 3.183a8.25 8.25 0 0 0 13.803-3.7M4.031 9.865a8.25 8.25 0 0 1 13.803-3.7l3.181 3.182"
                  />
                </svg>
              </button>
            <% end %>
          </div>

          <div class="border-l border-stone-900 flex-none h-6 px-1 text-sm outline-none overflow-hidden rounded-sm flex items-center justify-end">
            <button
              id={"delete-audio-track-#{track.id}"}
              type="button"
              aria-label={gettext("Remove audio track")}
              class={[
                "relative w-4 h-6 flex items-center justify-end text-stone-500 phx-click-loading:pointer-events-none phx-click-loading:cursor-wait phx-click-loading:text-stone-300",
                track.default && "opacity-40 pointer-events-none",
                !track.default && "cursor-pointer hover:text-stone-300"
              ]}
              phx-click={
                JS.push("delete_audio_track",
                  target: @myself,
                  value: %{id: track.id},
                  loading: "#delete-audio-track-#{track.id}"
                )
              }
            >
              <span class="inline-flex items-center justify-end phx-click-loading:hidden">
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke-width="2"
                  stroke="currentColor"
                  class="h-4 w-4 rotate-45"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    d="M12 4.5v15m7.5-7.5h-15"
                  />
                </svg>
              </span>
              <span class="hidden h-4 w-4 items-center justify-center phx-click-loading:inline-flex">
                <span class="h-3.5 w-3.5 animate-spin rounded-full border border-stone-500 border-t-transparent"></span>
              </span>
            </button>
          </div>
        </div>

        <.processing_audio_track_row
          :if={new_processing_media?(@processing_uploaded_audio_track)}
          track={@processing_uploaded_audio_track}
          language_options={@language_options}
        />

        <%= if @audio_track_form && @audio_track_form.mode == :new do %>
          <div class="w-full flex items-center my-1.5">
            <div class="flex-grow border-r border-stone-900 pr-2">
              <form
                id="new-audio-track-form"
                phx-change="change_new_audio_track"
                phx-target={@myself}
                class="flex flex-col space-y-1.5"
              >
                <input
                  name="audio_track[label]"
                  type="text"
                  value={@audio_track_form.label}
                  placeholder="Audio track"
                  class="w-full h-6 bg-stone-800 border-b border-stone-800 px-2 py-0.5 text-sm text-stone-400 outline-none focus:ring-blue-600 ring-1 rounded-sm ring-transparent"
                />
                <div class="relative">
                  <select
                    name="audio_track[language]"
                    class="w-full h-6 bg-stone-800 border-b border-stone-800 px-2 py-0.5 pr-7 text-sm text-stone-400 outline-none focus:ring-blue-600 ring-1 rounded-sm ring-transparent appearance-none"
                  >
                    {Phoenix.HTML.Form.options_for_select(
                      @language_options,
                      @audio_track_form.language || ""
                    )}
                  </select>
                  <div class="absolute right-0 top-0 w-6 h-6 bg-stone-800 flex items-center justify-center text-stone-500 opacity-60 pointer-events-none">
                    <svg
                      class="w-3"
                      width="24"
                      height="24"
                      stroke-width="2.5"
                      viewBox="0 0 24 24"
                      fill="none"
                      xmlns="http://www.w3.org/2000/svg"
                    >
                      <path
                        d="M6 9L12 15L18 9"
                        stroke="currentColor"
                        stroke-linecap="round"
                        stroke-linejoin="round"
                      />
                    </svg>
                  </div>
                </div>
              </form>
            </div>

            <form
              id="new-audio-track-upload-form"
              phx-change="noop"
              phx-target={@myself}
              class="relative flex-none h-6 px-1 text-sm bg-stone-800 text-stone-400 outline-none overflow-hidden rounded-sm flex items-center justify-center cursor-pointer hover:bg-stone-600"
            >
              <.live_file_input
                upload={@uploads.audio_track_file}
                class="absolute inset-0 opacity-0 cursor-pointer"
              />
              <%= if @uploads.audio_track_file.entries == [] do %>
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke-width="2"
                  stroke="currentColor"
                  class="h-4 w-4"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    d="M12 19.5v-15m0 0l6.75 6.75M12 4.5l-6.75 6.75"
                  />
                </svg>
              <% else %>
                <div class="h-4 w-4 animate-spin rounded-full border border-stone-500 border-t-transparent">
                </div>
              <% end %>
            </form>

            <div class="border-l border-stone-900 flex-none h-6 px-1 text-sm outline-none overflow-hidden rounded-sm flex items-center justify-end">
              <button
                type="button"
                class="w-4 h-6 flex items-center justify-end text-stone-500 cursor-pointer hover:text-stone-300"
                phx-click="cancel_audio_track"
                phx-target={@myself}
              >
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke-width="2"
                  stroke="currentColor"
                  class="h-4 w-4 rotate-45"
                >
                  <path stroke-linecap="round" stroke-linejoin="round" d="M12 4.5v15m7.5-7.5h-15" />
                </svg>
              </button>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :video, :map, required: true
  attr :subtitles, :list, required: true
  attr :subtitle_form, :map, default: nil
  attr :processing_uploaded_subtitle, :map, default: nil
  attr :uploads, :map, required: true
  attr :current_space, :map, required: true
  attr :myself, :any, required: true

  defp subtitles_options_section(assigns) do
    assigns = assign(assigns, :language_options, language_options())
    has_subtitles = Enum.any?(assigns.subtitles || [])
    assigns = assign(assigns, :has_subtitles, has_subtitles)

    ~H"""
    <div>
      <.settings_header title="subtitles" addable phx-click="add_subtitle" phx-target={@myself} />
      <div class="pl-3 pr-2.5 py-1.5 text-sm text-stone-400">
        <div
          :if={!@has_subtitles and is_nil(@subtitle_form) and !@processing_uploaded_subtitle}
          class="h-1"
        >
        </div>
        <div
          :for={subtitle <- @subtitles}
          class={[
            "relative w-full flex items-center my-1.5",
            processing_subtitle?(@processing_uploaded_subtitle, subtitle) && "pointer-events-none"
          ]}
        >
          <div class="relative flex-grow flex border-r border-stone-900 pr-2">
            <form
              id={"subtitle-language-form-#{subtitle.id}"}
              phx-change="change_subtitle"
              phx-target={@myself}
              class="w-full"
            >
              <input type="hidden" name="subtitle[id]" value={subtitle.id} />
              <div class="relative">
                <select
                  name="subtitle[language]"
                  class="w-full h-6 bg-stone-800 border-b border-stone-800 px-2 py-0.5 pr-7 text-sm text-stone-400 outline-none focus:ring-blue-600 ring-1 rounded-sm ring-transparent appearance-none"
                >
                  {Phoenix.HTML.Form.options_for_select(@language_options, subtitle.language || "")}
                </select>
                <div class="absolute right-0 top-0 w-6 h-6 bg-stone-800 flex items-center justify-center text-stone-500 opacity-60 pointer-events-none">
                  <svg
                    class="w-3"
                    width="24"
                    height="24"
                    stroke-width="2.5"
                    viewBox="0 0 24 24"
                    fill="none"
                    xmlns="http://www.w3.org/2000/svg"
                  >
                    <path
                      d="M6 9L12 15L18 9"
                      stroke="currentColor"
                      stroke-linecap="round"
                      stroke-linejoin="round"
                    />
                  </svg>
                </div>
              </div>
            </form>
          </div>

          <a
            href={DashboardRoutes.subtitle_download_path(@current_space, @video.id, subtitle.id)}
            download={subtitle_download_filename(subtitle)}
            class="relative flex-none h-6 px-1 text-sm bg-stone-800 text-stone-400 outline-none overflow-hidden rounded-sm flex items-center justify-center cursor-pointer hover:bg-stone-600"
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              fill="none"
              viewBox="0 0 24 24"
              stroke-width="1.5"
              stroke="currentColor"
              class="w-4 h-4"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                d="M12 4.5v15m0 0l6.75-6.75M12 19.5l-6.75-6.75"
              />
            </svg>
          </a>

          <div class="relative ml-px flex-none h-6 px-1 text-sm bg-stone-800 text-stone-400 outline-none overflow-hidden rounded-sm flex items-center justify-center cursor-pointer hover:bg-stone-600">
            <%= if active_subtitle_upload_target?(@subtitle_form, subtitle) do %>
              <form
                id={"subtitle-picker-#{subtitle.id}-#{@subtitle_form[:picker_ref]}"}
                phx-change="noop"
                phx-target={@myself}
                class="absolute inset-0"
                phx-hook="auto_open_file_picker"
                data-picker-ref={@subtitle_form[:picker_ref]}
              >
                <.live_file_input
                  upload={@uploads.subtitle_file}
                  class="absolute inset-0 opacity-0 cursor-pointer"
                />
              </form>
              <%= if @uploads.subtitle_file.entries != [] do %>
                <.media_spinner />
              <% else %>
                <.replace_icon />
              <% end %>
            <% else %>
              <%= if processing_subtitle?(@processing_uploaded_subtitle, subtitle) do %>
                <.media_spinner />
              <% else %>
                <button
                  type="button"
                  class="flex h-full items-center justify-center cursor-pointer"
                  phx-click="replace_subtitle"
                  phx-target={@myself}
                  phx-value-id={subtitle.id}
                >
                  <.replace_icon />
                </button>
              <% end %>
            <% end %>
          </div>

          <div class="border-l border-stone-900 flex-none h-6 px-1 text-sm outline-none overflow-hidden rounded-sm flex items-center justify-end">
            <button
              id={"delete-subtitle-#{subtitle.id}"}
              type="button"
              aria-label={gettext("Remove subtitle")}
              class="relative w-4 h-6 flex items-center justify-end text-stone-500 cursor-pointer hover:text-stone-300 phx-click-loading:pointer-events-none phx-click-loading:cursor-wait phx-click-loading:text-stone-300"
              phx-click={
                JS.push("delete_subtitle",
                  target: @myself,
                  value: %{id: subtitle.id},
                  loading: "#delete-subtitle-#{subtitle.id}"
                )
              }
            >
              <span class="inline-flex items-center justify-end phx-click-loading:hidden">
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke-width="2"
                  stroke="currentColor"
                  class="h-4 w-4 rotate-45"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    d="M12 4.5v15m7.5-7.5h-15"
                  />
                </svg>
              </span>
              <span class="hidden h-4 w-4 items-center justify-center phx-click-loading:inline-flex">
                <span class="h-3.5 w-3.5 animate-spin rounded-full border border-stone-500 border-t-transparent"></span>
              </span>
            </button>
          </div>
        </div>

        <.processing_subtitle_row
          :if={new_processing_media?(@processing_uploaded_subtitle)}
          subtitle={@processing_uploaded_subtitle}
          language_options={@language_options}
        />

        <%= if @subtitle_form && @subtitle_form.mode == :new do %>
          <div class="w-full flex items-center my-1.5">
            <div class="flex-grow border-r border-stone-900 pr-2">
              <form
                id="new-subtitle-form"
                phx-change="change_new_subtitle"
                phx-target={@myself}
                class="w-full"
              >
                <div class="relative">
                  <select
                    name="subtitle[language]"
                    class="w-full h-6 bg-stone-800 border-b border-stone-800 px-2 py-0.5 pr-7 text-sm text-stone-400 outline-none focus:ring-blue-600 ring-1 rounded-sm ring-transparent appearance-none"
                  >
                    {Phoenix.HTML.Form.options_for_select(
                      @language_options,
                      @subtitle_form.language || ""
                    )}
                  </select>
                  <div class="absolute right-0 top-0 w-6 h-6 bg-stone-800 flex items-center justify-center text-stone-500 opacity-60 pointer-events-none">
                    <svg
                      class="w-3"
                      width="24"
                      height="24"
                      stroke-width="2.5"
                      viewBox="0 0 24 24"
                      fill="none"
                      xmlns="http://www.w3.org/2000/svg"
                    >
                      <path
                        d="M6 9L12 15L18 9"
                        stroke="currentColor"
                        stroke-linecap="round"
                        stroke-linejoin="round"
                      />
                    </svg>
                  </div>
                </div>
              </form>
            </div>

            <form
              id="new-subtitle-upload-form"
              phx-change="noop"
              phx-target={@myself}
              class={[
                "relative flex-none h-6 px-1 text-sm bg-stone-800 text-stone-400 outline-none overflow-hidden rounded-sm flex items-center justify-center cursor-pointer hover:bg-stone-600",
                blank_to_nil(@subtitle_form.language) == nil && "opacity-60 pointer-events-none"
              ]}
            >
              <.live_file_input
                upload={@uploads.subtitle_file}
                class="absolute inset-0 opacity-0 cursor-pointer"
              />
              <%= if @uploads.subtitle_file.entries == [] do %>
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke-width="2"
                  stroke="currentColor"
                  class="w-4 h-4"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    d="M12 19.5v-15m0 0l6.75 6.75M12 4.5l-6.75 6.75"
                  />
                </svg>
              <% else %>
                <div class="h-4 w-4 animate-spin rounded-full border border-stone-500 border-t-transparent">
                </div>
              <% end %>
            </form>

            <div class="border-l border-stone-900 flex-none h-6 px-1 text-sm outline-none overflow-hidden rounded-sm flex items-center justify-end">
              <button
                type="button"
                class="w-4 h-6 flex items-center justify-end text-stone-500 cursor-pointer hover:text-stone-300"
                phx-click="cancel_subtitle"
                phx-target={@myself}
              >
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke-width="2"
                  stroke="currentColor"
                  class="h-4 w-4 rotate-45"
                >
                  <path stroke-linecap="round" stroke-linejoin="round" d="M12 4.5v15m7.5-7.5h-15" />
                </svg>
              </button>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :renditions, :list, required: true
  attr :audio_tracks, :list, default: []
  attr :subtitles, :list, default: []

  attr :audio_only, :boolean, default: false

  defp renditions_section(assigns) do
    assigns =
      assign(assigns, :groups, [
        {"videos", ["video"]},
        {"audio", ["audio"]},
        {"subtitles", ["subtitle"]},
        {"clips", ["clip"]},
        {"keyframes", ["clip_keyframes"]},
        {"images", ["poster", "thumbnail", "placeholder", "storyboard", "custom_thumbnail"]}
      ])

    ~H"""
    <div>
      <%= for {label, types} <- @groups, not (@audio_only and label in ["videos", "clips", "keyframes"]) do %>
        <% grouped = renditions_of_group(@renditions, types) %>
        <% audio_group_rows =
          if label == "audio", do: audio_group_rows(@audio_tracks, grouped), else: [] %>
        <% subtitle_group_rows =
          if label == "subtitles", do: subtitle_group_rows(@subtitles, grouped), else: [] %>
        <%= unless grouped == [] and audio_group_rows == [] and subtitle_group_rows == [] do %>
          <.settings_header title={label} />
          <div id={"rendition-group-#{label}"} class="py-1.5">
            <%= if label == "images" do %>
              <div
                :for={group <- renditions_for_images(grouped)}
                class="flex items-center pl-3.5 pr-2 py-1.5"
              >
                <% {{type, progress, status}, renditions} = group %>
                <.rendition_led progress={progress} status={status} />
                <div class="w-full text-sm text-stone-500 mb-0.5 h-[1.225rem]">
                  {image_type_label(type)}
                </div>
                <div class="flex-grow"></div>
                <%= for badge <- image_badges(renditions) do %>
                  <.format_badge>{badge}</.format_badge>
                <% end %>
              </div>
            <% else %>
              <% rows =
                cond do
                  label == "audio" and audio_group_rows != [] -> audio_group_rows
                  label == "subtitles" and subtitle_group_rows != [] -> subtitle_group_rows
                  true -> grouped_rows_for(label, grouped)
                end %>
              <%= for row <- rows do %>
                <div class="flex items-center pl-3.5 pr-2 py-1.5">
                  <.rendition_led progress={row.progress} status={row.status} />
                  <%= if row.size do %>
                    <div class="w-10 text-center bg-stone-800 rounded text-xs text-stone-600/80 ring-1 ring-inset ring-stone-700/50 shadow px-1 py-[0.05rem] mr-1">
                      {row.size}
                    </div>
                  <% end %>
                  <%= if row.label do %>
                    <div class="w-full text-sm text-stone-500 mb-0.5 h-[1.225rem]">
                      {row.label}
                    </div>
                  <% else %>
                    <div class="flex-grow"></div>
                  <% end %>
                  <div class="flex-grow"></div>
                  <%= for badge <- row.badges do %>
                    <.format_badge>{badge}</.format_badge>
                  <% end %>
                </div>
              <% end %>
            <% end %>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  slot :inner_block, required: true

  defp format_badge(assigns) do
    ~H"""
    <div class="w-10 font-condensed text-center rounded text-xs text-stone-600/80 ring-1 ring-inset ring-stone-700/50 shadow px-1 pt-[0.02rem] pb-[0.09rem] mr-1">
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :progress, :integer, required: true
  attr :status, :string, default: nil

  defp rendition_led(%{status: "failed"} = assigns) do
    ~H"""
    <div class="w-2 h-2 rounded-full bg-gradient-to-b from-red-400 to-red-600 mr-2.5 flex-none"></div>
    """
  end

  defp rendition_led(%{progress: 100} = assigns) do
    ~H"""
    <div class="w-2 h-2 rounded-full bg-gradient-to-b from-green-400 to-green-600 mr-2.5 flex-none">
    </div>
    """
  end

  defp rendition_led(%{progress: p} = assigns) when is_integer(p) and p > 0 do
    ~H"""
    <div class="relative w-2 h-2 rounded-full bg-stone-900 ring-1 ring-stone-700/60 mr-2.5 flex-none">
      <div class="absolute -top-0.5 -left-0.5 w-[0.75rem] h-[0.75rem] ring-[0.1rem] ring-inset ring-blue-600 rounded-full flex-none animate-spin">
        <div class="w-[0.4rem] h-[0.4rem] bg-gradient-to-t from-stone-900 border-b-2 border-stone-900">
        </div>
      </div>
    </div>
    """
  end

  defp rendition_led(assigns) do
    ~H"""
    <div class="relative w-2 h-2 rounded-full bg-black ring-1 ring-stone-700/60 mr-2.5 flex-none">
    </div>
    """
  end

  attr :status, :string, required: true

  defp flow_step_led(%{status: "succeeded"} = assigns) do
    ~H"""
    <div class="w-2 h-2 rounded-full bg-gradient-to-b from-green-400 to-green-600 mr-2.5 flex-none">
    </div>
    """
  end

  defp flow_step_led(%{status: "executing"} = assigns) do
    ~H"""
    <div class="relative w-2 h-2 rounded-full bg-stone-900 ring-1 ring-stone-700/60 mr-2.5 flex-none">
      <div class="absolute -top-0.5 -left-0.5 w-[0.75rem] h-[0.75rem] ring-[0.1rem] ring-inset ring-blue-600 rounded-full animate-spin">
        <div class="w-[0.4rem] h-[0.4rem] bg-gradient-to-t from-stone-900 border-b-2 border-stone-900">
        </div>
      </div>
    </div>
    """
  end

  defp flow_step_led(%{status: status} = assigns) when status in ["scheduled", "queued"] do
    ~H"""
    <div class="relative w-2 h-2 rounded-full bg-black ring-1 ring-stone-700/60 mr-2.5 flex-none">
    </div>
    """
  end

  defp flow_step_led(%{status: "failed"} = assigns) do
    ~H"""
    <div class="w-2 h-2 rounded-full bg-gradient-to-b from-red-400 to-red-600 mr-2.5 flex-none"></div>
    """
  end

  defp flow_step_led(%{status: "skipped"} = assigns) do
    ~H"""
    <div class="w-2 h-2 rounded-full bg-gradient-to-b from-amber-300 to-amber-500 mr-2.5 flex-none">
    </div>
    """
  end

  defp flow_step_led(assigns) do
    ~H"""
    <div class="w-2 h-2 rounded-full bg-stone-600 mr-2.5 flex-none"></div>
    """
  end

  attr :renditions, :list, required: true

  defp encoding_section(assigns) do
    assigns =
      assign(
        assigns,
        :encoding,
        Enum.filter(assigns.renditions, fn rendition ->
          rendition.progress != 100 and rendition.type == "video" and rendition.container == "hls"
        end)
      )

    ~H"""
    <div :if={@encoding != []}>
      <div
        :for={rendition <- @encoding}
        id={"rendition_#{rendition.id}"}
        class="h-[calc(4rem+1px)] overflow-hidden px-3.5 pt-3.5 pb-3 border-t border-stone-800"
      >
        <div class="flex items-center">
          <div class="mr-2">
            <div class={[
              "rendition-status-indicator w-3 h-3 rounded-full",
              cond do
                rendition.status == "failed" ->
                  "rendition-status-failed bg-red-500/70 ring-1 ring-inset ring-red-400/60"

                rendition.progress == 0 || is_nil(rendition.progress) ->
                  "bg-black/15 ring-1 ring-inset ring-stone-800"

                true ->
                  "border border-stone-600/80 animate-spin"
              end
            ]}>
              <div
                :if={
                  rendition.status != "failed" && rendition.progress != 0 &&
                    !is_nil(rendition.progress)
                }
                class="rendition-activity-notch w-1 h-0.5 bg-stone-900"
              >
              </div>
            </div>
          </div>
          <div class="flex-grow text-xs text-stone-600/80">
            {encoding_status_label(rendition)}
          </div>
          <div class="w-10 font-condensed text-center rounded text-xs text-stone-600/80 ring-1 ring-inset ring-stone-700/50 shadow px-1 pt-[0.02rem] pb-[0.09rem] mr-1">
            {rendition.codec}
          </div>
          <div
            :if={rendition.size}
            class="w-10 text-center bg-stone-800 rounded text-xs text-stone-600/80 ring-1 ring-inset ring-stone-700/50 shadow px-1 py-[0.05rem]"
          >
            {rendition.size}
          </div>
        </div>
        <.progress_bar progress={rendition.progress || 0} class="my-2.5" />
      </div>
    </div>
    """
  end

  defp encoding_status_label(%{status: "failed"}), do: gettext("Failed")

  defp encoding_status_label(%{phase: "packaging"}), do: gettext("Packaging")
  defp encoding_status_label(%{phase: "encoding"}), do: gettext("Encoding")
  defp encoding_status_label(%{phase: "queued"}), do: gettext("Queued")

  defp encoding_status_label(%{progress: progress}) when progress in [nil, 0],
    do: gettext("Queued")

  defp encoding_status_label(%{progress: progress})
       when is_integer(progress) and progress >= @hls_packaging_phase_start_progress,
       do: gettext("Packaging")

  defp encoding_status_label(_rendition), do: gettext("Encoding")

  attr :has_changes, :boolean, required: true
  attr :myself, :any, required: true

  defp publish_button(assigns) do
    ~H"""
    <div
      id="settings-publish"
      class={[
        "w-full h-[calc(4rem+1px)] p-3 border-t border-stone-700/40 bg-stone-900",
        !@has_changes && "hidden"
      ]}
      phx-click="publish"
      phx-target={@myself}
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
        <div class="flex-grow text-center mr-7">publish</div>
      </div>
    </div>
    """
  end

  attr :current_tab, :atom, required: true
  attr :myself, :any, required: true

  defp tab_navigation(assigns) do
    ~H"""
    <div
      id="video-settings-tab-navigation"
      class="relative flex-none w-full grid grid-cols-2 border-t py-2 pb-2.5 px-1.5 border-stone-700/40 bg-stone-900 overflow-hidden"
    >
      <.tab_button tab={:options} current={@current_tab} label="settings" myself={@myself}>
        <svg
          width="24"
          height="24"
          stroke-width="1"
          viewBox="0 0 24 24"
          fill="none"
          xmlns="http://www.w3.org/2000/svg"
        >
          <path
            d="M7 13C7.55228 13 8 12.5523 8 12C8 11.4477 7.55228 11 7 11C6.44772 11 6 11.4477 6 12C6 12.5523 6.44772 13 7 13Z"
            fill="currentColor"
            stroke="currentColor"
            stroke-linecap="round"
            stroke-linejoin="round"
          />
          <path
            d="M17 17H7C4.23858 17 2 14.7614 2 12C2 9.23858 4.23858 7 7 7H17C19.7614 7 22 9.23858 22 12C22 14.7614 19.7614 17 17 17Z"
            stroke="currentColor"
            stroke-width="1"
          />
        </svg>
      </.tab_button>
      <.tab_button tab={:info} current={@current_tab} label="info" myself={@myself}>
        <svg
          xmlns="http://www.w3.org/2000/svg"
          class="h-6 w-6"
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
          stroke-width="1"
        >
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            d="m11.25 11.25.041-.02a.75.75 0 0 1 1.063.852l-.708 2.836a.75.75 0 0 0 1.063.853l.041-.021M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Zm-9-3.75h.008v.008H12V8.25Z"
          />
        </svg>
      </.tab_button>
    </div>
    """
  end

  defp settings_tab_skeleton(assigns) do
    ~H"""
    <div class="pointer-events-none absolute inset-0 z-10 hidden bg-stone-900/85 px-3 py-3 phx-click-loading:block">
      <div class="mb-5 h-8 w-full rounded-sm bg-stone-800/80 animate-pulse"></div>

      <div class="space-y-3">
        <div>
          <div class="mb-2 h-3 w-28 rounded-sm bg-stone-800/80 animate-pulse"></div>
          <div class="grid grid-cols-2 gap-2">
            <div class="h-10 rounded-sm bg-stone-800/70 animate-pulse"></div>
            <div class="h-10 rounded-sm bg-stone-800/60 animate-pulse"></div>
          </div>
        </div>

        <div>
          <div class="mb-2 h-3 w-40 rounded-sm bg-stone-800/80 animate-pulse"></div>
          <div class="grid grid-cols-2 gap-2">
            <div class="h-10 rounded-sm bg-stone-800/70 animate-pulse"></div>
            <div class="h-10 rounded-sm bg-stone-800/60 animate-pulse"></div>
          </div>
        </div>

        <div>
          <div class="mb-2 h-3 w-24 rounded-sm bg-stone-800/80 animate-pulse"></div>
          <div class="grid grid-cols-2 gap-2">
            <div class="h-10 rounded-sm bg-stone-800/70 animate-pulse"></div>
            <div class="h-10 rounded-sm bg-stone-800/60 animate-pulse"></div>
          </div>
        </div>
      </div>

      <div class="mt-6 space-y-2">
        <div class="h-3 w-32 rounded-sm bg-stone-800/70 animate-pulse"></div>
        <div class="h-3 w-44 rounded-sm bg-stone-800/60 animate-pulse"></div>
        <div class="h-3 w-36 rounded-sm bg-stone-800/70 animate-pulse"></div>
      </div>
    </div>
    """
  end

  defp renditions_of_group(renditions, types) do
    Enum.filter(renditions, &(Map.get(&1, :type) in types))
  end

  defp grouped_rows_for("audio", []), do: []

  defp grouped_rows_for("audio", renditions) do
    [
      %{
        progress: grouped_progress(renditions),
        status: grouped_status(renditions),
        size: nil,
        label: gettext("Original"),
        badges: grouped_badges(renditions)
      }
    ]
  end

  defp grouped_rows_for("videos", renditions) do
    renditions
    |> Enum.filter(&(Map.get(&1, :size_key) in ~w(sd hd fhd qhd uhd)))
    |> then(&grouped_rows_for("other", &1))
  end

  defp grouped_rows_for(_label, renditions) do
    renditions
    |> Enum.group_by(&Map.get(&1, :size_key))
    |> Enum.sort_by(fn {size_key, _group} -> size_index(size_key) end)
    |> Enum.map(fn {_size_key, grouped} ->
      %{
        progress: grouped_progress(grouped),
        status: grouped_status(grouped),
        size: grouped |> List.first() |> Map.get(:size),
        label: nil,
        badges: grouped_badges(grouped)
      }
    end)
  end

  defp grouped_progress(renditions) do
    cond do
      Enum.all?(renditions, &completed_rendition?/1) ->
        100

      Enum.any?(renditions, &active_rendition?/1) ->
        renditions
        |> Enum.map(&Map.get(&1, :progress))
        |> Enum.filter(&(is_integer(&1) and &1 > 0 and &1 < 100))
        |> Enum.max(fn -> 50 end)

      true ->
        0
    end
  end

  defp grouped_status(renditions) do
    cond do
      Enum.any?(renditions, &(Map.get(&1, :status) == "failed")) -> "failed"
      Enum.all?(renditions, &completed_rendition?/1) -> "succeeded"
      Enum.any?(renditions, &active_rendition?/1) -> "executing"
      true -> "queued"
    end
  end

  defp completed_rendition?(rendition), do: Map.get(rendition, :progress) == 100

  defp active_rendition?(rendition) do
    progress = Map.get(rendition, :progress)

    Map.get(rendition, :status) == "executing" ||
      (is_integer(progress) and progress > 0 and progress < 100)
  end

  defp audio_group_rows(audio_tracks, renditions) do
    audio_renditions = Enum.filter(renditions, &(Map.get(&1, :type) == "audio"))

    completed_container_badges =
      audio_renditions
      |> Enum.filter(&(&1.progress && &1.progress >= 100))
      |> Enum.map(& &1.container_label)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort_by(&format_index/1)

    audio_tracks
    |> List.wrap()
    |> Enum.map(fn track ->
      base_badges =
        track
        |> audio_track_format()
        |> case do
          nil -> []
          format -> [format]
        end

      label = Map.get(track, :label) || gettext("Audio track")

      %{
        progress: audio_track_progress(audio_renditions),
        status: audio_track_status(audio_renditions),
        size: nil,
        label: label,
        badges:
          (completed_container_badges ++
             Enum.reject(base_badges, &(&1 in completed_container_badges)))
          |> Enum.uniq()
          |> Enum.sort_by(&format_index/1)
      }
    end)
  end

  defp subtitle_group_rows(subtitles, renditions) do
    planned_rows =
      renditions
      |> Enum.map(fn rendition ->
        key = Map.get(rendition, :language) || Map.get(rendition, :id)

        {key,
         %{
           progress: rendition.progress,
           status: rendition.status,
           size: nil,
           label: Map.get(rendition, :label) || gettext("Subtitles"),
           badges: [Map.get(rendition, :container_label) || "VTT"]
         }}
      end)
      |> Map.new()

    subtitles
    |> List.wrap()
    |> Enum.reduce(planned_rows, fn subtitle, rows ->
      language = Map.get(subtitle, :language)
      label = Map.get(subtitle, :label) || Languages.spoken_language(language) || language

      Map.put(rows, language || Map.get(subtitle, :id), %{
        progress: 100,
        status: "succeeded",
        size: nil,
        label: label || gettext("Subtitles"),
        badges: ["VTT"]
      })
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.label)
  end

  defp audio_track_format(%{codec: codec}) when is_binary(codec) and codec != "", do: codec

  defp audio_track_format(%{filename: filename}) when is_binary(filename) do
    case Path.extname(filename) do
      "." <> ext -> String.upcase(ext)
      _ -> nil
    end
  end

  defp audio_track_format(_track), do: nil

  defp audio_track_progress([]), do: nil

  defp audio_track_progress(renditions),
    do: renditions |> Enum.map(& &1.progress) |> Enum.max(fn -> 100 end)

  defp audio_track_status(renditions) do
    if Enum.any?(renditions, &(&1.status == "failed")), do: "failed", else: nil
  end

  defp language_options do
    [{"Select language", ""} | Languages.spoken_languages()]
  end

  defp active_audio_upload_target?(%{audio_track_id: id}, %{id: id}), do: true
  defp active_audio_upload_target?(_, _), do: false

  defp active_subtitle_upload_target?(%{subtitle_id: id}, %{id: id}), do: true
  defp active_subtitle_upload_target?(_, _), do: false

  defp subtitle_download_filename(%{language: language}) when is_binary(language) do
    filename =
      language
      |> String.trim()
      |> String.replace(~r/[^A-Za-z0-9_-]/, "_")

    case filename do
      "" -> "subtitle.vtt"
      value -> "#{value}.vtt"
    end
  end

  defp subtitle_download_filename(_subtitle), do: "subtitle.vtt"

  defp pending_audio_track_upload(socket) do
    form = socket.assigns.audio_track_form || %{}

    %{
      id: Map.get(form, :audio_track_id),
      mode: Map.get(form, :mode, :new),
      label: blank_to_nil(Map.get(form, :label)) || gettext("Audio track"),
      language: blank_to_nil(Map.get(form, :language))
    }
  end

  defp pending_subtitle_upload(socket) do
    form = socket.assigns.subtitle_form || %{}

    %{
      id: Map.get(form, :subtitle_id),
      mode: Map.get(form, :mode, :new),
      language: blank_to_nil(Map.get(form, :language))
    }
  end

  defp processing_audio_track?(%{id: id}, %{id: id}) when not is_nil(id), do: true
  defp processing_audio_track?(_, _), do: false

  defp processing_subtitle?(%{id: id}, %{id: id}) when not is_nil(id), do: true
  defp processing_subtitle?(_, _), do: false

  defp new_processing_media?(%{id: nil}), do: true
  defp new_processing_media?(%{} = pending), do: not Map.has_key?(pending, :id)
  defp new_processing_media?(_), do: false

  defp show_audio_tracks_section?(video, form, processing_upload?) do
    (video && video_status_ready?(Map.get(video, :status))) || not is_nil(form) ||
      processing_upload?
  end

  defp show_subtitles_section?(video, form, processing_upload?) do
    (video && video_status_ready?(Map.get(video, :status))) || not is_nil(form) ||
      processing_upload?
  end

  defp video_status_ready?(status) when status in ["ready", "playable"], do: true
  defp video_status_ready?(_status), do: false

  defp poster_upload_entry(%{poster_image: %{entries: [entry | _]}}), do: entry
  defp poster_upload_entry(_), do: nil

  defp poster_upload_preview(%{external_poster: external_poster}, video)
       when is_binary(external_poster) and external_poster != "" do
    case video do
      %{preview_poster: preview_poster} when is_binary(preview_poster) and preview_poster != "" ->
        preview_poster

      _ ->
        external_poster
    end
  end

  defp poster_upload_preview(_settings, _video), do: nil

  defp poster_upload_error(uploads, entry) do
    case poster_upload_errors(uploads, entry) do
      [first | _] -> upload_error_to_string(first)
      _ -> gettext("Poster upload failed.")
    end
  end

  defp poster_upload_errors(%{poster_image: upload}, entry), do: upload_errors(upload, entry)
  defp poster_upload_errors(_, _), do: []

  defp upload_error_to_string(:too_large), do: gettext("Poster file is too large.")
  defp upload_error_to_string(:too_many_files), do: gettext("Please choose a single poster file.")

  defp upload_error_to_string(:not_accepted),
    do: gettext("Please choose a JPG, JPEG, or PNG image.")

  defp upload_error_to_string(other) when is_binary(other), do: other
  defp upload_error_to_string(other), do: inspect(other)

  defp scoped_audio_track(socket, id) do
    Assets.get_audio_track_for_embed(id, socket.assigns.embed)
  end

  defp scoped_subtitle(socket, id) do
    Assets.get_subtitle_for_embed(id, socket.assigns.embed)
  end

  defp refresh_audio_outputs(socket) do
    case Assets.refresh_audio_outputs(socket.assigns.embed) do
      :ok ->
        notify_parent(:audio_tracks_updated)
        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  defp update_audio_track_if_changed(socket, id, field, value) do
    case scoped_audio_track(socket, id) do
      nil -> {:noreply, socket}
      track -> maybe_update_audio_track_field(socket, track, field, value)
    end
  end

  defp maybe_update_audio_track_field(socket, track, field, value) do
    if Map.get(track, field) == value do
      {:noreply, socket}
    else
      persist_audio_track_field(socket, track, field, value)
    end
  end

  defp persist_audio_track_field(socket, track, field, value) do
    case Assets.update_audio_track(track, %{field => value}) do
      {:ok, _track} -> refresh_audio_outputs(socket)
      {:error, _reason} -> {:noreply, socket}
    end
  end

  defp poster_upload_style(url) when is_binary(url) and url != "" do
    "background-image: url(#{url});"
  end

  defp poster_upload_style(_), do: nil

  defp renditions_for_images(renditions) do
    renditions
    |> Enum.group_by(&Map.get(&1, :type))
    |> Enum.map(fn {type, grouped} ->
      {progress, status} = image_group_state(grouped)
      {{type, progress, status}, grouped}
    end)
    |> Enum.sort_by(fn {{type, _progress, _status}, _group} -> image_type_index(type) end)
  end

  defp image_group_state(renditions) do
    case Enum.find(renditions, &(Map.get(&1, :codec) == "JPG")) do
      nil -> {grouped_progress(renditions), grouped_status(renditions)}
      rendition -> {Map.get(rendition, :progress), Map.get(rendition, :status)}
    end
  end

  defp image_badges(renditions) do
    renditions
    |> Enum.map(& &1.codec)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort_by(&format_index/1)
  end

  defp grouped_badges(renditions) do
    renditions
    |> Enum.group_by(&Map.get(&1, :container_label), &Map.get(&1, :codec))
    |> Enum.flat_map(fn
      {"HLS", _codecs} -> ["HLS"]
      {_container, codecs} -> codecs |> Enum.reject(&is_nil/1) |> Enum.uniq()
    end)
    |> Enum.uniq()
    |> Enum.sort_by(&format_index/1)
  end

  defp image_type_label("poster"), do: "Poster"
  defp image_type_label("thumbnail"), do: "Thumbnail"
  defp image_type_label("placeholder"), do: "Placeholder"
  defp image_type_label("storyboard"), do: "Storyboard"
  defp image_type_label("custom_thumbnail"), do: "Custom thumbnail"

  defp image_type_label(type) when is_binary(type),
    do: type |> String.replace("_", " ") |> String.capitalize()

  defp image_type_label(_), do: "Image"

  defp size_index("sd"), do: 0
  defp size_index("hd"), do: 1
  defp size_index("fhd"), do: 2
  defp size_index("qhd"), do: 3
  defp size_index("uhd"), do: 4
  defp size_index(_), do: 99

  defp format_index("JPG"), do: 0
  defp format_index("WebP"), do: 1
  defp format_index("AVIF"), do: 2
  defp format_index("HLS"), do: 3
  defp format_index("H.264"), do: 4
  defp format_index("H.265"), do: 5
  defp format_index("AV1"), do: 6
  defp format_index("WEBM"), do: 7
  defp format_index("MP4"), do: 8
  defp format_index("MP3"), do: 9
  defp format_index("AAC"), do: 10
  defp format_index(_), do: 99

  defp image_type_index("poster"), do: 0
  defp image_type_index("thumbnail"), do: 1
  defp image_type_index("placeholder"), do: 2
  defp image_type_index("storyboard"), do: 3
  defp image_type_index("custom_thumbnail"), do: 4
  defp image_type_index(_), do: 99

  attr :tab, :atom, required: true
  attr :current, :atom, required: true
  attr :label, :string, required: true
  attr :myself, :any, required: true
  slot :inner_block, required: true

  defp tab_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={
        JS.push("change_tab",
          target: @myself,
          loading: "#video-settings-tab-content",
          value: %{tab: @tab}
        )
      }
      phx-value-tab={@tab}
      class={[
        "flex flex-col items-center justify-center text-sm cursor-pointer transition-colors duration-150 ease-out",
        @current == @tab && "text-blue-600",
        @current != @tab && "text-stone-500 hover:text-stone-400"
      ]}
    >
      <span class="inline-flex h-6 items-center justify-center">
        {render_slot(@inner_block)}
      </span>
      <div class="mt-0.5">{@label}</div>
    </button>
    """
  end

  defp maybe_allow_poster_upload(socket) do
    uploads = socket.assigns[:uploads] || %{}

    if Map.has_key?(uploads, :poster_image) do
      socket
    else
      allow_upload(socket, :poster_image,
        accept: ~w(.jpg .jpeg .png),
        max_entries: 1,
        external: &presign_upload/2,
        progress: &handle_progress/3,
        auto_upload: true,
        max_file_size: 10_485_760
      )
    end
  end

  defp maybe_allow_audio_track_upload(socket) do
    uploads = socket.assigns[:uploads] || %{}

    if Map.has_key?(uploads, :audio_track_file) do
      socket
    else
      allow_upload(socket, :audio_track_file,
        accept: ~w(.mp3),
        max_entries: 1,
        external: &presign_audio_track_upload/2,
        progress: &handle_progress/3,
        auto_upload: true,
        max_file_size: 104_857_600
      )
    end
  end

  defp maybe_allow_subtitle_upload(socket) do
    uploads = socket.assigns[:uploads] || %{}

    if Map.has_key?(uploads, :subtitle_file) do
      socket
    else
      allow_upload(socket, :subtitle_file,
        accept: ~w(.vtt),
        max_entries: 1,
        external: &presign_subtitle_upload/2,
        progress: &handle_progress/3,
        auto_upload: true,
        max_file_size: 10_485_760
      )
    end
  end

  defp push_settings(socket, settings) do
    notify_parent({:settings_changed, settings})

    socket
    |> assign(:settings, settings)
    |> assign(:has_changes, settings != socket.assigns.persisted_settings)
  end

  defp notify_parent(message), do: send(self(), {__MODULE__, message})

  defp upload_token(%Space{} = space, %Embed{} = embed, current_user, access_context) do
    with true <- MaveCoreWeb.SpaceLiveAuth.can_access_space?(current_user, space, access_context),
         {:ok, key} <- Spaces.ensure_internal_key(space, :dashboard_uploads) do
      Token.sign_api_key(
        key,
        SettingsSerializer.public_embed_id(space, embed),
        admin_maintenance_bypass: Maintenance.internal_user?(current_user)
      )
    else
      _ -> nil
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp maybe_put_string(settings, _field, nil), do: settings
  defp maybe_put_string(settings, field, value), do: Map.put(settings, field, value)

  defp maybe_put_integer(settings, _field, nil), do: settings

  defp maybe_put_integer(settings, field, value),
    do: Map.put(settings, field, parse_integer(value, Map.get(settings, field) || 0))

  defp maybe_put_float(settings, _field, nil), do: settings

  defp maybe_put_float(settings, field, value),
    do: Map.put(settings, field, parse_float(value, Map.get(settings, field) || 0.0))

  defp parse_integer(value, _fallback) when is_integer(value), do: value

  defp parse_integer(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> fallback
    end
  end

  defp parse_integer(_, fallback), do: fallback

  defp parse_float(value, _fallback) when is_float(value), do: value
  defp parse_float(value, _fallback) when is_integer(value), do: value * 1.0

  defp parse_float(value, fallback) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed
      _ -> fallback
    end
  end

  defp parse_float(_, fallback), do: fallback

  defp normalize_poster_time(settings) do
    hours = Map.get(settings, :poster_time_hour, 0) || 0
    minutes = Map.get(settings, :poster_time_minute, 0) || 0
    seconds = Map.get(settings, :poster_time_second, 0.0) || 0.0

    total_seconds = max(hours * 3600 + minutes * 60 + seconds, 0.0)
    whole_hours = trunc(total_seconds / 3600)
    whole_minutes = trunc(total_seconds / 60) |> rem(60)

    seconds_part =
      (total_seconds - whole_hours * 3600 - whole_minutes * 60)
      |> Kernel.*(1.0)
      |> Float.round(2)

    settings
    |> Map.put(:poster_time_seconds, total_seconds)
    |> Map.put(:poster_time_hour, whole_hours)
    |> Map.put(:poster_time_minute, whole_minutes)
    |> Map.put(:poster_time_second, normalize_seconds_part(seconds_part))
  end

  defp thumbnail_preview_available?(%{thumbnail_preview: %{preferred_src: src}})
       when is_binary(src) and src != "",
       do: true

  defp thumbnail_preview_available?(%{thumbnail_preview: %{fallback_src: src}})
       when is_binary(src) and src != "",
       do: true

  defp thumbnail_preview_available?(_), do: false

  defp normalize_seconds(value) when is_float(value), do: Float.round(value, 3)
  defp normalize_seconds(value) when is_integer(value), do: value
  defp normalize_seconds(_), do: 0.0

  defp normalize_seconds_part(seconds) when is_float(seconds) do
    if seconds == Float.floor(seconds) do
      trunc(seconds)
    else
      seconds
    end
  end

  defp normalize_seconds_part(seconds), do: seconds

  defp normalize_color(nil), do: nil
  defp normalize_color(""), do: nil
  defp normalize_color(color), do: String.trim_leading(color, "#")

  defp time_value(value) when is_float(value) do
    if value == Float.floor(value) do
      Integer.to_string(trunc(value))
    else
      :erlang.float_to_binary(value, decimals: 2)
      |> String.trim_trailing("0")
      |> String.trim_trailing(".")
    end
  end

  defp time_value(value) when is_integer(value), do: Integer.to_string(value)
  defp time_value(_), do: "0"

  defp format_file_size(size) when is_integer(size) and size >= 1_000_000_000,
    do: Float.round(size / 1_000_000_000, 1)

  defp format_file_size(size) when is_integer(size) and size >= 1_000_000,
    do: Float.round(size / 1_000_000, 1)

  defp format_file_size(size) when is_integer(size) and size >= 1_000, do: round(size / 1_000)
  defp format_file_size(size) when is_integer(size), do: size
  defp format_file_size(_), do: 0

  defp file_size_unit(size) when is_integer(size) and size >= 1_000_000_000, do: "GB"
  defp file_size_unit(size) when is_integer(size) and size >= 1_000_000, do: "MB"
  defp file_size_unit(size) when is_integer(size) and size >= 1_000, do: "KB"
  defp file_size_unit(_), do: "B"
end
