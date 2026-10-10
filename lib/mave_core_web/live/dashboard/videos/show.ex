defmodule MaveCoreWeb.Dashboard.Videos.Show do
  @moduledoc false

  use MaveCoreWeb, :live_view
  import MaveCoreWeb.DashboardComponents, except: [icon: 1]

  alias MaveCore.Embeds
  alias MaveCore.Embeds.Embed
  alias MaveCore.Embeds.Events, as: EmbedEvents
  alias MaveCore.Embeds.SettingsSerializer
  alias MaveCore.Flow.Diagnostics
  alias MaveCore.Playback.EmbedCode
  alias MaveCore.Spaces
  alias MaveCore.Uploads.Token
  alias MaveCore.UsageLimits
  alias MaveCoreWeb.Dashboard.Videos.VideoSettingsComponent
  alias MaveCoreWeb.DashboardRoutes
  alias MaveCoreWeb.Formatter
  alias MaveCoreWeb.Plugs.Maintenance

  @default_processing_player_settle_ms 2_500
  @processing_progress_refresh_interval_ms 1_000
  @max_dropoff_chart_points 30
  @poster_reload_attempts 120
  @poster_reload_interval_ms 1_000
  @uploaded_video_reload_attempts 12
  @uploaded_video_reload_interval_ms 500

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:mode, :video)
     |> assign(:resource_embed, nil)
     |> assign(:video_id, nil)
     |> assign(:video, nil)
     |> assign(:folder, nil)
     |> assign(:folders, [])
     |> assign(:videos, [])
     |> assign(:page, 1)
     |> assign(:total_pages, 0)
     |> assign(:engagement, "[]")
     |> assign(:page_title, gettext("Video Details"))
     |> assign(:code_preview, :script)
     |> assign(:confirmation_needed, false)
     |> assign(:pending_action, nil)
     |> assign(:settings_open, true)
     |> assign(:current_tab, :all)
     |> assign(:route_scope, :unscoped)
     |> assign(:persisted_settings, nil)
     |> assign(:player_dom_id, nil)
     |> assign(:video_ready, false)
     |> assign(:video_processing, false)
     |> assign(:processing_player_visible_after_ms, nil)
     |> assign(:processing_progress_refresh_pending, false)
     |> assign(:replace_mode, false)
     |> assign(:upload_token, nil)
     |> assign(:component_src, SettingsSerializer.component_src())
     |> assign(:folder_paths, [])
     |> assign(:poster_upload, nil)
     |> assign(:processing_uploaded_audio_track, nil)
     |> assign(:processing_uploaded_audio_track_signature, nil)
     |> assign(:processing_uploaded_subtitle, nil)
     |> assign(:processing_uploaded_subtitle_signature, nil)
     |> assign(:embed_subscription, nil)
     |> assign(:embed_subscription_active, false)
     |> assign(:embed_list_subscription, nil)
     |> assign(:embed_list_subscription_active, false)
     |> assign(:can_create_video, true)
     |> assign(:video_creation_notice, nil)
     |> assign(:video_creation_help, nil)}
  end

  @impl true
  def handle_params(%{"id" => id} = params, _url, socket) do
    tab =
      case params["tab"] do
        "archive" -> :archive
        _ -> :all
      end

    page = parse_page(params["page"])

    {:noreply,
     socket
     |> assign(:route_scope, route_scope(params))
     |> load_resource(id, tab, page)}
  end

  @impl true
  def handle_info({VideoSettingsComponent, {:settings_changed, settings}}, socket) do
    {:noreply, assign_video_preview(socket, settings)}
  end

  def handle_info(
        {VideoSettingsComponent, {:retry_flow_step, flow_run_id, step_id}},
        %{assigns: %{resource_embed: %Embed{} = current_embed}} = socket
      ) do
    case Diagnostics.retry_step_for_embed(
           socket.assigns.current_space,
           current_embed,
           flow_run_id,
           step_id
         ) do
      {:ok, _run} ->
        case Embeds.resolve_dashboard_embed(socket.assigns.current_space, current_embed.id) do
          {:ok, %Embed{} = embed} ->
            {:noreply,
             socket
             |> assign_video_by_state(embed, update_mode: :event)
             |> put_flash(:info, gettext("Flow step retried"))}

          _ ->
            {:noreply, put_flash(socket, :info, gettext("Flow step retried"))}
        end

      {:error, :subtree_in_progress} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("This step cannot be retried while downstream work is still running.")
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not retry flow step"))}
    end
  end

  def handle_info(
        {:embed_updated,
         %{
           "space_id" => space_id,
           "embed_id" => embed_id,
           "progress" => progress
         }},
        %{assigns: %{current_space: %{id: space_id}, resource_embed: %{id: embed_id}}} = socket
      )
      when is_number(progress) do
    {:noreply, schedule_processing_progress_refresh(socket, space_id, embed_id)}
  end

  def handle_info(
        {:embed_updated, %{"space_id" => space_id, "embed_id" => embed_id}},
        %{assigns: %{current_space: %{id: space_id}, resource_embed: %{id: embed_id}}} = socket
      ) do
    case Embeds.resolve_dashboard_embed(socket.assigns.current_space, embed_id) do
      {:ok, %Embed{} = embed} ->
        {:noreply, assign_video_by_state(socket, embed, update_mode: :event)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(
        {:refresh_processing_progress, space_id, embed_id},
        %{assigns: %{current_space: %{id: space_id}, resource_embed: %{id: embed_id}}} = socket
      ) do
    socket = assign(socket, :processing_progress_refresh_pending, false)

    case Embeds.resolve_dashboard_embed(socket.assigns.current_space, embed_id) do
      {:ok, %Embed{} = embed} ->
        {:noreply, assign_video_by_state(socket, embed, update_mode: :progress)}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_info({:refresh_processing_progress, _space_id, _embed_id}, socket) do
    {:noreply, assign(socket, :processing_progress_refresh_pending, false)}
  end

  def handle_info(
        {:space_embeds_updated, %{"space_id" => space_id}},
        %{
          assigns: %{
            current_space: %{id: space_id},
            mode: :collection,
            resource_embed: %Embed{} = folder
          }
        } =
          socket
      ) do
    {:noreply, load_resource(socket, folder.id, socket.assigns.current_tab, socket.assigns.page)}
  end

  def handle_info({VideoSettingsComponent, {:settings_published, %Embed{} = embed}}, socket) do
    {:noreply,
     socket
     |> assign_video_embed(embed)
     |> put_flash(:info, gettext("Settings published"))}
  end

  def handle_info({VideoSettingsComponent, :poster_upload_started}, socket) do
    {:noreply, start_poster_upload(socket)}
  end

  def handle_info({VideoSettingsComponent, :poster_uploaded}, socket) do
    socket = if socket.assigns.poster_upload, do: socket, else: start_poster_upload(socket)

    case socket.assigns.poster_upload do
      %{embed_id: embed_id, ref: ref} = upload ->
        send(self(), {:reload_poster, embed_id, ref, @poster_reload_attempts})
        {:noreply, assign(socket, :poster_upload, %{upload | stage: :processing})}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_info({VideoSettingsComponent, :audio_tracks_updated}, socket) do
    if socket.assigns.resource_embed do
      case Embeds.resolve_dashboard_embed(
             socket.assigns.current_space,
             socket.assigns.resource_embed.id
           ) do
        {:ok, %Embed{} = embed} ->
          {:noreply, assign_video_embed(socket, embed, force_player_refresh: true)}

        _ ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({VideoSettingsComponent, :audio_track_uploaded}, socket) do
    handle_info({VideoSettingsComponent, {:audio_track_uploaded, %{}}}, socket)
  end

  def handle_info({VideoSettingsComponent, {:audio_track_uploaded, pending_track}}, socket) do
    if socket.assigns.resource_embed do
      previous_signature = media_signature(socket.assigns.video, :audio_tracks)
      previous_count = socket.assigns.video |> Map.get(:audio_tracks, []) |> length()

      Process.send_after(
        self(),
        {:reload_audio_tracks, socket.assigns.resource_embed.id, previous_count, 10},
        350
      )

      socket =
        socket
        |> assign(:processing_uploaded_audio_track, pending_track || %{})
        |> assign(:processing_uploaded_audio_track_signature, previous_signature)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({VideoSettingsComponent, :subtitles_updated}, socket) do
    if socket.assigns.resource_embed do
      case Embeds.resolve_dashboard_embed(
             socket.assigns.current_space,
             socket.assigns.resource_embed.id
           ) do
        {:ok, %Embed{} = embed} ->
          {:noreply, assign_video_embed(socket, embed, force_player_refresh: true)}

        _ ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({VideoSettingsComponent, :subtitle_uploaded}, socket) do
    handle_info({VideoSettingsComponent, {:subtitle_uploaded, %{}}}, socket)
  end

  def handle_info({VideoSettingsComponent, {:subtitle_uploaded, pending_subtitle}}, socket) do
    if socket.assigns.resource_embed do
      previous_signature = media_signature(socket.assigns.video, :subtitles)
      previous_count = socket.assigns.video |> Map.get(:subtitles, []) |> length()

      Process.send_after(
        self(),
        {:reload_subtitles, socket.assigns.resource_embed.id, previous_count, 10},
        350
      )

      socket =
        socket
        |> assign(:processing_uploaded_subtitle, pending_subtitle || %{})
        |> assign(:processing_uploaded_subtitle_signature, previous_signature)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:processing_player_settle_elapsed, embed_id}, socket) do
    if (socket.assigns.mode == :video and socket.assigns.resource_embed) &&
         socket.assigns.resource_embed.id == embed_id do
      case Embeds.resolve_dashboard_embed(socket.assigns.current_space, embed_id) do
        {:ok, %Embed{} = embed} ->
          {:noreply, assign_video_by_state(socket, embed, update_mode: :event)}

        _ ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:reload_uploaded_video, embed_id, attempts_left}, socket) do
    case resolve_current_video_embed(socket, embed_id) do
      {:ok, %Embed{} = embed} ->
        if video_ready?(embed) do
          {:noreply, assign_video_embed(socket, embed)}
        else
          socket = assign_uploaded_video_state(socket, embed)

          maybe_schedule_reload(
            attempts_left,
            {:reload_uploaded_video, embed_id, attempts_left - 1},
            @uploaded_video_reload_interval_ms
          )

          {:noreply, socket}
        end

      :error ->
        {:noreply, socket}
    end
  end

  def handle_info({:reload_poster, embed_id, ref, attempts_left}, socket) do
    with %{embed_id: ^embed_id, ref: ^ref, stage: :processing} <- socket.assigns.poster_upload,
         {:ok, %Embed{} = embed} <- resolve_current_video_embed(socket, embed_id) do
      socket = assign_video_embed(socket, embed)

      cond do
        is_nil(socket.assigns.poster_upload) ->
          {:noreply, socket}

        attempts_left <= 0 ->
          {:noreply,
           socket
           |> assign(:poster_upload, nil)
           |> put_flash(
             :error,
             gettext("Poster processing could not be completed. Please try again.")
           )}

        true ->
          Process.send_after(
            self(),
            {:reload_poster, embed_id, ref, attempts_left - 1},
            @poster_reload_interval_ms
          )

          {:noreply, socket}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:reload_audio_tracks, embed_id, previous_count, attempts_left}, socket) do
    case resolve_current_video_embed(socket, embed_id) do
      {:ok, %Embed{} = embed} ->
        audio_count = dashboard_payload_count(socket, embed, :audio_tracks)
        audio_signature = dashboard_payload_signature(socket, embed, :audio_tracks)

        if audio_count > previous_count or
             uploaded_media_signature_changed?(
               socket,
               audio_signature,
               :processing_uploaded_audio_track,
               :processing_uploaded_audio_track_signature
             ) or attempts_left <= 0 do
          socket =
            socket
            |> assign_video_embed(embed, force_player_refresh: true)
            |> maybe_clear_exhausted_media_processing(
              attempts_left,
              :processing_uploaded_audio_track,
              :processing_uploaded_audio_track_signature
            )

          {:noreply, socket}
        else
          maybe_schedule_reload(
            attempts_left,
            {:reload_audio_tracks, embed_id, previous_count, attempts_left - 1},
            350
          )

          {:noreply, socket}
        end

      :error ->
        {:noreply, socket}
    end
  end

  def handle_info({:reload_subtitles, embed_id, previous_count, attempts_left}, socket) do
    case resolve_current_video_embed(socket, embed_id) do
      {:ok, %Embed{} = embed} ->
        subtitle_count = dashboard_payload_count(socket, embed, :subtitles)
        subtitle_signature = dashboard_payload_signature(socket, embed, :subtitles)

        if subtitle_count > previous_count or
             uploaded_media_signature_changed?(
               socket,
               subtitle_signature,
               :processing_uploaded_subtitle,
               :processing_uploaded_subtitle_signature
             ) or attempts_left <= 0 do
          socket =
            socket
            |> assign_video_embed(embed, force_player_refresh: true)
            |> maybe_clear_exhausted_media_processing(
              attempts_left,
              :processing_uploaded_subtitle,
              :processing_uploaded_subtitle_signature
            )

          {:noreply, socket}
        else
          maybe_schedule_reload(
            attempts_left,
            {:reload_subtitles, embed_id, previous_count, attempts_left - 1},
            350
          )

          {:noreply, socket}
        end

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event(
        "playback_session",
        _params,
        %{assigns: %{resource_embed: %Embed{} = embed}} = socket
      ) do
    session =
      if MaveCore.Playback.protected?(embed),
        do: MaveCore.Playback.dashboard_session(embed),
        else: nil

    {:reply, %{session: session, embed: socket.assigns.current_space.hash <> embed.hash}, socket}
  end

  def handle_event(
        "toggle_playback_visibility",
        _params,
        %{assigns: %{resource_embed: %Embed{} = embed}} = socket
      ) do
    visibility = if embed.playback_visibility == :private, do: :public, else: :private

    case MaveCore.Playback.request_visibility(embed, visibility) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:resource_embed, updated)
         |> put_flash(:info, gettext("Playback access is being updated."))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Playback access could not be updated."))}
    end
  end

  def handle_event("change_code_preview", %{"preview" => preview}, socket) do
    {:noreply, assign(socket, :code_preview, String.to_existing_atom(preview))}
  end

  def handle_event("upload_completed", _params, socket) do
    if socket.assigns.resource_embed do
      Process.send_after(
        self(),
        {:reload_uploaded_video, socket.assigns.resource_embed.id,
         @uploaded_video_reload_attempts},
        250
      )
    end

    {:noreply, socket}
  end

  def handle_event(
        "replace",
        _params,
        %{assigns: %{resource_embed: %Embed{type: :video} = embed}} = socket
      ) do
    {:noreply, assign_video_upload(socket, embed, replace_mode: true)}
  end

  def handle_event(
        "cancel_replace",
        _params,
        %{assigns: %{resource_embed: %Embed{type: :video} = embed}} = socket
      ) do
    socket =
      cond do
        video_ready?(embed) ->
          assign_video_embed(socket, embed)

        processing_view?(socket, embed) ->
          assign_video_processing(socket, embed)

        true ->
          assign_video_upload(socket, embed)
      end

    {:noreply, socket}
  end

  def handle_event("upload_error", %{"message" => message}, socket) do
    {:noreply, put_flash(socket, :error, message)}
  end

  def handle_event("upload_error", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("rename", %{"rename" => %{"name" => name}}, socket) do
    case Embeds.rename_embed(socket.assigns.resource_embed, name) do
      {:ok, %Embed{type: :video} = embed} ->
        {:noreply, assign_video_embed(socket, embed)}

      {:ok, %Embed{type: :collection} = embed} ->
        {:noreply, assign_folder_embed(socket, embed)}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  def handle_event("previous_page", _params, %{assigns: %{mode: :collection}} = socket) do
    {:noreply, push_patch(socket, to: folder_page_path(socket, max(socket.assigns.page - 1, 1)))}
  end

  def handle_event("previous_page", _params, socket), do: {:noreply, socket}

  def handle_event("next_page", _params, %{assigns: %{mode: :collection}} = socket) do
    next_page = min(socket.assigns.page + 1, max(socket.assigns.total_pages, 1))

    {:noreply, push_patch(socket, to: folder_page_path(socket, next_page))}
  end

  def handle_event("next_page", _params, socket), do: {:noreply, socket}

  def handle_event(
        "create_video",
        _params,
        %{assigns: %{mode: :collection, resource_embed: folder}} = socket
      ) do
    attrs =
      %{}
      |> maybe_archive_attrs(socket.assigns.current_tab)
      |> Map.put(:parent_folder_id, folder.id)

    case Embeds.create_video_embed(socket.assigns.current_space, attrs) do
      {:ok, embed} ->
        {:noreply,
         push_navigate(socket,
           to:
             video_path(
               socket.assigns.current_space,
               Embeds.dashboard_embed_id(embed),
               socket.assigns.current_tab,
               socket.assigns.route_scope
             )
         )}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign_video_creation_status()
         |> put_flash(:error, video_creation_error(reason))}
    end
  end

  def handle_event(
        "create_folder",
        _params,
        %{assigns: %{mode: :collection, resource_embed: folder}} = socket
      ) do
    attrs =
      %{}
      |> maybe_archive_attrs(socket.assigns.current_tab)
      |> Map.put(:parent_folder_id, folder.id)

    case Embeds.create_folder_embed(socket.assigns.current_space, attrs) do
      {:ok, embed} ->
        {:noreply,
         push_navigate(socket,
           to:
             video_path(
               socket.assigns.current_space,
               Embeds.dashboard_embed_id(embed),
               socket.assigns.current_tab,
               socket.assigns.route_scope
             )
         )}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Could not create folder"))}
    end
  end

  def handle_event("drop_embed", %{"id" => id} = params, socket) do
    with {:ok, embed} <- Embeds.resolve_dashboard_embed(socket.assigns.current_space, id),
         {:ok, target_folder} <- resolve_drop_target(socket.assigns.current_space, params),
         {:ok, _moved_embed} <- Embeds.move_embed(embed, target_folder) do
      {:noreply,
       socket
       |> load_resource(
         socket.assigns.resource_embed.id,
         socket.assigns.current_tab,
         socket.assigns.page
       )
       |> put_flash(:info, gettext("Item moved"))}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not move item"))}
    end
  end

  def handle_event("archive", _params, socket) do
    {:noreply,
     socket
     |> assign(:pending_action, :archive)
     |> assign(:confirmation_needed, true)}
  end

  def handle_event("delete", _params, socket) do
    {:noreply,
     socket
     |> assign(:pending_action, :delete)
     |> assign(:confirmation_needed, true)}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply,
     socket
     |> assign(:confirmation_needed, false)
     |> assign(:pending_action, nil)}
  end

  def handle_event("confirm", _params, %{assigns: %{pending_action: :delete}} = socket) do
    case Embeds.delete_embed(socket.assigns.resource_embed) do
      {:ok, %Embed{type: :collection}} ->
        {:noreply,
         socket
         |> push_navigate(
           to:
             videos_path(
               socket.assigns.current_space,
               socket.assigns.current_tab,
               socket.assigns.route_scope
             )
         )
         |> put_flash(:info, gettext("Folder deleted"))}

      {:ok, _embed} ->
        {:noreply,
         socket
         |> push_navigate(
           to:
             videos_path(
               socket.assigns.current_space,
               socket.assigns.current_tab,
               socket.assigns.route_scope
             )
         )
         |> put_flash(:info, gettext("Video deleted"))}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:confirmation_needed, false)
         |> assign(:pending_action, nil)
         |> put_flash(:error, gettext("Could not delete this item"))}
    end
  end

  def handle_event("confirm", _params, %{assigns: %{pending_action: :archive}} = socket) do
    case Embeds.archive_embed(socket.assigns.resource_embed) do
      {:ok, embed} ->
        message =
          cond do
            embed.type == :collection and embed.archived -> gettext("Folder archived")
            embed.type == :collection -> gettext("Folder unarchived")
            embed.archived -> gettext("Video archived")
            true -> gettext("Video unarchived")
          end

        {:noreply,
         socket
         |> push_navigate(
           to:
             videos_path(
               socket.assigns.current_space,
               socket.assigns.current_tab,
               socket.assigns.route_scope
             )
         )
         |> put_flash(:info, message)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:confirmation_needed, false)
         |> assign(:pending_action, nil)
         |> put_flash(:error, gettext("Could not update this item"))}
    end
  end

  def handle_event("toggle_settings", _params, socket) do
    {:noreply, assign(socket, :settings_open, !socket.assigns.settings_open)}
  end

  defp format_number(num), do: Formatter.format_number(num)

  defp load_resource(socket, id, tab, page) do
    case Embeds.resolve_dashboard_embed(socket.assigns.current_space, id) do
      {:ok, %Embed{type: :collection} = folder_embed} ->
        socket =
          socket
          |> maybe_track_embed_subscription(nil)
          |> maybe_track_embed_list_subscription()

        %{folders: folders, videos: videos, page: current_page, total_pages: total_pages} =
          Embeds.list_folder_items(socket.assigns.current_space, folder_embed, page: page)

        socket
        |> assign(:current_tab, tab)
        |> assign(:mode, :collection)
        |> assign(:resource_embed, folder_embed)
        |> assign(:page_title, folder_name(folder_embed))
        |> assign(:video_id, id)
        |> assign(:folder, %{
          id: Embeds.dashboard_embed_id(folder_embed),
          public_id:
            SettingsSerializer.public_embed_id(socket.assigns.current_space, folder_embed),
          name: folder_name(folder_embed),
          archived: folder_embed.archived
        })
        |> assign(
          :folder_paths,
          folder_paths(
            socket.assigns.current_space,
            folder_embed,
            tab,
            socket.assigns.route_scope
          )
        )
        |> assign(:folders, folders)
        |> assign(:videos, videos)
        |> assign(:page, current_page)
        |> assign(:total_pages, total_pages)
        |> assign(:video, nil)
        |> assign(:engagement, "[]")
        |> assign(:persisted_settings, nil)
        |> assign(:player_dom_id, nil)
        |> assign(:confirmation_needed, false)
        |> assign(:pending_action, nil)
        |> assign(:replace_mode, false)
        |> assign(:settings_open, false)
        |> assign_video_creation_status()

      {:ok, %Embed{type: :video} = video_embed} ->
        socket =
          socket
          |> assign(:current_tab, tab)
          |> assign(:confirmation_needed, false)
          |> assign(:pending_action, nil)
          |> assign(:folder_paths, [])
          |> unsubscribe_embed_list(socket.assigns[:embed_list_subscription])
          |> maybe_track_embed_subscription(video_embed)

        assign_video_by_state(socket, video_embed)

      _ ->
        socket =
          socket
          |> maybe_track_embed_subscription(nil)
          |> unsubscribe_embed_list(socket.assigns[:embed_list_subscription])

        socket
        |> assign(:current_tab, tab)
        |> put_flash(:info, gettext("This video does not exist"))
        |> push_navigate(
          to: videos_path(socket.assigns.current_space, tab, socket.assigns.route_scope)
        )
    end
  end

  defp assign_video_by_state(socket, %Embed{} = video_embed, opts \\ []) do
    update_mode = Keyword.get(opts, :update_mode, :default)

    cond do
      video_ready?(video_embed) ->
        assign_video_embed(socket, video_embed)

      update_mode == :event and latched_processing_player?(socket, video_embed) ->
        assign_video_processing(socket, video_embed)

      update_mode == :progress and latched_processing_player?(socket, video_embed) ->
        assign_video_processing(socket, video_embed, reuse_analytics: true)

      processing_view?(socket, video_embed) ->
        assign_video_processing(
          socket,
          video_embed,
          reuse_analytics: update_mode == :progress
        )

      true ->
        assign_video_upload(socket, video_embed)
    end
  end

  defp maybe_track_embed_subscription(socket, %Embed{} = embed) do
    next = {socket.assigns.current_space.id, embed.id}
    current = socket.assigns[:embed_subscription]
    active? = socket.assigns[:embed_subscription_active]

    cond do
      current == next and active? ->
        socket

      current == next ->
        subscribe_embed(socket, next)

      true ->
        socket
        |> unsubscribe_embed(current)
        |> subscribe_embed(next)
    end
  end

  defp maybe_track_embed_subscription(socket, nil) do
    socket
    |> unsubscribe_embed(socket.assigns[:embed_subscription])
    |> assign(:embed_subscription, nil)
    |> assign(:embed_subscription_active, false)
  end

  defp subscribe_embed(socket, {space_id, embed_id}) do
    EmbedEvents.subscribe(space_id, embed_id)

    socket
    |> assign(:embed_subscription, {space_id, embed_id})
    |> assign(:embed_subscription_active, true)
  end

  defp unsubscribe_embed(socket, {space_id, embed_id}) do
    EmbedEvents.unsubscribe(space_id, embed_id)

    assign(socket, :embed_subscription_active, false)
  end

  defp unsubscribe_embed(socket, _), do: socket

  defp maybe_track_embed_list_subscription(socket) do
    next = socket.assigns.current_space.id
    current = socket.assigns[:embed_list_subscription]
    active? = socket.assigns[:embed_list_subscription_active]

    cond do
      not connected?(socket) ->
        socket

      current == next and active? ->
        socket

      current == next ->
        subscribe_embed_list(socket, next)

      true ->
        socket
        |> unsubscribe_embed_list(current)
        |> subscribe_embed_list(next)
    end
  end

  defp subscribe_embed_list(socket, space_id) do
    EmbedEvents.subscribe_space(space_id)

    socket
    |> assign(:embed_list_subscription, space_id)
    |> assign(:embed_list_subscription_active, true)
  end

  defp unsubscribe_embed_list(socket, space_id) when is_binary(space_id) do
    EmbedEvents.unsubscribe_space(space_id)

    assign(socket, :embed_list_subscription_active, false)
  end

  defp unsubscribe_embed_list(socket, _space_id), do: socket

  defp assign_video_embed(socket, %Embed{} = video_embed, opts \\ []) do
    video =
      Embeds.get_preloaded_video_dashboard_payload(socket.assigns.current_space, video_embed)

    force_player_refresh? = Keyword.get(opts, :force_player_refresh, false)

    player_dom_id =
      if force_player_refresh? do
        "player-#{video.public_id}-refresh-#{System.unique_integer([:positive])}"
      else
        player_dom_id(video)
      end

    socket
    |> assign(:mode, :video)
    |> assign(:resource_embed, video_embed)
    |> assign(:page_title, gettext("Video Details"))
    |> assign(:video_id, Embeds.dashboard_embed_id(video_embed))
    |> assign(:folder, nil)
    |> assign(:folders, [])
    |> assign(:videos, [])
    |> assign(:video, video)
    |> assign(:engagement, encode_dropoff_chart_points(video.engagement))
    |> assign(:persisted_settings, video.settings)
    |> assign(:player_dom_id, player_dom_id)
    |> assign(:video_ready, true)
    |> assign(:video_processing, false)
    |> assign(:processing_player_visible_after_ms, nil)
    |> assign(:replace_mode, false)
    |> assign(:upload_token, nil)
    |> assign(:component_src, video.component_src)
    |> assign(:folder_paths, [])
    |> assign(:settings_open, true)
    |> maybe_complete_poster_upload(video_embed, video)
    |> maybe_clear_materialized_media_processing(
      video,
      :audio_tracks,
      :processing_uploaded_audio_track,
      :processing_uploaded_audio_track_signature
    )
    |> maybe_clear_materialized_media_processing(
      video,
      :subtitles,
      :processing_uploaded_subtitle,
      :processing_uploaded_subtitle_signature
    )
  end

  defp start_poster_upload(%{assigns: %{resource_embed: %Embed{} = embed}} = socket) do
    assign(socket, :poster_upload, %{
      embed_id: embed.id,
      ref: make_ref(),
      stage: :uploading,
      signature: poster_signature(socket.assigns.video)
    })
  end

  defp start_poster_upload(socket), do: socket

  defp maybe_complete_poster_upload(socket, embed, video) do
    case socket.assigns.poster_upload do
      %{embed_id: embed_id} when embed_id != embed.id ->
        assign(socket, :poster_upload, nil)

      %{stage: :processing, signature: previous_signature} ->
        signature = poster_signature(video)

        if signature != [] and signature != previous_signature and
             video.settings.poster == :upload and is_binary(video.settings.external_poster) do
          socket
          |> assign(:poster_upload, nil)
          |> assign(
            :player_dom_id,
            "player-#{video.public_id}-refresh-#{System.unique_integer([:positive])}"
          )
        else
          socket
        end

      _ ->
        socket
    end
  end

  defp poster_signature(video) when is_map(video) do
    video
    |> Map.get(:renditions, [])
    |> Enum.filter(&(&1.type == "custom_thumbnail"))
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  defp poster_signature(_video), do: []

  defp resolve_current_video_embed(socket, embed_id) do
    case socket.assigns do
      %{mode: :video, resource_embed: %Embed{id: ^embed_id}} ->
        case Embeds.resolve_dashboard_embed(socket.assigns.current_space, embed_id) do
          {:ok, %Embed{} = embed} -> {:ok, embed}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp dashboard_payload_count(socket, %Embed{} = embed, field) do
    socket.assigns.current_space
    |> then(&Embeds.get_preloaded_video_dashboard_payload(&1, embed))
    |> Map.get(field, [])
    |> length()
  end

  defp dashboard_payload_signature(socket, %Embed{} = embed, field) do
    socket.assigns.current_space
    |> then(&Embeds.get_preloaded_video_dashboard_payload(&1, embed))
    |> media_signature(field)
  end

  defp uploaded_media_signature_changed?(socket, next_signature, processing_key, signature_key) do
    not is_nil(Map.get(socket.assigns, processing_key)) and
      next_signature != Map.get(socket.assigns, signature_key)
  end

  defp maybe_clear_materialized_media_processing(
         socket,
         video,
         field,
         processing_key,
         signature_key
       ) do
    if Map.get(socket.assigns, processing_key) &&
         media_signature(video, field) != Map.get(socket.assigns, signature_key) do
      socket
      |> assign(processing_key, nil)
      |> assign(signature_key, nil)
    else
      socket
    end
  end

  defp maybe_clear_exhausted_media_processing(
         socket,
         attempts_left,
         processing_key,
         signature_key
       ) do
    if attempts_left <= 0 do
      socket
      |> assign(processing_key, nil)
      |> assign(signature_key, nil)
    else
      socket
    end
  end

  defp media_signature(video, field) when is_map(video) do
    video
    |> Map.get(field, [])
    |> Enum.map(&media_signature_item/1)
  end

  defp media_signature(_video, _field), do: []

  defp media_signature_item(item) when is_map(item) do
    item
    |> Map.take([:id, :filename, :path, :label, :language, :codec, :file_size, :default])
    |> Enum.sort()
  end

  defp media_signature_item(item), do: item

  defp maybe_schedule_reload(attempts_left, message, delay_ms) when attempts_left > 0 do
    Process.send_after(self(), message, delay_ms)
  end

  defp maybe_schedule_reload(_attempts_left, _message, _delay_ms), do: :ok

  defp assign_uploaded_video_state(socket, %Embed{} = embed) do
    if processing_view?(socket, embed) do
      assign_video_processing(socket, embed)
    else
      assign_video_upload(socket, embed)
    end
  end

  defp assign_video_processing(socket, %Embed{} = video_embed, opts \\ []) do
    reuse_analytics? = Keyword.get(opts, :reuse_analytics, false)

    video_payload =
      if reuse_analytics? and is_map(socket.assigns[:video]) do
        Embeds.refresh_video_dashboard_processing_payload(
          socket.assigns.current_space,
          video_embed,
          socket.assigns.video
        )
      else
        Embeds.get_preloaded_video_dashboard_payload(socket.assigns.current_space, video_embed)
      end

    {video, visible_after_ms} =
      video_payload
      |> with_processing_player_readiness(socket, video_embed.id)

    socket
    |> assign(:mode, :video)
    |> assign(:resource_embed, video_embed)
    |> assign(:page_title, gettext("Video Details"))
    |> assign(:video_id, Embeds.dashboard_embed_id(video_embed))
    |> assign(:folder, nil)
    |> assign(:folders, [])
    |> assign(:videos, [])
    |> assign(:video, video)
    |> assign(:engagement, encode_dropoff_chart_points(video.engagement))
    |> assign(:persisted_settings, video.settings)
    |> assign(:player_dom_id, "processing-#{video.public_id}")
    |> assign(:video_ready, false)
    |> assign(:video_processing, true)
    |> assign(:processing_player_visible_after_ms, visible_after_ms)
    |> assign(:replace_mode, false)
    |> assign(:upload_token, nil)
    |> assign(:component_src, video.component_src)
    |> assign(:folder_paths, [])
    |> assign(:settings_open, Map.get(video, :processing_player_ready, false))
  end

  defp schedule_processing_progress_refresh(socket, space_id, embed_id) do
    if socket.assigns.processing_progress_refresh_pending do
      socket
    else
      Process.send_after(
        self(),
        {:refresh_processing_progress, space_id, embed_id},
        @processing_progress_refresh_interval_ms
      )

      assign(socket, :processing_progress_refresh_pending, true)
    end
  end

  defp with_processing_player_readiness(video, socket, embed_id) when is_map(video) do
    now_ms = System.monotonic_time(:millisecond)
    ready_now? = Map.get(video, :processing_player_ready, false)
    latched? = processing_player_ready_latched?(socket, video)
    visible_after_ms = processing_player_visible_after_ms(socket, video, now_ms, ready_now?)
    ready? = latched? or (ready_now? and now_ms >= visible_after_ms)

    if ready_now? and not ready? do
      Process.send_after(
        self(),
        {:processing_player_settle_elapsed, embed_id},
        max(0, visible_after_ms - now_ms)
      )
    end

    {Map.put(video, :processing_player_ready, ready?), visible_after_ms}
  end

  defp with_processing_player_readiness(video, _socket, _embed_id), do: {video, nil}

  defp processing_player_visible_after_ms(socket, video, now_ms, ready_now?) do
    if socket.assigns[:video_processing] &&
         is_map(socket.assigns[:video]) &&
         Map.get(socket.assigns.video, :public_id) == Map.get(video, :public_id) &&
         is_integer(socket.assigns[:processing_player_visible_after_ms]) do
      socket.assigns.processing_player_visible_after_ms
    else
      if ready_now?, do: now_ms, else: now_ms + processing_player_settle_ms()
    end
  end

  defp processing_player_ready_latched?(socket, video) do
    socket.assigns[:video_processing] &&
      is_map(socket.assigns[:video]) &&
      Map.get(socket.assigns.video, :public_id) == Map.get(video, :public_id) &&
      Map.get(socket.assigns.video, :processing_player_ready, false)
  end

  defp latched_processing_player?(socket, %Embed{} = video_embed) do
    socket.assigns[:video_processing] &&
      current_video_present?(video_embed) &&
      is_map(socket.assigns[:video]) &&
      Map.get(socket.assigns.video, :public_id) ==
        SettingsSerializer.public_embed_id(socket.assigns.current_space, video_embed) &&
      Map.get(socket.assigns.video, :processing_player_ready, false)
  end

  defp assign_video_upload(socket, %Embed{} = video_embed, opts \\ []) do
    video = upload_video_payload(socket.assigns.current_space, video_embed)
    replace_mode? = Keyword.get(opts, :replace_mode, false)

    socket
    |> assign(:mode, :video)
    |> assign(:resource_embed, video_embed)
    |> assign(:page_title, gettext("Video Details"))
    |> assign(:video_id, Embeds.dashboard_embed_id(video_embed))
    |> assign(:folder, nil)
    |> assign(:folders, [])
    |> assign(:videos, [])
    |> assign(:video, video)
    |> assign(:engagement, "[]")
    |> assign(:persisted_settings, nil)
    |> assign(:player_dom_id, "upload-#{video.public_id}")
    |> assign(:video_ready, false)
    |> assign(:video_processing, false)
    |> assign(:processing_player_visible_after_ms, nil)
    |> assign(:replace_mode, replace_mode?)
    |> assign(
      :upload_token,
      upload_token(socket.assigns.current_space, video_embed, socket.assigns.current_user)
    )
    |> assign(:component_src, video.component_src)
    |> assign(:folder_paths, [])
    |> assign(:settings_open, false)
  end

  defp upload_token(space, %Embed{} = embed, current_user) do
    case Spaces.ensure_internal_key(space, :dashboard_uploads) do
      {:ok, key} ->
        Token.sign_api_key(
          key,
          SettingsSerializer.public_embed_id(space, embed),
          admin_maintenance_bypass: Maintenance.internal_user?(current_user)
        )

      {:error, _reason} ->
        nil
    end
  end

  defp assign_video_preview(%{assigns: %{resource_embed: %Embed{} = embed}} = socket, settings) do
    video =
      Embeds.get_preloaded_video_dashboard_payload(socket.assigns.current_space, embed, settings)

    if poster_preview_only_change?(socket.assigns.persisted_settings, settings) and
         socket.assigns.video do
      socket
      |> assign(:video, video)
      |> assign(:engagement, encode_dropoff_chart_points(video.engagement))
    else
      socket
      |> assign(:video, video)
      |> assign(:engagement, encode_dropoff_chart_points(video.engagement))
      |> assign(:player_dom_id, player_dom_id(video))
    end
  end

  defp encode_dropoff_chart_points(per_second) do
    per_second
    |> dropoff_chart_points()
    |> Jason.encode!()
  end

  defp dropoff_chart_points(per_second) when is_list(per_second) do
    points =
      per_second
      |> Enum.map(&view_count/1)
      |> Enum.filter(&(&1 >= 0))

    cond do
      points == [] ->
        []

      Enum.all?(points, &(&1 == 0)) ->
        []

      length(points) <= @max_dropoff_chart_points ->
        points

      true ->
        sample_dropoff_chart_points(points)
    end
  end

  defp dropoff_chart_points(_), do: []

  defp sample_dropoff_chart_points(points) do
    point_count = length(points)
    last_point = List.last(points)

    0..(@max_dropoff_chart_points - 1)
    |> Enum.map(fn point_index ->
      segment_start = div(point_index * point_count, @max_dropoff_chart_points)
      segment_end = div((point_index + 1) * point_count, @max_dropoff_chart_points) - 1
      segment_length = max(segment_end - segment_start + 1, 1)

      cond do
        point_index == 0 ->
          hd(points)

        point_index == @max_dropoff_chart_points - 1 ->
          last_point

        true ->
          points
          |> Enum.slice(segment_start, segment_length)
          |> Enum.max()
      end
    end)
  end

  defp view_count(value) when is_integer(value), do: value
  defp view_count(value) when is_float(value), do: round(value)
  defp view_count(_), do: 0

  defp maybe_archive_attrs(attrs, :archive), do: Map.put(attrs, :archived, true)
  defp maybe_archive_attrs(attrs, _tab), do: attrs

  defp poster_preview_only_change?(persisted, current)
       when is_map(persisted) and is_map(current) do
    poster_fields = [
      :poster,
      :poster_time_seconds,
      :poster_time_hour,
      :poster_time_minute,
      :poster_time_second,
      :external_poster
    ]

    Map.take(persisted, poster_fields) != Map.take(current, poster_fields) and
      Map.drop(persisted, poster_fields) == Map.drop(current, poster_fields)
  end

  defp poster_preview_only_change?(_persisted, _current), do: false

  defp assign_folder_embed(socket, %Embed{} = folder_embed) do
    %{folders: folders, videos: videos, page: current_page, total_pages: total_pages} =
      Embeds.list_folder_items(socket.assigns.current_space, folder_embed,
        page: socket.assigns.page
      )

    socket
    |> assign(:resource_embed, folder_embed)
    |> assign(:page_title, folder_name(folder_embed))
    |> assign(:folder, %{
      id: Embeds.dashboard_embed_id(folder_embed),
      public_id: SettingsSerializer.public_embed_id(socket.assigns.current_space, folder_embed),
      name: folder_name(folder_embed),
      archived: folder_embed.archived
    })
    |> assign(
      :folder_paths,
      folder_paths(
        socket.assigns.current_space,
        folder_embed,
        socket.assigns.current_tab,
        socket.assigns.route_scope
      )
    )
    |> assign(:folders, folders)
    |> assign(:videos, videos)
    |> assign(:page, current_page)
    |> assign(:total_pages, total_pages)
    |> assign(:confirmation_needed, false)
    |> assign(:pending_action, nil)
    |> assign_video_creation_status()
  end

  defp assign_video_creation_status(socket) do
    case UsageLimits.can_create_video_embed?(socket.assigns.current_space) do
      :ok ->
        socket
        |> assign(:can_create_video, true)
        |> assign(:video_creation_notice, nil)
        |> assign(:video_creation_help, nil)

      {:error, reason} ->
        copy = UsageLimits.restriction_copy(:create_video, reason)

        socket
        |> assign(:can_create_video, false)
        |> assign(
          :video_creation_notice,
          Map.get(copy, :notice, gettext("Video creation is unavailable"))
        )
        |> assign(
          :video_creation_help,
          Map.get(copy, :help, gettext("This space cannot create more videos right now."))
        )
    end
  end

  defp video_creation_error(reason) do
    :create_video
    |> UsageLimits.restriction_copy(reason)
    |> Map.get(:error, gettext("Could not create video"))
  end

  defp video_state_label(:queued), do: gettext("Queued")
  defp video_state_label(:processing), do: gettext("Processing")
  defp video_state_label(:failed), do: gettext("Failed")
  defp video_state_label(_state), do: gettext("Processing")

  defp confirmation_message(:archive, %Embed{type: :collection, archived: true}),
    do: gettext("Restore this folder from the archive?")

  defp confirmation_message(:archive, %Embed{type: :collection}),
    do: gettext("Move this folder to the archive? You can restore it from the archive later.")

  defp confirmation_message(:archive, %Embed{archived: true}),
    do: gettext("Restore this video from the archive?")

  defp confirmation_message(:archive, %Embed{}),
    do: gettext("Move this video to the archive? You can restore it from the archive later.")

  defp confirmation_message(_pending_action, _embed),
    do: gettext("This action cannot be reversed.")

  defp dashboard_player_tag(%{original: %{audio_only: true}}), do: "mave-audio"
  defp dashboard_player_tag(_video), do: "mave-player"

  defp framework_player_name(%{original: %{audio_only: true}}), do: "Audio"
  defp framework_player_name(_video), do: "Player"

  defp player_dom_id(video) do
    "player-#{video.public_id}-#{:erlang.phash2({dashboard_player_tag(video), dashboard_player_attributes_string(video)})}"
  end

  defp dashboard_player_attributes(video) when is_map(video) do
    attrs = Map.get(video, :player_attributes, [])

    case dashboard_player_poster(video) do
      poster when is_binary(poster) and poster != "" ->
        attrs
        |> Enum.reject(fn
          {"poster", _value} -> true
          {:poster, _value} -> true
          _attr -> false
        end)
        |> Kernel.++([{"poster", poster}])
        |> dashboard_audio_thumbnail(video)

      _ ->
        attrs
    end
  end

  defp dashboard_player_attributes(_video), do: []

  defp dashboard_audio_thumbnail(attrs, %{original: %{audio_only: true}}) do
    controls =
      Enum.find_value(attrs, "full", fn
        {key, value} when key in ["controls", :controls] -> value
        _attr -> nil
      end)

    attrs
    |> Enum.reject(fn {key, _value} -> key in ["controls", :controls] end)
    |> Kernel.++([{"controls", "#{controls} thumbnail"}])
  end

  defp dashboard_audio_thumbnail(attrs, _video), do: attrs

  defp dashboard_player_attributes_string(video) do
    video
    |> dashboard_player_attributes()
    |> SettingsSerializer.attributes_to_string()
  end

  defp dashboard_player_poster(%{
         settings: %{poster: :upload, external_poster: external_poster},
         preview_poster: preview_poster
       })
       when is_binary(external_poster) and external_poster != "" and is_binary(preview_poster) and
              preview_poster != "" do
    preview_poster
  end

  defp dashboard_player_poster(_video), do: nil

  defp player_shell_style(%{original: %{audio_only: true}}),
    do:
      "display: block; width: 100%; --mave-audio-min-height: 160px; min-height: var(--mave-audio-min-height);"

  defp player_shell_style(video) when is_map(video) do
    ratio =
      video
      |> Map.get(:aspect_ratio, "16/9")
      |> normalize_aspect_ratio()

    background =
      case Map.get(video, :preview_poster) do
        value when is_binary(value) and value != "" ->
          "background: center / contain no-repeat url(#{value}); "

        _ ->
          ""
      end

    "display: block; width: 100%; #{background}aspect-ratio: #{ratio};"
  end

  defp normalize_aspect_ratio(value) when is_binary(value) and value != "" do
    value
    |> String.replace(":", " / ")
    |> String.replace("/", " / ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp normalize_aspect_ratio(_), do: "16 / 9"

  defp folder_name(%Embed{} = folder_embed) do
    name =
      case folder_embed.collection do
        %{name: value} -> value
        _ -> nil
      end

    if is_binary(name) and name != "" do
      name
    else
      gettext("Untitled")
    end
  end

  defp video_name(%Embed{} = video_embed) do
    case video_embed.asset do
      %{name: value} when is_binary(value) and value != "" -> value
      _ -> gettext("Untitled")
    end
  end

  defp upload_video_payload(space, %Embed{} = video_embed) do
    settings = SettingsSerializer.settings_struct(video_embed)

    %{
      id: Embeds.dashboard_embed_id(video_embed),
      public_id: SettingsSerializer.public_embed_id(space, video_embed),
      hash: video_embed.hash,
      name: video_name(video_embed),
      archived: video_embed.archived,
      snippet_player_poster: nil,
      snippet_clip_poster: nil,
      settings: SettingsSerializer.form_values(settings),
      player_attributes: SettingsSerializer.player_attributes(settings),
      player_attributes_string:
        settings
        |> SettingsSerializer.player_attributes()
        |> SettingsSerializer.attributes_to_string(),
      iframe_url: SettingsSerializer.iframe_url(space, video_embed),
      iframe_dimensions: SettingsSerializer.iframe_dimensions(settings),
      component_config_src: SettingsSerializer.component_config_src(),
      component_src: SettingsSerializer.component_src(),
      component_config_required: SettingsSerializer.component_config_required?(),
      component_config_json: SettingsSerializer.component_config_json(),
      views_today: 0,
      views_month: 0,
      views_year: 0,
      sources: [],
      engagement: []
    }
  end

  defp line_numbers(type, video, embed) do
    type
    |> snippet_string(video, embed)
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.map(&elem(&1, 1))
  end

  defp resolve_drop_target(space, %{"to" => target_id}) do
    case String.trim(target_id || "") do
      "" -> {:ok, nil}
      value -> Embeds.resolve_dashboard_embed(space, value)
    end
  end

  defp resolve_drop_target(_space, _params), do: {:ok, nil}

  defp folder_paths(space, %Embed{} = folder_embed, tab, scope) do
    Enum.map(Embeds.folder_paths(space, folder_embed), fn path_embed ->
      %{
        id: path_embed.id,
        label: folder_name(path_embed),
        navigate: video_path(space, Embeds.dashboard_embed_id(path_embed), tab, scope),
        drop_to: path_embed.id
      }
    end)
  end

  defp code_tabs(current, video, embed) do
    current = effective_code_preview(current, embed)

    [
      %{name: :script, label: "Player", current: current == :script},
      %{name: :clip, label: "Clip", current: current == :clip},
      %{name: :iframe, label: "iFrame", current: current == :iframe},
      %{name: :react, label: "React", current: current == :react},
      %{name: :vue, label: "Vue", current: current == :vue}
    ]
    |> Enum.reject(fn tab ->
      (dashboard_player_tag(video) == "mave-audio" and tab.name == :clip) or
        (MaveCore.Playback.protected?(embed) and tab.name == :iframe)
    end)
  end

  defp effective_code_preview(:iframe, embed) do
    if MaveCore.Playback.protected?(embed), do: :script, else: :iframe
  end

  defp effective_code_preview(type, _embed), do: type

  defp snippet_string(type, video, embed) do
    type = effective_code_preview(type, embed)

    if MaveCore.Playback.protected?(embed) do
      # Public thumbnail URLs are not suitable as private embed backgrounds.
      video = video |> Map.put(:snippet_player_poster, nil) |> Map.put(:snippet_clip_poster, nil)

      tag =
        case type do
          :clip -> "mave-clip"
          framework when framework in [:react, :vue] -> framework_player_name(video)
          _ -> dashboard_player_tag(video)
        end

      EmbedCode.add_token(snippet_string(type, video), type, video.public_id, tag)
    else
      snippet_string(type, video)
    end
  end

  defp snippet_string(:script, video) do
    Enum.join(
      component_script_lines(video) ++
        [
          snippet_element(
            dashboard_player_tag(video),
            video.public_id,
            video.player_attributes,
            player_style_lines(video)
          )
        ],
      "\n"
    )
  end

  defp snippet_string(:clip, video) do
    Enum.join(
      component_script_lines(video) ++
        [
          snippet_element("mave-clip", video.public_id, [], clip_style_lines(video))
        ],
      "\n"
    )
  end

  defp snippet_string(:iframe, video) do
    Enum.join(
      [
        ~s(<iframe),
        ~s(  src="#{video.iframe_url}"),
        ~s(  width="640" height="360" frameborder="0" scrolling="no" allowfullscreen>),
        ~s(</iframe>)
      ],
      "\n"
    )
  end

  defp snippet_string(:react, video) do
    component = framework_player_name(video)

    Enum.join(
      snippet_config_lines(video, "") ++
        [
          ~s|const { #{component} } = await import("#{SettingsSerializer.react_src()}");|,
          snippet_element(component, video.public_id, video.player_attributes, [])
        ],
      "\n"
    )
  end

  defp snippet_string(:vue, video) do
    component = framework_player_name(video)

    Enum.join(
      snippet_config_lines(video, "") ++
        [
          ~s|const { #{component} } = await import("#{SettingsSerializer.vue_src()}");|,
          snippet_element(component, video.public_id, video.player_attributes, [])
        ],
      "\n"
    )
  end

  defp component_script_lines(%{component_config_required: false} = video) do
    [
      ~s(<script),
      ~s(  type="module"),
      ~s(  src="#{video.component_src}"),
      ~s(></script>)
    ]
  end

  defp component_script_lines(video) do
    [
      ~s(<script type="module">)
    ] ++
      snippet_config_lines(video, "  ") ++
      [
        ~s|  await import("#{video.component_src}");|,
        ~s(</script>)
      ]
  end

  defp snippet_config_lines(%{component_config_required: true} = video, indent) do
    [
      ~s(#{indent}import { configureMave } from "#{video.component_config_src}";),
      ~s|#{indent}configureMave(#{video.component_config_json});|
    ]
  end

  defp snippet_config_lines(_video, _indent), do: []

  defp snippet_element(tag, public_id, attributes, style_lines) do
    attrs = snippet_attrs(attributes)
    style = snippet_style_attr(style_lines)

    ~s(<#{tag} embed="#{public_id}"#{attrs}#{style}></#{tag}>)
  end

  defp snippet_attrs([]), do: ""

  defp snippet_attrs(attributes) do
    attributes
    |> Enum.map_join("", fn
      {key, value} when key == value -> " #{key}"
      {key, value} -> ~s( #{key}="#{SettingsSerializer.escape_attribute(value)}")
    end)
  end

  defp snippet_style_attr([]), do: ""

  defp snippet_style_attr(style_lines) do
    ~s( style="#{SettingsSerializer.escape_attribute(Enum.join(style_lines, " "))}")
  end

  defp player_style_lines(%{original: %{audio_only: true}}),
    do: ["display: block;", "width: 100%;"]

  defp player_style_lines(video) do
    ratio =
      video
      |> Map.get(:aspect_ratio, "16/9")
      |> normalize_aspect_ratio()

    background =
      video
      |> Map.get(:snippet_player_poster)
      |> snippet_background_line("contain")

    [
      "display: block;",
      "width: 100%;",
      background,
      "aspect-ratio: #{ratio};"
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp clip_style_lines(video) do
    background =
      video
      |> Map.get(:snippet_clip_poster)
      |> snippet_background_line("cover")

    [
      "display: block;",
      "height: 100%;",
      "width: 100%;",
      background
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp snippet_background_line(url, mode) when is_binary(url) and url != "",
    do: "background: center / #{mode} no-repeat url(#{url});"

  defp snippet_background_line(_url, _mode), do: nil

  defp route_scope(%{"space_id" => space_id}) when is_binary(space_id) and space_id != "",
    do: :scoped

  defp route_scope(_params), do: :unscoped

  defp videos_path(space, tab, scope), do: DashboardRoutes.videos_path(space, tab, scope: scope)

  defp video_path(space, id, tab, scope, opts \\ []),
    do: DashboardRoutes.video_path(space, id, tab, Keyword.put(opts, :scope, scope))

  defp folder_page_path(%{assigns: %{resource_embed: %Embed{} = folder_embed}} = socket, page) do
    video_path(
      socket.assigns.current_space,
      Embeds.dashboard_embed_id(folder_embed),
      socket.assigns.current_tab,
      socket.assigns.route_scope,
      page: page
    )
  end

  defp parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {parsed, _rest} when parsed > 0 -> parsed
      _ -> 1
    end
  end

  defp parse_page(_page), do: 1

  defp video_ready?(%Embed{asset: %{current_video: %{status: status}}})
       when status in ["ready", "playable"],
       do: true

  defp video_ready?(%Embed{asset: %{current_video_id: current_video_id}})
       when is_binary(current_video_id),
       do: false

  defp video_ready?(_embed), do: false

  defp current_video_present?(%Embed{asset: %{current_video_id: current_video_id}})
       when is_binary(current_video_id),
       do: true

  defp current_video_present?(_embed), do: false

  defp processing_view_ready?(socket, %Embed{} = embed) do
    !video_ready?(embed) &&
      current_video_present?(embed) &&
      Embeds.processing_player_ready?(socket.assigns.current_space.hash, embed.hash)
  end

  defp processing_view?(socket, %Embed{} = embed) do
    current_video_present?(embed) &&
      (video_preparing?(embed) ||
         processing_view_ready?(socket, embed) ||
         Embeds.processing_run_active?(socket.assigns.current_space.hash, embed.hash))
  end

  defp video_preparing?(%Embed{asset: %{current_video: %{status: "preparing"}}}), do: true
  defp video_preparing?(_embed), do: false

  defp processing_player_settle_ms do
    case Application.get_env(
           :mave_core,
           :processing_player_settle_ms,
           @default_processing_player_settle_ms
         ) do
      value when is_integer(value) and value >= 0 -> value
      _ -> @default_processing_player_settle_ms
    end
  end
end
