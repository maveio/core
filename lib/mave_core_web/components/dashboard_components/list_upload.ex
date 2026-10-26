defmodule MaveCoreWeb.DashboardComponents.ListUpload do
  @moduledoc """
  File drop target and upload queue shared by video and folder lists.
  """

  use Phoenix.Component
  use Gettext, backend: MaveCoreWeb.Gettext

  import MaveCoreWeb.DashboardComponents.Settings, only: [settings_header: 1, settings_panel: 1]
  import MaveCoreWeb.DashboardComponents.States, only: [empty_state: 1, progress_status_row: 1]
  alias MaveCore.Embeds.SettingsSerializer

  attr :id, :string, required: true
  attr :folder_id, :string, default: nil
  attr :destination, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :disabled_message, :string, default: nil
  attr :hook, :string, default: "video_list_upload"
  attr :active, :boolean, default: false
  attr :uploads, :list, default: [], doc: "Static queue examples for component previews."
  slot :inner_block, required: true

  def video_list_upload(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook={@hook}
      class={[
        "video-upload-area group/video-drop relative flex min-h-0 flex-1 flex-col",
        is_nil(@hook) && "video-upload-preview"
      ]}
      data-drop-active={to_string(@active)}
      data-folder-id={@folder_id}
      data-destination={@destination || gettext("Videos")}
      data-upload-disabled={to_string(@disabled)}
      data-disabled-message={@disabled_message || gettext("Video creation is unavailable.")}
      data-drop-label={gettext("drop to upload")}
      data-drop-folder-label={gettext("drop to upload to %{folder}", folder: "%{folder}")}
      data-invalid-file-message={
        gettext("Choose video or audio files. Folders and empty files cannot be uploaded.")
      }
      data-queued-message={gettext("Queued")}
      data-preparing-message={gettext("Preparing…")}
      data-uploading-message={gettext("Uploading…")}
      data-processing-message={gettext("Uploaded · processing")}
      data-completed-message={gettext("Ready")}
      data-error-message={gettext("Could not upload this file. Please try again.")}
      data-connection-message={gettext("The upload connection was lost. Please try again.")}
      data-leave-message={
        gettext(
          "Uploads are still running. Leaving this list will discard files that are waiting to upload. Leave anyway?"
        )
      }
    >
      <div
        :if={@hook}
        id={"#{@id}-components"}
        phx-hook="component_loader"
        data-component-config-src={SettingsSerializer.component_config_src()}
        data-component-src={SettingsSerializer.component_src()}
        data-component-config={SettingsSerializer.component_config_json()}
        class="hidden"
      >
      </div>
      <div class="video-upload-list relative flex min-h-0 flex-1 flex-col">
        {render_slot(@inner_block)}
        <div
          id={"#{@id}-overlay"}
          phx-update="ignore"
          aria-hidden="true"
          class={[
            "video-upload-drop pointer-events-none absolute inset-x-0 bottom-0 z-20 flex items-center justify-center bg-stone-100/90 px-6 text-center text-stone-500 backdrop-grayscale",
            if(@folder_id, do: "-top-4", else: "top-0")
          ]}
        >
          <.empty_state
            title={gettext("drop to upload")}
            icon="upload"
            title_attrs={%{"data-drop-label" => true}}
          />
        </div>
      </div>
      <div id={"#{@id}-upload-host"} data-upload-host phx-update="ignore" class="hidden"></div>
      <p
        id={"#{@id}-notice"}
        data-upload-notice
        phx-update="ignore"
        role="alert"
        class="hidden shrink-0 border-t border-stone-200 bg-stone-50 px-6 py-3 text-sm text-stone-600 sm:px-16"
      >
      </p>
      <.settings_panel
        id={"#{@id}-status"}
        phx-update="ignore"
        data-upload-status
        role="complementary"
        aria-label={gettext("Uploads")}
        aria-hidden={to_string(@uploads == [])}
        inert={@uploads == []}
        class={[@uploads != [] && "is-open", "video-upload-queue"]}
      >
        <div data-upload-details class="video-upload-details">
          <.settings_header title={gettext("Uploads")} />
          <div
            id={"#{@id}-rows"}
            data-upload-rows
            class="flex flex-col"
          >
            <.upload_row
              :for={{upload, index} <- Enum.with_index(@uploads)}
              delay={min(index, 4) * 60}
              {upload}
            />
          </div>
        </div>
        <template data-upload-template>
          <.upload_row />
        </template>
      </.settings_panel>
    </div>
    """
  end

  attr :name, :string, default: ""
  attr :destination, :string, default: ""
  attr :state, :string, default: "queued"
  attr :progress, :integer, default: 0
  attr :delay, :integer, default: 0

  defp upload_row(assigns) do
    ~H"""
    <.progress_status_row
      data-upload-id=""
      data-state={@state}
      style={"animation-delay: #{@delay}ms"}
      status={upload_status(@state)}
      progress={@progress}
      progress_attrs={
        %{
          "data-upload-progress" => true,
          "role" => "progressbar",
          "aria-label" => @name,
          "aria-valuemin" => 0,
          "aria-valuemax" => 100,
          "aria-valuenow" => @progress,
          "class" => if(@state not in ["queued", "preparing", "uploading"], do: "hidden")
        }
      }
      class="video-upload-row group/upload data-[state=error]:h-auto data-[state=error]:min-h-[calc(4rem+1px)]"
    >
      <a
        data-upload-name
        data-upload-link
        title={"#{@name} · #{@destination}"}
        class="block truncate [&[href]]:hover:text-stone-400 focus-visible:outline-2 focus-visible:outline-blue-500"
      >
        {@name}
      </a>
      <:metadata>
        <span
          data-upload-percent
          class={[
            @state not in ["preparing", "uploading"] && "hidden",
            "ml-1 w-10 shrink-0 font-condensed text-center rounded text-xs text-stone-600/80 ring-1 ring-inset ring-stone-700/50 shadow px-1 pt-[0.02rem] pb-[0.09rem]"
          ]}
        >{@progress}%</span>
      </:metadata>
      <:detail>
        <span
          data-upload-message
          class="sr-only group-data-[state=error]/upload:not-sr-only group-data-[state=error]/upload:mt-2 group-data-[state=error]/upload:block break-words text-xs leading-4 text-red-400"
        >{upload_message(@state)}</span>
        <button
          data-upload-retry
          type="button"
          class={[
            @state != "error" && "hidden",
            "mt-2 cursor-pointer text-xs text-stone-400 hover:text-stone-300 focus-visible:outline-2 focus-visible:outline-blue-500"
          ]}
        >
          {gettext("Try again")}
        </button>
      </:detail>
    </.progress_status_row>
    """
  end

  defp upload_message("queued"), do: gettext("Queued")
  defp upload_message("preparing"), do: gettext("Preparing…")
  defp upload_message("uploading"), do: gettext("Uploading…")
  defp upload_message("processing"), do: gettext("Uploaded · processing")
  defp upload_message("completed"), do: gettext("Ready")
  defp upload_message("error"), do: gettext("Connection lost. Please try again.")

  defp upload_status("queued"), do: "queued"
  defp upload_status("completed"), do: "completed"
  defp upload_status("error"), do: "failed"
  defp upload_status(_state), do: "active"
end
