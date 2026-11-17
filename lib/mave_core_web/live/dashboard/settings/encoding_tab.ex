defmodule MaveCoreWeb.Dashboard.Settings.EncodingTab do
  @moduledoc """
  Visual editor for a space's encoding pipeline.

  Shows the steps an upload goes through, lets a member turn optional steps
  off, add the steps that step plugins offer and change editable step settings,
  and saves the result as a new pipeline version through
  `MaveCore.Flow.Pipelines`. Plugin steps show their progress and results from
  the space's most recent uploads.
  """

  use MaveCoreWeb, :live_component
  import MaveCoreWeb.DashboardComponents, except: [icon: 1]

  alias MaveCore.Flow.{Pipeline, Pipelines, StepRegistry}
  alias MaveCore.UsageLimits
  alias MaveCoreWeb.Dashboard.Settings.PipelineGraph

  @activity_refresh_ms 3_000

  @impl true
  def update(%{refresh_activity: token}, socket) do
    if token == socket.assigns[:activity_token] do
      {:ok, socket |> assign_activity() |> schedule_activity_refresh()}
    else
      {:ok, socket}
    end
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> MaveCoreWeb.SpaceLiveAuth.attach_component()

    {:ok,
     if(socket.assigns[:loaded_space_id] == assigns.current_space.id,
       do: socket,
       else: load(socket)
     )}
  end

  defp load(socket) do
    space = socket.assigns.current_space
    saved = Pipelines.current_overrides(space)

    socket
    |> assign(:loaded_space_id, space.id)
    |> assign(:base, base(space))
    |> assign(:edit_access, Pipelines.can_edit?(space))
    |> assign(:unavailable, Pipelines.unavailable_steps(space))
    |> assign(:saved, saved)
    |> assign(:draft, saved)
    |> assign(:selected, nil)
    |> assign(:note, "")
    |> assign_versions()
    |> resolve()
    |> assign_activity()
    |> schedule_activity_refresh()
  end

  defp assign_activity(socket) do
    assign(socket, :activity, Pipelines.step_activity(socket.assigns.current_space))
  end

  # Results of plugin steps arrive while the editor is open, so it looks again
  # every few seconds for as long as the pipeline has such steps. The parent
  # LiveView forwards the message back to this component.
  defp schedule_activity_refresh(socket) do
    token = System.unique_integer([:positive])

    if connected?(socket) and plugin_steps?(socket.assigns[:resolution]) do
      Process.send_after(
        self(),
        {:settings_component_update, __MODULE__, socket.assigns.id, %{refresh_activity: token}},
        @activity_refresh_ms
      )
    end

    assign(socket, :activity_token, token)
  end

  defp plugin_steps?(nil), do: false
  defp plugin_steps?(resolution), do: Enum.any?(resolution.steps, & &1.results?)

  defp base(space) do
    case Pipelines.base(space) do
      {:ok, base} -> base
      {:error, _reason} -> nil
    end
  end

  defp assign_versions(socket) do
    versions = Pipelines.list_versions(socket.assigns.current_space)
    assign(socket, versions: versions, current_version: List.first(versions))
  end

  defp resolve(%{assigns: %{base: nil}} = socket) do
    assign(socket,
      resolution: nil,
      graph: nil,
      selected_step: nil,
      also_disabled: [],
      related: %{}
    )
  end

  defp resolve(socket) do
    %{base: base, draft: draft, selected: selected} = socket.assigns

    resolution =
      base.definition
      |> Pipeline.resolve(draft, unavailable: socket.assigns.unavailable)
      |> Map.update!(:steps, fn steps -> Enum.map(steps, &with_contract/1) end)

    selected_step = Enum.find(resolution.steps, &(&1.id == selected))

    also_disabled =
      if selected_step && selected_step.state == :enabled && not selected_step.locked,
        do: Pipeline.also_disabled(base.definition, draft, selected_step.id),
        else: []

    socket
    |> assign(:resolution, resolution)
    |> assign(:selected_step, selected_step)
    |> assign(:also_disabled, also_disabled)
    |> assign(:related, related(selected_step, also_disabled))
    |> assign(:graph, PipelineGraph.layout(resolution.steps, selected_step && selected_step.id))
  end

  # What a plugin step type declares about itself, for the inspector.
  defp with_contract(step) do
    type = StepRegistry.fetch(step.type) || %{}

    Map.merge(step, %{
      plugin: Map.get(type, :plugin, false),
      inputs: Map.get(type, :inputs, []),
      results?: Map.get(type, :results, []) != []
    })
  end

  # How each step relates to the selected one, for row highlighting.
  defp related(nil, _also_disabled), do: %{}

  defp related(step, also_disabled) do
    %{}
    |> Map.merge(Map.new(step.dependencies, &{&1, :needs}))
    |> Map.merge(Map.new(step.dependents, &{&1, :feeds}))
    |> Map.merge(Map.new(also_disabled, &{&1, :follows}))
  end

  @impl true
  def handle_event("select_step", %{"id" => step_id}, socket) do
    selected = if socket.assigns.selected == step_id, do: nil, else: step_id
    {:noreply, socket |> assign(:selected, selected) |> resolve()}
  end

  def handle_event("close_inspector", _params, socket) do
    {:noreply, socket |> assign(:selected, nil) |> resolve()}
  end

  def handle_event("toggle_step", %{"id" => step_id}, socket) do
    with true <- editable?(socket),
         %{locked: false, state: state} = step when state != :auto_disabled <-
           Enum.find(socket.assigns.resolution.steps, &(&1.id == step_id)),
         true <- step.available or state == :enabled do
      draft =
        if step.addon,
          do: Pipeline.put_step_added(socket.assigns.draft, step_id, state == :disabled),
          else: Pipeline.put_step_enabled(socket.assigns.draft, step_id, state == :disabled)

      {:noreply, socket |> assign(:draft, draft) |> resolve()}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("change_setting", %{"step_id" => step_id, "setting" => values}, socket)
      when is_map(values) do
    step = Enum.find(socket.assigns.resolution.steps, &(&1.id == step_id))

    if editable?(socket) and step != nil do
      draft =
        Enum.reduce(step.settings, socket.assigns.draft, &put_setting(&2, step_id, &1, values))

      {:noreply, socket |> assign(:draft, draft) |> resolve()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("change_note", %{"pipeline" => %{"note" => note}}, socket) do
    {:noreply, assign(socket, :note, note)}
  end

  def handle_event("discard", _params, socket) do
    {:noreply, socket |> assign(draft: socket.assigns.saved, note: "") |> resolve()}
  end

  def handle_event("restore", %{"version" => version}, socket) do
    with true <- editable?(socket),
         {number, ""} <- Integer.parse(version),
         %{overrides: overrides} <- Pipelines.get_version(socket.assigns.current_space, number) do
      {:noreply,
       socket
       |> assign(:draft, Pipeline.normalize(overrides))
       |> assign(:note, gettext("Restored version %{version}", version: number))
       |> resolve()}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("reset", _params, socket) do
    if editable?(socket) do
      {:noreply, socket |> assign(:draft, Pipeline.empty()) |> resolve()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save", params, socket) do
    note = get_in(params, ["pipeline", "note"]) || socket.assigns.note

    case Pipelines.save(socket.assigns.current_space, socket.assigns.draft,
           user: socket.assigns.current_user,
           note: note
         ) do
      {:ok, version} ->
        {:noreply,
         socket
         |> assign(saved: Pipeline.normalize(version.overrides), note: "")
         |> assign(:draft, Pipeline.normalize(version.overrides))
         |> assign_versions()
         |> resolve()
         |> put_flash(
           :info,
           gettext("Saved as version %{version}. New uploads use it from now on.",
             version: version.version
           )
         )}

      {:error, :unchanged} ->
        {:noreply, put_flash(socket, :info, gettext("Nothing changed since the last version."))}

      {:error, {:invalid, _issues}} ->
        {:noreply,
         put_flash(socket, :error, gettext("Fix the highlighted problems before saving."))}

      {:error, reason} ->
        copy = UsageLimits.restriction_copy(:encoding_pipeline, reason)

        {:noreply,
         put_flash(socket, :error, Map.get(copy, :error, gettext("Could not save the pipeline.")))}
    end
  end

  defp editable?(socket), do: socket.assigns.edit_access == :ok

  defp put_setting(draft, step_id, setting, values) do
    case Map.fetch(values, setting.key) do
      {:ok, value} ->
        Pipeline.put_setting(draft, step_id, setting.key, setting_input(setting, value))

      :error ->
        draft
    end
  end

  # Unchanged inputs are stored as "no override" so a later change of the
  # flow's own default still reaches the space.
  defp setting_input(setting, value) do
    if to_string(setting.base || "") == String.trim(to_string(value)), do: nil, else: value
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:dirty, assigns.draft != assigns.saved)
      |> assign(:issues, (assigns.resolution && assigns.resolution.issues) || [])
      |> assign(:can_edit, assigns.edit_access == :ok)
      |> assign(:notice, restriction_notice(assigns.edit_access))

    ~H"""
    <div id="encoding-pipeline">
      <.subtitle label={gettext("Encoding pipeline")} icon="video">
        <.info_hover position="left">
          {gettext(
            "Changes are saved as a new version and apply to future uploads. Videos that were already processed keep the version they ran with."
          )}
        </.info_hover>
      </.subtitle>

      <%= if @base == nil do %>
        <div class="mt-6">
          <.info_box>
            {gettext("The flow for this space could not be loaded, so there is nothing to edit yet.")}
          </.info_box>
        </div>
      <% else %>
        <p class="mt-3 max-w-3xl text-sm text-stone-400">
          {gettext(
            "This is the path every upload in this space takes, from the original file to playback. Select a step to see what it does, change its settings, turn optional steps off or add extra ones."
          )}
        </p>

        <div :if={@notice} id="pipeline-notice" class="mt-4">
          <.info_box>{@notice}</.info_box>
        </div>

        <div class="mt-6 flex flex-wrap items-center gap-2 text-sm">
          <span class="rounded-full bg-stone-100 px-3 py-1 text-stone-500" id="pipeline-base">
            {gettext("Based on %{name}", name: @base.name)}
          </span>
          <span class="rounded-full bg-stone-100 px-3 py-1 text-stone-500" id="pipeline-version">
            <%= if @current_version do %>
              {gettext("Version %{version} is live", version: @current_version.version)}
            <% else %>
              {gettext("Standard pipeline")}
            <% end %>
          </span>
          <span
            :if={@dirty}
            id="pipeline-dirty"
            class="rounded-full bg-amber-50 px-3 py-1 text-amber-600 ring-1 ring-inset ring-amber-200"
          >
            {gettext("Unsaved changes")}
          </span>
          <span class="ml-auto flex items-center gap-4 text-stone-400">
            <.legend_dot state={:enabled} label={gettext("On")} />
            <.legend_dot state={:disabled} label={gettext("Off")} />
            <span class="flex items-center gap-1">
              <.icon name="hero-lock-closed-micro" class="h-3.5 w-3.5 text-stone-300" />
              {gettext("Required")}
            </span>
            <span
              :if={Enum.any?(@resolution.steps, & &1.addon)}
              id="pipeline-legend-addon"
              class="flex items-center gap-1"
            >
              <.icon name="hero-puzzle-piece-micro" class="h-3.5 w-3.5 text-violet-400" />
              {gettext("Add-on")}
            </span>
          </span>
        </div>

        <div
          :if={@issues != []}
          id="pipeline-issues"
          class="mt-4 rounded-md bg-red-50 px-4 py-3 text-sm text-red-600 ring-1 ring-inset ring-red-200"
        >
          <div :for={issue <- @issues}>{issue.message}</div>
        </div>

        <div class="mt-4 flex items-start gap-4">
          <div
            id="pipeline-canvas"
            class="min-w-0 flex-1 overflow-x-auto rounded-lg bg-stone-50 ring-1 ring-stone-200"
          >
            <div class="relative" style={"width: #{@graph.width}px; height: #{@graph.height}px"}>
              <div
                :for={stage <- @graph.stages}
                id={"pipeline-stage-#{stage.stage}"}
                class="absolute text-xs font-medium uppercase tracking-wide text-stone-400"
                style={"left: #{stage.x + 2}px; top: #{stage.y + 2}px"}
              >
                {stage_label(stage.stage)}
              </div>

              <div
                :for={card <- @graph.cards}
                id={"pipeline-card-#{card.key}"}
                class="absolute overflow-hidden rounded-md bg-white shadow-sm ring-1 ring-stone-200"
                style={"left: #{card.x}px; top: #{card.y}px; width: #{@graph.column_width}px; height: #{card.height}px"}
              >
                <div
                  :if={!card.compact}
                  class="flex h-[26px] items-center truncate px-2.5 text-[11px] font-medium uppercase tracking-wide text-stone-400"
                >
                  {card.title}
                </div>
                <button
                  :for={member <- card.members}
                  type="button"
                  id={"pipeline-step-#{member.step.id}"}
                  title={member.step.name}
                  data-state={member.step.state}
                  phx-click="select_step"
                  phx-value-id={member.step.id}
                  phx-target={@myself}
                  class={[
                    "flex w-full items-center gap-2 px-2.5 text-left text-[13px] hover:bg-blue-50",
                    if(card.compact, do: "h-[32px]", else: "h-[24px]"),
                    row_class(member.step, @selected, @related)
                  ]}
                >
                  <.state_dot state={member.step.state} />
                  <span class={[
                    "min-w-0 flex-1 truncate",
                    member.step.state != :enabled && !member.step.addon && "line-through"
                  ]}>
                    {member.label}
                  </span>
                  <.row_activity
                    :if={member.step.state == :enabled}
                    id={"pipeline-step-result-#{member.step.id}"}
                    activity={Map.get(@activity, member.step.id)}
                  />
                  <span
                    :if={Enum.any?(member.step.settings, & &1.changed)}
                    class="h-1.5 w-1.5 flex-none rounded-full bg-amber-400"
                    title={gettext("Settings changed")}
                  />
                  <.icon
                    :if={member.step.locked}
                    name="hero-lock-closed-micro"
                    class="h-3 w-3 flex-none text-stone-300"
                  />
                  <.icon
                    :if={member.step.addon}
                    name="hero-puzzle-piece-micro"
                    class={[
                      "h-3 w-3 flex-none",
                      if(member.step.state == :enabled, do: "text-violet-400", else: "text-stone-300")
                    ]}
                  />
                </button>
              </div>

              <svg
                :if={@graph.links != []}
                id="pipeline-links"
                class="pointer-events-none absolute left-0 top-0"
                width={@graph.width}
                height={@graph.height}
                aria-hidden="true"
              >
                <g :for={link <- @graph.links}>
                  <path
                    d={link.path}
                    fill="none"
                    stroke-width="1.75"
                    stroke-linecap="round"
                    stroke-dasharray={if(link.kind == :feeds, do: "5 4", else: nil)}
                    class={if(link.kind == :needs, do: "stroke-blue-500", else: "stroke-blue-400")}
                  />
                  <circle cx={elem(link.from, 0)} cy={elem(link.from, 1)} r="3" class="fill-blue-500" />
                  <circle cx={elem(link.to, 0)} cy={elem(link.to, 1)} r="3" class="fill-blue-500" />
                </g>
              </svg>
            </div>
          </div>

          <div id="pipeline-inspector" class="sticky top-4 w-72 flex-none">
            <%= if @selected_step do %>
              <.inspector
                step={@selected_step}
                steps={@resolution.steps}
                also_disabled={@also_disabled}
                activity={Map.get(@activity, @selected_step.id)}
                can_edit={@can_edit}
                myself={@myself}
              />
            <% else %>
              <.overview resolution={@resolution} />
            <% end %>
          </div>
        </div>

        <.form
          :if={@can_edit}
          for={to_form(%{"note" => @note}, as: :pipeline)}
          id="pipeline-save-form"
          class="mt-4 flex items-center gap-3"
          phx-change="change_note"
          phx-submit="save"
          phx-target={@myself}
        >
          <input
            type="text"
            name="pipeline[note]"
            id="pipeline-note"
            value={@note}
            maxlength="200"
            placeholder={gettext("What changed? (optional)")}
            autocomplete="off"
            class="h-10 min-w-0 flex-1 rounded-md border-0 bg-white px-4 text-[0.96rem] text-stone-700 placeholder-stone-400 shadow-sm ring-1 ring-stone-200 focus:ring-1 focus:ring-blue-500"
          />
          <.dash_button
            :if={@draft != Pipeline.empty()}
            id="pipeline-reset"
            type="button"
            variant="ghost"
            phx-click="reset"
            phx-target={@myself}
          >
            {gettext("back to standard")}
          </.dash_button>
          <.dash_button
            id="pipeline-discard"
            type="button"
            disabled={!@dirty}
            phx-click="discard"
            phx-target={@myself}
          >
            {gettext("discard")}
          </.dash_button>
          <.dash_button id="pipeline-save" variant="primary" disabled={!@dirty or @issues != []}>
            {gettext("save new version")}
          </.dash_button>
        </.form>

        <.divider />

        <.subtitle label={gettext("Versions")} icon="general" />
        <div class="mt-6" id="pipeline-versions">
          <%= if @versions == [] do %>
            <.info_box>
              {gettext(
                "No changes saved yet. This space uses the standard pipeline; the first save becomes version 1."
              )}
            </.info_box>
          <% else %>
            <.data_table>
              <.data_table_row :for={version <- @versions} id={"pipeline-version-#{version.version}"}>
                <div class="w-14 font-medium text-stone-600">v{version.version}</div>
                <div class="min-w-0 flex-1">
                  <div class="truncate text-stone-600">{version_summary(@base, version)}</div>
                  <div class="truncate text-sm text-stone-400">
                    {version_meta(version)}
                  </div>
                </div>
                <:actions>
                  <span
                    :if={version.version == @current_version.version}
                    class="mr-4 rounded-full bg-blue-50 px-3 py-1 text-sm text-blue-500"
                  >
                    {gettext("live")}
                  </span>
                  <div :if={@can_edit and version.version != @current_version.version} class="mr-2">
                    <.dash_button
                      id={"pipeline-restore-#{version.version}"}
                      type="button"
                      variant="ghost"
                      phx-click="restore"
                      phx-value-version={version.version}
                      phx-target={@myself}
                    >
                      {gettext("load into editor")}
                    </.dash_button>
                  </div>
                </:actions>
              </.data_table_row>
            </.data_table>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  attr :step, :map, required: true
  attr :steps, :list, required: true
  attr :also_disabled, :list, required: true
  attr :activity, :map, default: nil
  attr :can_edit, :boolean, required: true
  attr :myself, :any, required: true

  defp inspector(assigns) do
    assigns = assign(assigns, :names, Map.new(assigns.steps, &{&1.id, &1.name}))

    ~H"""
    <div class="rounded-lg bg-white shadow-sm ring-1 ring-stone-200">
      <div class="flex items-start gap-3 border-b border-stone-100 px-4 py-3">
        <div class="min-w-0 flex-1">
          <div id="pipeline-inspector-title" class="font-medium text-stone-700">{@step.name}</div>
          <div class="text-sm text-stone-400">
            {@step.type_name} · {stage_label(@step.stage)}
          </div>
        </div>
        <button
          type="button"
          id="pipeline-inspector-close"
          class="text-stone-300 hover:text-stone-500"
          phx-click="close_inspector"
          phx-target={@myself}
          aria-label={gettext("Close")}
        >
          <.icon name="hero-x-mark-mini" class="h-5 w-5" />
        </button>
      </div>

      <div class="space-y-4 px-4 py-4 text-sm">
        <p :if={@step.description} class="text-stone-500">{@step.description}</p>

        <div :if={badges(@step) != [] or @step.plugin} class="flex flex-wrap gap-1.5">
          <span
            :if={@step.plugin}
            id="pipeline-step-plugin"
            class="flex items-center gap-1 rounded bg-violet-50 px-2 py-0.5 text-xs text-violet-600"
          >
            <.icon name="hero-puzzle-piece-micro" class="h-3 w-3" />
            {if @step.addon, do: gettext("Add-on"), else: gettext("Plugin")}
          </span>
          <span
            :for={badge <- badges(@step)}
            class="rounded bg-stone-100 px-2 py-0.5 text-xs text-stone-500"
          >
            {badge}
          </span>
        </div>

        <div class="rounded-md bg-stone-50 px-3 py-3 ring-1 ring-inset ring-stone-200/70">
          <div class="flex items-center gap-3">
            <div class="min-w-0 flex-1 text-stone-600" id="pipeline-step-state">
              <%= cond do %>
                <% @step.locked -> %>
                  {gettext("Always on")}
                <% @step.addon and @step.state == :enabled -> %>
                  {gettext("Added")}
                <% @step.addon -> %>
                  {gettext("Not added")}
                <% @step.state == :enabled -> %>
                  {gettext("On")}
                <% true -> %>
                  {gettext("Off")}
              <% end %>
            </div>
            <.icon
              :if={@step.locked}
              name="hero-lock-closed-mini"
              class="h-4 w-4 text-stone-300"
            />
            <.toggle
              :if={!@step.locked}
              id={"pipeline-toggle-#{@step.id}"}
              enabled={@step.state == :enabled}
              disabled={
                !@can_edit or @step.state == :auto_disabled or
                  (!@step.available and @step.state != :enabled)
              }
              phx-click="toggle_step"
              phx-value-id={@step.id}
              phx-target={@myself}
            />
          </div>
          <p class="mt-2 text-stone-400" id="pipeline-step-effect">
            <%= cond do %>
              <% @step.locked -> %>
                {gettext("Playback depends on this step, so it cannot be turned off.")}
              <% !@step.available -> %>
                {@step.unavailable_reason}
              <% @step.state == :auto_disabled -> %>
                {gettext("Off because it needs %{steps}.",
                  steps: join_names(@step.disabled_by, @names)
                )}
              <% @step.addon and @step.state == :disabled -> %>
                {gettext("Add this step to run it for new uploads.")}
              <% @step.state == :disabled -> %>
                {gettext("New uploads skip this step.")}
              <% @also_disabled != [] -> %>
                {gettext("Turning this off also turns off %{steps}.",
                  steps: join_names(@also_disabled, @names)
                )}
              <% true -> %>
                {gettext("Nothing else depends on this step.")}
            <% end %>
          </p>
        </div>

        <div :if={@step.results? and @step.state == :enabled} id="pipeline-step-results">
          <div class="text-xs font-medium uppercase tracking-wide text-stone-400">
            {gettext("Latest result")}
          </div>
          <.step_activity activity={@activity} />
        </div>

        <.form
          :if={@step.settings != []}
          for={to_form(%{}, as: :setting)}
          id={"pipeline-settings-#{@step.id}"}
          phx-change="change_setting"
          phx-submit="change_setting"
          phx-target={@myself}
          class="space-y-3"
        >
          <input type="hidden" name="step_id" value={@step.id} />
          <div :for={setting <- @step.settings}>
            <label
              for={"pipeline-setting-#{@step.id}-#{setting.key}"}
              class="flex items-center gap-2 font-medium text-stone-600"
            >
              {setting.label}
              <span :if={setting.changed} class="h-1.5 w-1.5 rounded-full bg-amber-400" />
            </label>
            <p :if={setting.description} class="mt-0.5 text-stone-400">{setting.description}</p>
            <%= case setting.type do %>
              <% "text" -> %>
                <textarea
                  name={"setting[#{setting.key}]"}
                  id={"pipeline-setting-#{@step.id}-#{setting.key}"}
                  rows="3"
                  maxlength={setting.max_length}
                  placeholder={setting.placeholder}
                  disabled={!@can_edit or @step.state != :enabled}
                  phx-debounce="300"
                  class="mt-2 w-full rounded-md border-0 bg-white px-3 py-2 text-stone-700 placeholder-stone-300 shadow-sm ring-1 ring-stone-200 focus:ring-1 focus:ring-blue-500 disabled:opacity-50"
                >{setting.input}</textarea>
              <% "integer" -> %>
                <input
                  type="number"
                  name={"setting[#{setting.key}]"}
                  id={"pipeline-setting-#{@step.id}-#{setting.key}"}
                  value={setting.input}
                  min={setting.min}
                  max={setting.max}
                  disabled={!@can_edit or @step.state != :enabled}
                  phx-debounce="300"
                  class="mt-2 w-28 rounded-md border-0 bg-white px-3 py-2 text-stone-700 shadow-sm ring-1 ring-stone-200 focus:ring-1 focus:ring-blue-500 disabled:opacity-50"
                />
              <% _ -> %>
                <input
                  type="text"
                  name={"setting[#{setting.key}]"}
                  id={"pipeline-setting-#{@step.id}-#{setting.key}"}
                  value={setting.input}
                  disabled={!@can_edit or @step.state != :enabled}
                  phx-debounce="300"
                  class="mt-2 w-full rounded-md border-0 bg-white px-3 py-2 text-stone-700 shadow-sm ring-1 ring-stone-200 focus:ring-1 focus:ring-blue-500 disabled:opacity-50"
                />
            <% end %>
          </div>
        </.form>

        <div :if={@step.inputs != []} id="pipeline-step-inputs">
          <div class="text-xs font-medium uppercase tracking-wide text-stone-400">
            {gettext("Connects to")}
          </div>
          <ul class="mt-1.5 space-y-0.5 text-stone-500">
            <li :for={input <- @step.inputs}>{input["label"]}</li>
          </ul>
        </div>

        <.connections
          :if={@step.dependencies != []}
          label={gettext("Needs")}
          step_ids={@step.dependencies}
          names={@names}
          myself={@myself}
        />
        <.connections
          :if={@step.dependents != []}
          label={gettext("Feeds")}
          step_ids={@step.dependents}
          names={@names}
          myself={@myself}
        />
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :step_ids, :list, required: true
  attr :names, :map, required: true
  attr :myself, :any, required: true

  defp connections(assigns) do
    ~H"""
    <div>
      <div class="text-xs font-medium uppercase tracking-wide text-stone-400">{@label}</div>
      <div class="mt-1.5 flex flex-wrap gap-1.5">
        <button
          :for={step_id <- @step_ids}
          type="button"
          class="rounded bg-stone-100 px-2 py-0.5 text-xs text-stone-500 hover:bg-blue-50 hover:text-blue-600"
          phx-click="select_step"
          phx-value-id={step_id}
          phx-target={@myself}
        >
          {Map.get(@names, step_id, step_id)}
        </button>
      </div>
    </div>
    """
  end

  attr :activity, :map, default: nil

  defp step_activity(assigns) do
    ~H"""
    <%= cond do %>
      <% @activity == nil -> %>
        <p class="mt-1.5 text-stone-400">
          {gettext("No results yet. They appear here after the next upload.")}
        </p>
      <% @activity.status == "executing" -> %>
        <div class="mt-1.5 text-blue-500" id="pipeline-step-progress">
          {progress_text(@activity)}
          <div class="mt-1 h-1.5 overflow-hidden rounded-full bg-stone-200">
            <div
              class="h-full rounded-full bg-blue-500 transition-[width] duration-300"
              style={"width: #{progress_percent(@activity)}%"}
            >
            </div>
          </div>
        </div>
      <% @activity.status == "failed" -> %>
        <p class="mt-1.5 text-stone-400">
          {gettext("The step failed on the latest upload. The video itself is not affected.")}
        </p>
      <% @activity.results == [] -> %>
        <p class="mt-1.5 text-stone-400">
          {gettext("Skipped on the latest upload: %{reason}.",
            reason: @activity.reason || gettext("nothing to do")
          )}
        </p>
      <% true -> %>
        <dl class="mt-1.5 space-y-1 text-stone-500">
          <div :for={result <- @activity.results} class="flex justify-between gap-3">
            <dt>{result.label}</dt>
            <dd class={["tabular-nums", result.primary && "font-medium text-stone-700"]}>
              {result.text}
            </dd>
          </div>
        </dl>
        <p class="mt-1.5 text-xs text-stone-400">
          {gettext("Latest upload, %{time}", time: Calendar.strftime(@activity.at, "%d %b %H:%M UTC"))}
        </p>
    <% end %>
    """
  end

  attr :id, :string, required: true
  attr :activity, :map, default: nil

  defp row_activity(assigns) do
    assigns = assign(assigns, :primary, primary_result(assigns.activity))

    ~H"""
    <span
      :if={@activity && @activity.status == "executing"}
      id={@id}
      class="flex-none text-[11px] tabular-nums text-blue-500"
    >
      {progress_percent(@activity)}%
    </span>
    <span
      :if={@primary}
      id={@id}
      title={@primary.label}
      class="flex-none text-[11px] font-medium tabular-nums text-stone-600"
    >
      {@primary.text}
    </span>
    """
  end

  defp primary_result(%{status: "succeeded", results: results}),
    do: Enum.find(results, & &1.primary)

  defp primary_result(_activity), do: nil

  defp progress_percent(%{progress: percent}) when is_number(percent),
    do: percent |> max(0) |> min(100) |> round()

  defp progress_percent(_activity), do: 0

  defp progress_text(activity) do
    label = activity.progress_label || gettext("processing")
    "#{progress_percent(activity)}% #{label}"
  end

  attr :resolution, :map, required: true

  defp overview(assigns) do
    steps = Enum.reject(assigns.resolution.steps, &(&1.addon and &1.state != :enabled))

    assigns =
      assigns
      |> assign(:total, length(steps))
      |> assign(:added, Enum.filter(steps, & &1.addon))
      |> assign(:off, Enum.filter(steps, &(&1.state != :enabled)))
      |> assign(
        :changed,
        Enum.filter(steps, fn step -> Enum.any?(step.settings, & &1.changed) end)
      )

    ~H"""
    <div class="rounded-lg bg-white px-4 py-4 text-sm shadow-sm ring-1 ring-stone-200">
      <div class="font-medium text-stone-700">{gettext("Pipeline overview")}</div>
      <p class="mt-1 text-stone-400">
        {gettext("Select a step to see what it needs, what it feeds and what you can change.")}
      </p>
      <dl class="mt-4 space-y-2 text-stone-500">
        <div class="flex justify-between">
          <dt>{gettext("Steps")}</dt>
          <dd class="tabular-nums" id="pipeline-count-total">{@total}</dd>
        </div>
        <div class="flex justify-between">
          <dt>{gettext("Turned off")}</dt>
          <dd class="tabular-nums" id="pipeline-count-off">{length(@off)}</dd>
        </div>
        <div class="flex justify-between">
          <dt>{gettext("Settings changed")}</dt>
          <dd class="tabular-nums" id="pipeline-count-changed">{length(@changed)}</dd>
        </div>
        <div :if={Enum.any?(@resolution.steps, & &1.addon)} class="flex justify-between">
          <dt>{gettext("Add-ons added")}</dt>
          <dd class="tabular-nums" id="pipeline-count-added">{length(@added)}</dd>
        </div>
      </dl>
      <div :if={@off != []} class="mt-4">
        <div class="text-xs font-medium uppercase tracking-wide text-stone-400">
          {gettext("Off for new uploads")}
        </div>
        <ul class="mt-1.5 space-y-1 text-stone-500">
          <li :for={step <- @off} class="truncate">{step.name}</li>
        </ul>
      </div>
    </div>
    """
  end

  attr :state, :atom, required: true

  defp state_dot(assigns) do
    ~H"""
    <span class={[
      "h-2 w-2 flex-none rounded-full",
      @state == :enabled && "bg-blue-500",
      @state == :disabled && "bg-white ring-1 ring-inset ring-stone-400",
      @state == :auto_disabled && "bg-white ring-1 ring-inset ring-stone-300"
    ]} />
    """
  end

  attr :state, :atom, required: true
  attr :label, :string, required: true

  defp legend_dot(assigns) do
    ~H"""
    <span class="flex items-center gap-1.5">
      <.state_dot state={@state} />
      {@label}
    </span>
    """
  end

  defp row_class(%{id: id}, id, _related), do: "bg-blue-100 text-stone-800"

  defp row_class(step, _selected, related) do
    [
      case Map.get(related, step.id) do
        :follows -> "bg-amber-50"
        relation when relation in [:needs, :feeds] -> "bg-blue-50"
        nil -> nil
      end,
      if(step.state == :enabled, do: "text-stone-700", else: "text-stone-400")
    ]
  end

  defp stage_label("ingest"), do: gettext("Upload")
  defp stage_label("audio"), do: gettext("Audio")
  defp stage_label("video"), do: gettext("Video")
  defp stage_label("images"), do: gettext("Images")
  defp stage_label("subtitles"), do: gettext("Subtitles")
  defp stage_label("audio_description"), do: gettext("Audio description")
  defp stage_label("publish"), do: gettext("Playback")
  defp stage_label("deliver"), do: gettext("Delivery")
  defp stage_label("quality"), do: gettext("Quality")
  defp stage_label(stage), do: stage |> String.replace("_", " ") |> String.capitalize()

  @size_labels %{
    "sd" => "480p",
    "hd" => "720p",
    "fhd" => "1080p",
    "qhd" => "1440p",
    "uhd" => "4K"
  }

  defp badges(step) do
    params = step.params

    sizes =
      (List.wrap(params["sizes"]) ++ List.wrap(params["size"]))
      |> Enum.map(&Map.get(@size_labels, &1, &1))

    codec = if is_binary(params["codec"]), do: [String.upcase(params["codec"])], else: []
    role = if is_binary(params["role"]), do: [params["role"]], else: []

    lane =
      case step.lane do
        "background" -> [gettext("runs after publishing")]
        _ -> []
      end

    sizes ++ codec ++ role ++ lane
  end

  defp join_names(step_ids, names), do: Enum.map_join(step_ids, ", ", &Map.get(names, &1, &1))

  defp version_summary(base, version) do
    %{steps_off: off, steps_added: added, settings_changed: changed} =
      Pipeline.summary(base.definition, version.overrides)

    parts =
      Enum.filter(
        [
          off > 0 && ngettext("%{count} step off", "%{count} steps off", off),
          added > 0 && ngettext("%{count} add-on added", "%{count} add-ons added", added),
          changed > 0 &&
            ngettext("%{count} setting changed", "%{count} settings changed", changed)
        ],
        & &1
      )

    if parts == [], do: gettext("Standard pipeline"), else: Enum.join(parts, " · ")
  end

  defp version_meta(version) do
    [
      version.note,
      version.created_by && version.created_by.email,
      Calendar.strftime(version.inserted_at, "%d %b %Y %H:%M UTC")
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.join(" · ")
  end

  defp restriction_notice(:ok), do: nil

  defp restriction_notice({:error, reason}) do
    copy = UsageLimits.restriction_copy(:encoding_pipeline, reason)

    Map.get(copy, :notice) ||
      gettext("The pipeline of this space is managed for you and cannot be changed here.")
  end
end
