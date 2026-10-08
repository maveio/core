defmodule MaveCoreWeb.Dashboard.Flow.Runs do
  @moduledoc false

  use MaveCoreWeb, :live_view

  import MaveCoreWeb.DashboardComponents

  alias MaveCore.Flow.Admin
  alias MaveCore.Flow.Diagnostics
  alias MaveCore.Flow.Events, as: FlowEvents
  alias MaveCoreWeb.DashboardRoutes

  @per_page 25
  @statuses ~w(all queued running succeeded failed cancelled)

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Runs"))
     |> assign(:operations_enabled, Admin.dashboard_enabled_for?(socket.assigns.current_user))
     |> assign(:operations, nil)
     |> assign(:retrying, nil)
     |> assign(:recovering, nil)
     |> assign(:page, 1)
     |> assign(:total_pages, 0)
     |> assign(:status, "all")
     |> assign(:step_type, nil)
     |> assign(:time_window, nil)
     |> assign(:expanded_run_ids, MapSet.new())
     |> maybe_subscribe_flow_events()}
  end

  def handle_params(params, _url, socket) do
    if socket.assigns.operations_enabled do
      {:noreply,
       socket
       |> assign(:status, parse_status(params["status"]))
       |> assign(:step_type, parse_step_type(params["step_type"]))
       |> assign(:time_window, parse_time_window(params["time_from"], params["time_to"]))
       |> load_operations(parse_page(params["page"]))}
    else
      {:noreply,
       push_navigate(socket, to: DashboardRoutes.videos_path(socket.assigns.current_space))}
    end
  end

  def handle_info({:flow_run_updated, %{"flow_run_id" => flow_run_id} = payload}, socket)
      when is_binary(flow_run_id) do
    {:noreply, refresh_operation_run(socket, flow_run_id, payload)}
  end

  def handle_info({:flow_run_updated, _payload}, socket) do
    {:noreply, socket}
  end

  def handle_event("previous_page", _params, socket) do
    {:noreply,
     push_patch(socket,
       to:
         runs_path(
           max(socket.assigns.page - 1, 1),
           socket.assigns.status,
           socket.assigns.step_type,
           socket.assigns.time_window
         )
     )}
  end

  def handle_event("next_page", _params, socket) do
    next_page = min(socket.assigns.page + 1, max(socket.assigns.total_pages, 1))

    {:noreply,
     push_patch(socket,
       to:
         runs_path(
           next_page,
           socket.assigns.status,
           socket.assigns.step_type,
           socket.assigns.time_window
         )
     )}
  end

  def handle_event("toggle_steps", %{"run-id" => run_id}, socket) do
    {:noreply, update(socket, :expanded_run_ids, &toggle_expanded_run(&1, run_id))}
  end

  def handle_event("retry_step", %{"run-id" => run_id, "step-id" => step_id}, socket) do
    socket = assign(socket, :retrying, {run_id, step_id})

    case Diagnostics.retry_step(run_id, step_id) do
      {:ok, _run} ->
        {:noreply,
         socket
         |> assign(:retrying, nil)
         |> load_operations(socket.assigns.page)
         |> put_flash(:info, gettext("Flow step retried"))}

      {:error, :subtree_in_progress} ->
        {:noreply,
         socket
         |> assign(:retrying, nil)
         |> put_flash(
           :error,
           gettext("This step cannot be retried while downstream work is still running.")
         )}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:retrying, nil)
         |> put_flash(:error, gettext("Could not retry flow step"))}
    end
  end

  def handle_event("recover_run", %{"run-id" => run_id}, socket) do
    socket = assign(socket, :recovering, run_id)

    case Diagnostics.recover_run(run_id) do
      {:ok, _run} ->
        {:noreply,
         socket
         |> assign(:recovering, nil)
         |> load_operations(socket.assigns.page)
         |> put_flash(:info, gettext("Flow recovery started"))}

      {:error, :subtree_in_progress} ->
        {:noreply,
         socket
         |> assign(:recovering, nil)
         |> put_flash(
           :error,
           gettext("This run cannot be recovered while downstream work is still running.")
         )}

      {:error, :nothing_to_recover} ->
        {:noreply,
         socket
         |> assign(:recovering, nil)
         |> put_flash(:error, gettext("No failed required steps can be recovered."))}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:recovering, nil)
         |> put_flash(:error, gettext("Could not recover flow run"))}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="h-full flex flex-col">
      <.title title={gettext("Runs")} />

      <div
        id="flow-runs-scroll"
        phx-hook="preserve_scroll"
        class="min-h-0 flex-1 overflow-y-auto"
      >
        <div class="max-w-screen-xl px-16 mx-auto pt-8 pb-24">
          <div class="grid grid-cols-6 gap-3">
            <.ops_stat
              label={gettext("All")}
              value={@operations.status_counts.total}
              patch={runs_path(1, "all", @step_type, @time_window)}
              active={@status == "all"}
            />
            <.ops_stat
              label={gettext("Queued")}
              value={@operations.status_counts.queued}
              patch={runs_path(1, "queued", @step_type, @time_window)}
              active={@status == "queued"}
            />
            <.ops_stat
              label={gettext("Running")}
              value={@operations.status_counts.running}
              detail={
                gettext(
                  "%{executing} executing · %{awaiting} awaiting work · %{published} playable/background",
                  executing: @operations.status_counts.executing,
                  awaiting: @operations.status_counts.awaiting_work,
                  published: @operations.status_counts.published_background
                )
              }
              patch={runs_path(1, "running", @step_type, @time_window)}
              active={@status == "running"}
            />
            <.ops_stat
              label={gettext("Succeeded")}
              value={@operations.status_counts.succeeded}
              patch={runs_path(1, "succeeded", @step_type, @time_window)}
              active={@status == "succeeded"}
            />
            <.ops_stat
              label={gettext("Failed")}
              value={@operations.status_counts.failed}
              patch={runs_path(1, "failed", @step_type, @time_window)}
              active={@status == "failed"}
              tone="error"
            />
            <.ops_stat
              label={gettext("Cancelled")}
              value={@operations.status_counts.cancelled}
              patch={runs_path(1, "cancelled", @step_type, @time_window)}
              active={@status == "cancelled"}
            />
          </div>

          <.performance_panel
            performance={@operations.performance}
            status={@status}
            selected_step_type={@step_type}
            selected_time_window={@time_window}
          />

          <div
            :if={@step_type}
            class="mt-4 flex items-center justify-between rounded-md border border-blue-200/70 bg-blue-50/70 px-4 py-3 text-sm"
          >
            <div class="min-w-0 text-blue-700">
              {gettext("Inspecting")}
              <span class="font-mono">{@step_type}</span>
              <span class="text-blue-400">{gettext("in the runs below")}</span>
            </div>
            <.link
              patch={runs_path(1, @status, nil, @time_window)}
              class="text-xs text-blue-500 hover:text-blue-600"
            >
              {gettext("Clear")}
            </.link>
          </div>

          <div
            :if={@time_window}
            class="mt-4 flex items-center justify-between rounded-md border border-blue-200/70 bg-blue-50/70 px-4 py-3 text-sm"
          >
            <div class="min-w-0 text-blue-700">
              {gettext("Inspecting")}
              <span class="font-mono">{time_window_label(@time_window)}</span>
              <span class="text-blue-400">{gettext("in the runs below")}</span>
            </div>
            <.link
              patch={runs_path(1, @status, @step_type, nil)}
              class="text-xs text-blue-500 hover:text-blue-600"
            >
              {gettext("Clear")}
            </.link>
          </div>

          <div :if={@operations.attention_runs == []} class="mt-6">
            <.info_box>{gettext("No runs match your current filter.")}</.info_box>
          </div>

          <.data_table_grid
            :if={@operations.attention_runs != []}
            id="flow-runs-table"
            class="mt-6"
            columns={flow_runs_grid_columns()}
            aria-label={gettext("Flow runs requiring attention")}
          >
            <:header>
              <.data_table_grid_header_cell>{gettext("State")}</.data_table_grid_header_cell>
              <.data_table_grid_header_cell>{gettext("Space")}</.data_table_grid_header_cell>
              <.data_table_grid_header_cell>{gettext("Video")}</.data_table_grid_header_cell>
              <.data_table_grid_header_cell>{gettext("Step")}</.data_table_grid_header_cell>
              <.data_table_grid_header_cell>{gettext("Timing")}</.data_table_grid_header_cell>
              <.data_table_grid_header_cell>{gettext("Error")}</.data_table_grid_header_cell>
            </:header>

            <%= for run <- @operations.attention_runs do %>
              <.data_table_grid_row
                id={"run-row-#{run.id}"}
                columns={flow_runs_grid_columns()}
              >
                <.data_table_grid_cell
                  label={gettext("State")}
                  content_class="flex min-w-0 items-start gap-2"
                >
                  <button
                    id={"toggle-run-#{run.id}"}
                    type="button"
                    phx-click="toggle_steps"
                    phx-value-run-id={run.id}
                    aria-controls={"run-steps-#{run.id}"}
                    aria-expanded={expanded_run?(@expanded_run_ids, run.id)}
                    class="mt-px flex h-5 w-5 flex-none items-center justify-center rounded-sm text-stone-300 transition hover:bg-stone-100 hover:text-stone-500"
                    title={gettext("Steps")}
                  >
                    <MaveCoreWeb.DashboardComponents.icon
                      name="hero-chevron-right"
                      class={[
                        "size-4 transition-transform",
                        expanded_run?(@expanded_run_ids, run.id) && "rotate-90"
                      ]}
                    />
                  </button>
                  <div class="min-w-0">
                    <div class={["text-xs font-medium", reason_class(run.reason)]}>
                      {reason_label(run.reason)}
                    </div>
                    <div
                      :if={run.published?}
                      class="mt-1 text-[0.68rem] font-medium text-emerald-500"
                    >
                      {gettext("playable · background work")}
                    </div>
                    <div class="mt-1 font-mono text-[0.68rem] text-stone-300 select-text">
                      {short_id(run.id)}
                    </div>
                  </div>
                </.data_table_grid_cell>

                <.data_table_grid_cell label={gettext("Space")}>
                  <div class="truncate text-stone-700">
                    {run.space_domain || run.space_hash || "-"}
                  </div>
                  <div class="mt-1 font-mono text-[0.68rem] text-stone-300">
                    {run.space_hash || "-"}
                  </div>
                </.data_table_grid_cell>

                <.data_table_grid_cell label={gettext("Video")}>
                  <.run_embed_action
                    embed_hash={run.public_embed_id || run.embed_hash}
                    action={open_action(run)}
                  />
                  <div class="mt-1 truncate text-xs text-stone-300">
                    {run.template_slug || gettext("custom")}
                    <span :if={run.flow_version_number}>v{run.flow_version_number}</span>
                  </div>
                  <div class="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs">
                    <span class="text-stone-300">{steps_label(run.steps)}</span>
                    <.gpu_encoding_booster_badge steps={run.steps} />
                    <.encoding_booster_badge steps={run.steps} />
                    <.run_open_action action={open_action(run)} />
                    <.inspection_actions actions={inspection_actions_for(run)} />
                    <button
                      :if={run.recoverable?}
                      id={"recover-run-#{run.id}"}
                      type="button"
                      phx-click="recover_run"
                      phx-value-run-id={run.id}
                      class="text-blue-400 hover:text-blue-500 disabled:opacity-40"
                      disabled={@recovering == run.id}
                    >
                      {gettext("Recover")}
                    </button>
                    <button
                      :if={run.retry_step_id}
                      type="button"
                      phx-click="retry_step"
                      phx-value-run-id={run.id}
                      phx-value-step-id={run.retry_step_id}
                      class="text-stone-400 hover:text-stone-500 disabled:opacity-40"
                      disabled={@retrying == {run.id, run.retry_step_id}}
                    >
                      {gettext("Retry")}
                    </button>
                  </div>
                </.data_table_grid_cell>

                <.data_table_grid_cell label={gettext("Step")}>
                  <div class="truncate text-sm text-stone-500">{run.step_type || "-"}</div>
                  <div class="mt-1 truncate font-mono text-[0.68rem] text-stone-300">
                    {run.step_id || "-"} - {run.step_status || run.status}
                  </div>
                  <div class="mt-1 truncate text-[0.68rem] text-stone-300">
                    {execution_label(run.execution_metadata)}
                  </div>
                  <div
                    :if={ffmpeg_performance_label(run.execution_metadata)}
                    class="mt-1 truncate text-[0.68rem] text-blue-400"
                  >
                    {ffmpeg_performance_label(run.execution_metadata)}
                  </div>
                  <div
                    :if={execution_progress_percent(run.execution_metadata, run.step_status)}
                    class="mt-1 flex items-center gap-2 text-[0.68rem] text-blue-500"
                  >
                    <div class="h-1.5 w-20 overflow-hidden rounded-full bg-stone-200">
                      <div
                        class="h-full rounded-full bg-blue-500 transition-[width] duration-300"
                        style={"width: #{execution_progress_percent(run.execution_metadata, run.step_status)}%;"}
                      >
                      </div>
                    </div>
                    <span>{execution_progress_label(run.execution_metadata)}</span>
                  </div>
                </.data_table_grid_cell>

                <.data_table_grid_cell label={gettext("Timing")} class="text-xs">
                  <div class="text-stone-500">{timing_total(run)}</div>
                  <div class="mt-1 text-[0.68rem] text-stone-300">
                    {timing_step_total_detail(run)}
                  </div>
                  <div class="mt-1 text-[0.68rem] text-stone-300">
                    {timing_breakdown(run)}
                  </div>
                </.data_table_grid_cell>

                <.data_table_grid_cell label={gettext("Error")}>
                  <div class="truncate text-xs text-red-400/80">{run.error || "-"}</div>
                </.data_table_grid_cell>
              </.data_table_grid_row>

              <div
                :if={expanded_run?(@expanded_run_ids, run.id)}
                id={"run-steps-#{run.id}"}
                class="border-b border-stone-200/40 bg-stone-50/60 px-6 py-3 last:border-b-0"
              >
                <div class="pl-7">
                  <.data_table_grid
                    columns={flow_run_steps_grid_columns()}
                    class="rounded-sm shadow-none ring-stone-200/70"
                    aria-label={gettext("Run steps")}
                  >
                    <:header>
                      <.data_table_grid_header_cell>
                        {gettext("Step")}
                      </.data_table_grid_header_cell>
                      <.data_table_grid_header_cell>
                        {gettext("State")}
                      </.data_table_grid_header_cell>
                      <.data_table_grid_header_cell>
                        {gettext("Timing / Executor")}
                      </.data_table_grid_header_cell>
                      <.data_table_grid_header_cell>
                        {gettext("Error")}
                      </.data_table_grid_header_cell>
                    </:header>
                    <.data_table_grid_row
                      :for={step <- run.steps}
                      id={"run-step-#{run.id}-#{step.step_id}"}
                      columns={flow_run_steps_grid_columns()}
                      class={[
                        "text-xs",
                        @step_type == step.step_type && "bg-blue-50/60"
                      ]}
                    >
                      <.data_table_grid_cell label={gettext("Step")}>
                        <div class="truncate text-sm text-stone-500">{step.step_type || "-"}</div>
                        <div class="mt-1 truncate font-mono text-[0.68rem] text-stone-300">
                          {step.step_id || "-"} - {gettext("attempt")} {step.step_attempt || 0}
                        </div>
                        <div class="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1">
                          <.inspection_actions actions={inspection_actions_for(run, step)} />
                          <button
                            :if={retryable_step?(step)}
                            id={"retry-step-#{run.id}-#{step.step_id}"}
                            type="button"
                            phx-click="retry_step"
                            phx-value-run-id={run.id}
                            phx-value-step-id={step.step_id}
                            class="text-stone-400 hover:text-stone-500 disabled:opacity-40"
                            disabled={@retrying == {run.id, step.step_id}}
                          >
                            {gettext("Retry")}
                          </button>
                        </div>
                      </.data_table_grid_cell>
                      <.data_table_grid_cell label={gettext("State")}>
                        <div class={["font-medium", step_status_class(step.step_status)]}>
                          {step.step_status || "-"}
                        </div>
                        <div
                          :if={execution_progress_percent(step.execution_metadata, step.step_status)}
                          class="mt-2 text-[0.68rem] text-blue-500"
                        >
                          <div class="mb-1">{execution_progress_label(step.execution_metadata)}</div>
                          <div class="h-1.5 w-24 overflow-hidden rounded-full bg-stone-200">
                            <div
                              class="h-full rounded-full bg-blue-500 transition-[width] duration-300"
                              style={"width: #{execution_progress_percent(step.execution_metadata, step.step_status)}%;"}
                            >
                            </div>
                          </div>
                        </div>
                      </.data_table_grid_cell>
                      <.data_table_grid_cell label={gettext("Timing / Executor")}>
                        <div class="text-stone-500">{timing_total(step)}</div>
                        <div class="mt-1 text-[0.68rem] text-stone-300">
                          {timing_breakdown(step)}
                        </div>
                        <div class="truncate text-stone-500">
                          {execution_label(step.execution_metadata)}
                        </div>
                        <.encoding_booster_badge
                          step_type={step.step_type}
                          execution_metadata={step.execution_metadata}
                        />
                        <.gpu_encoding_booster_badge
                          step_type={step.step_type}
                          execution_metadata={step.execution_metadata}
                        />
                        <div class="mt-1 truncate font-mono text-[0.68rem] text-stone-300">
                          {execution_detail(step.execution_metadata)}
                        </div>
                        <div
                          :if={ffmpeg_performance_label(step.execution_metadata)}
                          class="mt-1 truncate text-[0.68rem] text-blue-400"
                        >
                          {ffmpeg_performance_label(step.execution_metadata)}
                        </div>
                      </.data_table_grid_cell>
                      <.data_table_grid_cell label={gettext("Error")}>
                        <div class="truncate text-red-400/80">{step.error || "-"}</div>
                      </.data_table_grid_cell>
                    </.data_table_grid_row>
                  </.data_table_grid>
                </div>
              </div>
            <% end %>
          </.data_table_grid>
        </div>
      </div>

      <%= if @operations.total_entries > 0 do %>
        <.footer page={@page} total_pages={@total_pages} />
      <% else %>
        <.footer />
      <% end %>
    </div>
    """
  end

  defp flow_runs_grid_columns do
    "@5xl:grid-cols-[6.5rem_minmax(7rem,0.8fr)_minmax(11rem,1.15fr)_minmax(10rem,1fr)_minmax(9rem,0.9fr)_minmax(9rem,1fr)]"
  end

  defp flow_run_steps_grid_columns do
    "@5xl:grid-cols-[minmax(13rem,1.1fr)_6rem_minmax(15rem,1.2fr)_minmax(10rem,1fr)]"
  end

  defp retryable_step?(%{step_status: status}) when status in ["failed", "succeeded"], do: true
  defp retryable_step?(_step), do: false

  attr(:label, :string, required: true)
  attr(:value, :integer, required: true)
  attr(:tone, :string, default: "neutral")
  attr(:patch, :string, required: true)
  attr(:active, :boolean, default: false)
  attr(:detail, :string, default: nil)

  defp ops_stat(assigns) do
    ~H"""
    <.link
      patch={@patch}
      class={[
        "rounded-md border px-4 py-3 transition",
        @active && "border-blue-400 bg-blue-50/60 shadow-sm",
        !@active && "border-stone-200/60 hover:border-blue-300 hover:bg-stone-50"
      ]}
    >
      <div class={["text-xs", @active && "text-blue-500", !@active && "text-stone-300"]}>
        {@label}
      </div>
      <div class={[
        "mt-2 text-2xl font-medium",
        @active && "text-blue-600",
        !@active && @tone == "error" && "text-red-500",
        !@active && @tone != "error" && "text-stone-600"
      ]}>
        {@value}
      </div>
      <div :if={@detail} class="mt-1 text-[0.68rem] text-stone-400">
        {@detail}
      </div>
    </.link>
    """
  end

  attr(:performance, :map, required: true)
  attr(:status, :string, default: "all")
  attr(:selected_step_type, :string, default: nil)
  attr(:selected_time_window, :any, default: nil)

  defp performance_panel(assigns) do
    performance = normalize_performance(assigns.performance)

    assigns =
      assigns
      |> assign(:performance, performance)
      |> assign(:runs, performance.runs)
      |> assign(:period_label, period_label(performance))
      |> assign(:throughput_peak, throughput_peak(performance.throughput))
      |> assign(:queue_bottleneck, top_metric(performance.step_metrics, :p95_queue_wait_ms))
      |> assign(:execution_bottleneck, top_metric(performance.step_metrics, :p95_execution_ms))
      |> assign(:visible_step_metrics, Enum.take(performance.step_metrics, 6))
      |> assign(:visible_ffmpeg_metrics, Enum.take(performance.ffmpeg_metrics, 12))

    ~H"""
    <div class="mt-6">
      <div class="grid gap-4 xl:grid-cols-[minmax(18rem,0.85fr)_minmax(26rem,1.15fr)]">
        <div class="overflow-hidden rounded-md ring-1 ring-stone-200/60 bg-white shadow-sm">
          <div class="border-b border-stone-200/60 px-4 py-3">
            <div class="text-sm font-medium text-stone-600">{gettext("Performance")}</div>
            <div class="mt-1 text-[0.68rem] uppercase tracking-wide text-stone-300">
              {@period_label}
            </div>
          </div>
          <div class="grid grid-cols-2 divide-x divide-y divide-stone-200/60">
            <.performance_stat
              label={gettext("Runs")}
              value={format_count(@runs.total)}
              detail={"#{format_count(@runs.succeeded)} #{gettext("ok")} / #{format_count(@runs.failed)} #{gettext("failed")}"}
            />
            <.performance_stat
              label={gettext("Flow p95")}
              value={format_duration(@runs.p95_duration_ms)}
              detail={"#{gettext("avg")} #{format_duration(@runs.avg_duration_ms)}"}
            />
            <.performance_stat
              label={gettext("Queue p95")}
              value={metric_duration(@queue_bottleneck, :p95_queue_wait_ms)}
              detail={metric_step_type(@queue_bottleneck)}
            />
            <.performance_stat
              label={gettext("Exec p95")}
              value={metric_duration(@execution_bottleneck, :p95_execution_ms)}
              detail={metric_step_type(@execution_bottleneck)}
            />
          </div>
        </div>

        <div class="overflow-hidden rounded-md ring-1 ring-stone-200/60 bg-white shadow-sm">
          <div class="flex items-center justify-between border-b border-stone-200/60 px-4 py-3">
            <div>
              <div class="text-sm font-medium text-stone-600">{gettext("Throughput")}</div>
              <div class="mt-1 text-[0.68rem] uppercase tracking-wide text-stone-300">
                {@period_label}
              </div>
            </div>
            <div class="text-xs text-stone-300">
              <.link
                :if={@selected_time_window}
                patch={runs_path(1, @status, @selected_step_type, nil)}
                class="mr-3 text-blue-400 hover:text-blue-500"
              >
                {gettext("Clear time")}
              </.link>
              {format_count(@runs.total)} {gettext("runs")}
            </div>
          </div>
          <div class="px-4 pb-4 pt-3">
            <div class="flex h-28 items-end gap-1">
              <div :for={bucket <- @performance.throughput} class="flex min-w-0 flex-1 items-end">
                <.link
                  id={"throughput-bucket-#{bucket_key(bucket)}"}
                  patch={runs_path(1, @status, @selected_step_type, bucket_time_window(bucket))}
                  class={[
                    "relative flex h-24 w-full items-end overflow-hidden rounded-sm bg-stone-100 transition hover:bg-blue-50",
                    selected_time_bucket?(@selected_time_window, bucket) &&
                      "ring-2 ring-blue-400 ring-offset-1"
                  ]}
                  title={throughput_title(bucket)}
                >
                  <div
                    class="w-full rounded-t-sm bg-blue-300/80"
                    style={"height: #{throughput_bar_height(bucket.total, @throughput_peak)}%"}
                  >
                  </div>
                  <div
                    :if={bucket.failed > 0}
                    class="absolute bottom-0 left-0 right-0 bg-red-400/75"
                    style={"height: #{throughput_bar_height(bucket.failed, @throughput_peak)}%"}
                  >
                  </div>
                </.link>
              </div>
            </div>
            <div class="mt-2 flex justify-between text-[0.68rem] text-stone-300">
              <span>{bucket_time_label(List.first(@performance.throughput))}</span>
              <span>{bucket_time_label(List.last(@performance.throughput))}</span>
            </div>
          </div>
        </div>
      </div>

      <div class="mt-4 overflow-hidden rounded-md ring-1 ring-stone-200/60 bg-white shadow-sm">
        <div class="flex items-center justify-between border-b border-stone-200/60 px-4 py-3">
          <div class="text-sm font-medium text-stone-600">{gettext("Slowest steps")}</div>
          <div class="text-[0.68rem] uppercase tracking-wide text-stone-300">{@period_label}</div>
        </div>
        <div
          :if={@visible_step_metrics != []}
          class="grid grid-cols-[minmax(14rem,1.1fr)_5rem_repeat(4,minmax(7rem,0.8fr))] gap-4 border-b border-stone-200/60 bg-stone-50 px-4 py-2 text-[0.68rem] uppercase tracking-wide text-stone-400"
        >
          <div>{gettext("Step")}</div>
          <div>{gettext("Count")}</div>
          <div>{gettext("Avg deps")}</div>
          <div>{gettext("P95 queue")}</div>
          <div>{gettext("P95 exec")}</div>
          <div>{gettext("P95 total")}</div>
        </div>
        <div
          :for={metric <- @visible_step_metrics}
          class={[
            "grid grid-cols-[minmax(14rem,1.1fr)_5rem_repeat(4,minmax(7rem,0.8fr))] gap-4 border-b border-stone-200/40 px-4 py-3 text-xs text-stone-500 last:border-b-0",
            @selected_step_type == metric.step_type && "bg-blue-50/70"
          ]}
        >
          <div class="min-w-0 truncate font-mono">
            <.link
              :if={metric.step_type}
              id={"inspect-step-#{step_type_dom_id(metric.step_type)}"}
              patch={runs_path(1, @status, metric.step_type, @selected_time_window)}
              class={[
                "hover:text-blue-500",
                @selected_step_type == metric.step_type && "text-blue-600",
                @selected_step_type != metric.step_type && "text-stone-600"
              ]}
            >
              {metric.step_type}
            </.link>
            <span :if={!metric.step_type}>-</span>
          </div>
          <div>{format_count(metric.count)}</div>
          <div>{format_duration(metric.avg_dependency_wait_ms)}</div>
          <div>{format_duration(metric.p95_queue_wait_ms)}</div>
          <div>{format_duration(metric.p95_execution_ms)}</div>
          <div>{format_duration(metric.p95_ready_total_ms)}</div>
        </div>
        <div :if={@visible_step_metrics == []} class="px-4 py-6 text-sm text-stone-300">
          {gettext("No completed step timings yet.")}
        </div>
      </div>

      <div class="mt-4 overflow-hidden rounded-md ring-1 ring-stone-200/60 bg-white shadow-sm">
        <div class="flex items-center justify-between border-b border-stone-200/60 px-4 py-3">
          <div class="text-sm font-medium text-stone-600">{gettext("FFmpeg by hardware")}</div>
          <div class="text-[0.68rem] uppercase tracking-wide text-stone-300">{@period_label}</div>
        </div>
        <div
          :if={@visible_ffmpeg_metrics != []}
          class="grid grid-cols-[minmax(12rem,0.9fr)_minmax(16rem,1.4fr)_5rem_repeat(4,minmax(7rem,0.7fr))] gap-4 border-b border-stone-200/60 bg-stone-50 px-4 py-2 text-[0.68rem] uppercase tracking-wide text-stone-400"
        >
          <div>{gettext("Hardware")}</div>
          <div>{gettext("Workload")}</div>
          <div>{gettext("Count")}</div>
          <div>{gettext("Median speed")}</div>
          <div>{gettext("P10 speed")}</div>
          <div>{gettext("Avg FPS")}</div>
          <div>{gettext("P95 FFmpeg")}</div>
        </div>
        <div
          :for={metric <- @visible_ffmpeg_metrics}
          class="grid grid-cols-[minmax(12rem,0.9fr)_minmax(16rem,1.4fr)_5rem_repeat(4,minmax(7rem,0.7fr))] gap-4 border-b border-stone-200/40 px-4 py-3 text-xs text-stone-500 last:border-b-0"
        >
          <div class="min-w-0 truncate font-mono text-stone-600">
            {metric.hardware_profile}
          </div>
          <div class="min-w-0">
            <div class="truncate font-mono text-stone-600">{metric.step_type}</div>
            <div class="mt-1 truncate text-[0.68rem] text-stone-300">
              {ffmpeg_workload_label(metric)}
            </div>
          </div>
          <div>{format_count(metric.count)}</div>
          <div>{format_speed(metric.p50_speed_x)}</div>
          <div>{format_speed(metric.p10_speed_x)}</div>
          <div>{format_fps(metric.avg_fps)}</div>
          <div>{format_duration(metric.p95_ffmpeg_elapsed_ms)}</div>
        </div>
        <div :if={@visible_ffmpeg_metrics == []} class="px-4 py-6 text-sm text-stone-300">
          {gettext("No completed FFmpeg performance samples yet.")}
        </div>
      </div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:detail, :string, default: nil)

  defp performance_stat(assigns) do
    ~H"""
    <div class="px-4 py-3">
      <div class="text-[0.68rem] uppercase tracking-wide text-stone-300">{@label}</div>
      <div class="mt-2 text-xl font-medium text-stone-700">{@value}</div>
      <div class="mt-1 truncate text-xs text-stone-300">{@detail || "-"}</div>
    </div>
    """
  end

  attr(:embed_hash, :string, default: nil)
  attr(:action, :map, default: nil)

  defp run_embed_action(%{embed_hash: embed_hash, action: %{method: :post, to: to}} = assigns)
       when is_binary(embed_hash) and embed_hash != "" and is_binary(to) do
    hidden = Map.get(assigns.action, :hidden, [])
    assigns = assign(assigns, :hidden, hidden)

    ~H"""
    <.form for={%{}} action={@action.to} method="post" class="min-w-0">
      <input :for={{name, value} <- @hidden} type="hidden" name={name} value={value} />
      <button
        type="submit"
        title={@embed_hash}
        class="block max-w-full truncate font-mono text-xs text-blue-500 hover:text-blue-600"
      >
        {@embed_hash}
      </button>
    </.form>
    """
  end

  defp run_embed_action(%{embed_hash: embed_hash, action: %{method: :get, to: to}} = assigns)
       when is_binary(embed_hash) and embed_hash != "" and is_binary(to) do
    ~H"""
    <.link
      navigate={@action.to}
      title={@embed_hash}
      class="block truncate font-mono text-xs text-blue-500 hover:text-blue-600"
    >
      {@embed_hash}
    </.link>
    """
  end

  defp run_embed_action(assigns) do
    ~H"""
    <div class="truncate font-mono text-xs text-stone-500">{@embed_hash || "-"}</div>
    """
  end

  attr(:action, :map, default: nil)

  defp run_open_action(%{action: %{method: :post, to: to}} = assigns) when is_binary(to) do
    hidden = Map.get(assigns.action, :hidden, [])
    assigns = assign(assigns, :hidden, hidden)

    ~H"""
    <.form for={%{}} action={@action.to} method="post">
      <input :for={{name, value} <- @hidden} type="hidden" name={name} value={value} />
      <button type="submit" class="text-blue-400 hover:text-blue-500">
        {Map.get(@action, :label) || gettext("Open")}
      </button>
    </.form>
    """
  end

  defp run_open_action(%{action: %{method: :get, to: to}} = assigns) when is_binary(to) do
    ~H"""
    <.link navigate={@action.to} class="text-blue-400 hover:text-blue-500">
      {Map.get(@action, :label) || gettext("Open")}
    </.link>
    """
  end

  defp run_open_action(assigns) do
    ~H"""
    """
  end

  attr(:actions, :list, default: [])

  defp inspection_actions(assigns) do
    ~H"""
    <.link
      :for={action <- @actions}
      :if={is_binary(Map.get(action, :to))}
      href={action.to}
      target={Map.get(action, :target) || "_blank"}
      rel="noopener noreferrer"
      class="text-blue-400 hover:text-blue-500"
    >
      {Map.get(action, :label) || gettext("Inspect")}
    </.link>
    """
  end

  defp maybe_subscribe_flow_events(%{assigns: %{operations_enabled: true}} = socket) do
    if connected?(socket) do
      :ok = FlowEvents.subscribe()
    end

    socket
  end

  defp maybe_subscribe_flow_events(socket), do: socket

  defp load_operations(socket, page) do
    operations =
      Diagnostics.global_diagnostics(
        page: page,
        limit: @per_page,
        status: socket.assigns.status,
        step_type: socket.assigns.step_type,
        time_window: socket.assigns.time_window
      )

    socket
    |> assign(:operations, operations)
    |> assign(:page, operations.page)
    |> assign(:total_pages, operations.total_pages)
  end

  defp refresh_operation_run(%{assigns: %{operations: nil}} = socket, _flow_run_id, _payload) do
    load_operations(socket, socket.assigns.page)
  end

  defp refresh_operation_run(socket, flow_run_id, payload) do
    operations = socket.assigns.operations
    current_run = Enum.find(operations.attention_runs, &(&1.id == flow_run_id))

    if current_run do
      operation =
        Diagnostics.run_diagnostics(flow_run_id,
          status: socket.assigns.status,
          step_type: socket.assigns.step_type,
          time_window: socket.assigns.time_window
        )

      operations =
        case operation do
          nil -> remove_attention_run(operations, current_run, Map.get(payload, "status"))
          operation -> replace_attention_run(operations, current_run, operation)
        end

      assign(socket, :operations, operations)
    else
      socket
    end
  end

  defp replace_attention_run(operations, current_run, updated_run) do
    attention_runs =
      Enum.map(operations.attention_runs, fn run ->
        if run.id == updated_run.id, do: updated_run, else: run
      end)

    operations
    |> Map.put(:attention_runs, attention_runs)
    |> adjust_status_counts(current_run.status, updated_run.status)
  end

  defp remove_attention_run(operations, current_run, updated_status) do
    attention_runs = Enum.reject(operations.attention_runs, &(&1.id == current_run.id))

    operations
    |> Map.put(:attention_runs, attention_runs)
    |> Map.update(:total_entries, 0, &max(&1 - 1, 0))
    |> adjust_status_counts(current_run.status, updated_status)
  end

  defp adjust_status_counts(operations, status, status), do: operations

  defp adjust_status_counts(operations, old_status, new_status)
       when is_binary(old_status) and is_binary(new_status) do
    Map.update!(operations, :status_counts, fn counts ->
      counts
      |> bump_status_count(old_status, -1)
      |> bump_status_count(new_status, 1)
    end)
  end

  defp adjust_status_counts(operations, _old_status, _new_status), do: operations

  defp bump_status_count(counts, status, delta) do
    case status_count_key(status) do
      nil -> counts
      key -> Map.update!(counts, key, &max(&1 + delta, 0))
    end
  end

  defp status_count_key("queued"), do: :queued
  defp status_count_key("running"), do: :running
  defp status_count_key("succeeded"), do: :succeeded
  defp status_count_key("failed"), do: :failed
  defp status_count_key("cancelled"), do: :cancelled
  defp status_count_key(_status), do: nil

  defp runs_path(page, status, step_type, time_window) do
    params =
      %{}
      |> maybe_put("page", page, page > 1)
      |> maybe_put("status", status, status != "all")
      |> maybe_put("step_type", step_type, is_binary(step_type) and step_type != "")
      |> maybe_put(
        "time_from",
        time_window_from(time_window),
        match?({%DateTime{}, %DateTime{}}, time_window)
      )
      |> maybe_put(
        "time_to",
        time_window_to(time_window),
        match?({%DateTime{}, %DateTime{}}, time_window)
      )

    case URI.encode_query(params) do
      "" -> "/flow/runs"
      encoded -> "/flow/runs?#{encoded}"
    end
  end

  defp maybe_put(params, key, value, true), do: Map.put(params, key, value)
  defp maybe_put(params, _key, _value, false), do: params

  defp parse_status(status) when status in @statuses, do: status
  defp parse_status(_status), do: "all"

  defp parse_step_type(step_type) when is_binary(step_type) do
    step_type = String.trim(step_type)

    if step_type == "" or String.length(step_type) > 160 do
      nil
    else
      step_type
    end
  end

  defp parse_step_type(_step_type), do: nil

  defp parse_time_window(from, to) when is_binary(from) and is_binary(to) do
    with {from_unix, ""} <- Integer.parse(from),
         {to_unix, ""} <- Integer.parse(to),
         {:ok, from_datetime} <- DateTime.from_unix(from_unix),
         {:ok, to_datetime} <- DateTime.from_unix(to_unix),
         :lt <- DateTime.compare(from_datetime, to_datetime) do
      {from_datetime, to_datetime}
    else
      _invalid -> nil
    end
  end

  defp parse_time_window(_from, _to), do: nil

  defp parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> 1
    end
  end

  defp parse_page(_page), do: 1

  defp toggle_expanded_run(expanded_run_ids, run_id) do
    expanded_run_ids = expanded_run_ids || MapSet.new()

    if MapSet.member?(expanded_run_ids, run_id) do
      MapSet.delete(expanded_run_ids, run_id)
    else
      MapSet.put(expanded_run_ids, run_id)
    end
  end

  defp expanded_run?(expanded_run_ids, run_id) do
    MapSet.member?(expanded_run_ids || MapSet.new(), run_id)
  end

  defp reason_label(:failed), do: gettext("failed")
  defp reason_label(:failed_step), do: gettext("failed step")
  defp reason_label(:stale_step), do: gettext("stale step")
  defp reason_label(:stale_run), do: gettext("stale run")
  defp reason_label(:executing), do: gettext("executing")
  defp reason_label(:waiting), do: gettext("awaiting work")
  defp reason_label(:cancelled), do: gettext("cancelled")
  defp reason_label(:succeeded), do: gettext("succeeded")
  defp reason_label(_reason), do: gettext("attention")

  defp reason_class(reason) when reason in [:failed, :failed_step], do: "text-red-500"
  defp reason_class(reason) when reason in [:stale_step, :stale_run], do: "text-amber-500"
  defp reason_class(:executing), do: "text-blue-500"
  defp reason_class(:waiting), do: "text-amber-500"
  defp reason_class(:succeeded), do: "text-emerald-500"
  defp reason_class(_reason), do: "text-stone-400"

  defp step_status_class(status) when status in ["failed"], do: "text-red-500"
  defp step_status_class(status) when status in ["scheduled", "executing"], do: "text-blue-500"
  defp step_status_class("queued"), do: "text-amber-500"
  defp step_status_class("succeeded"), do: "text-emerald-500"
  defp step_status_class(_status), do: "text-stone-400"

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(_id), do: "-"

  defp steps_label([_step]), do: gettext("1 step")
  defp steps_label(steps) when is_list(steps), do: "#{length(steps)} #{gettext("steps")}"
  defp steps_label(_steps), do: gettext("0 steps")

  defp normalize_performance(nil) do
    %{
      since_hours: 24,
      runs: %{
        total: 0,
        queued: 0,
        running: 0,
        succeeded: 0,
        failed: 0,
        cancelled: 0,
        completed: 0,
        avg_duration_ms: nil,
        p95_duration_ms: nil
      },
      throughput: [],
      step_metrics: [],
      ffmpeg_metrics: []
    }
  end

  defp normalize_performance(performance) when is_map(performance) do
    performance
    |> Map.put_new(:runs, normalize_performance(nil).runs)
    |> Map.put_new(:throughput, [])
    |> Map.put_new(:step_metrics, [])
    |> Map.put_new(:ffmpeg_metrics, [])
    |> Map.put_new(:since_hours, 24)
  end

  defp period_label(%{since_hours: since_hours}), do: "#{gettext("Last")} #{since_hours}h"

  defp top_metric(metrics, key) when is_list(metrics) do
    metrics
    |> Enum.filter(&(is_integer(Map.get(&1, key)) and Map.get(&1, key) > 0))
    |> Enum.max_by(&Map.get(&1, key), fn -> nil end)
  end

  defp top_metric(_metrics, _key), do: nil

  defp metric_duration(nil, _key), do: "-"
  defp metric_duration(metric, key), do: format_duration(Map.get(metric, key))

  defp metric_step_type(nil), do: "-"
  defp metric_step_type(%{step_type: step_type}) when is_binary(step_type), do: step_type
  defp metric_step_type(_metric), do: "-"

  defp step_type_dom_id(step_type) when is_binary(step_type) do
    step_type
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp step_type_dom_id(_step_type), do: "unknown"

  defp time_window_from({%DateTime{} = from, %DateTime{}}) do
    from |> DateTime.to_unix() |> Integer.to_string()
  end

  defp time_window_from(_time_window), do: nil

  defp time_window_to({%DateTime{}, %DateTime{} = to}) do
    to |> DateTime.to_unix() |> Integer.to_string()
  end

  defp time_window_to(_time_window), do: nil

  defp time_window_label({%DateTime{} = from, %DateTime{} = to}) do
    "#{Calendar.strftime(from, "%m/%d %H:%M")}-#{Calendar.strftime(to, "%H:%M UTC")}"
  end

  defp time_window_label(_time_window), do: "-"

  defp throughput_peak(buckets) when is_list(buckets) do
    buckets
    |> Enum.map(&Map.get(&1, :total, 0))
    |> Enum.max(fn -> 0 end)
    |> max(1)
  end

  defp throughput_peak(_buckets), do: 1

  defp throughput_bar_height(0, _peak), do: 0

  defp throughput_bar_height(value, peak)
       when is_integer(value) and is_integer(peak) and peak > 0 do
    value
    |> Kernel./(peak)
    |> Kernel.*(100)
    |> round()
    |> max(6)
  end

  defp throughput_bar_height(_value, _peak), do: 0

  defp bucket_time_window(%{bucket: %DateTime{} = bucket}) do
    {bucket, DateTime.add(bucket, 60 * 60, :second)}
  end

  defp bucket_time_window(_bucket), do: nil

  defp selected_time_bucket?({%DateTime{} = from, %DateTime{}}, %{bucket: %DateTime{} = bucket}) do
    DateTime.to_unix(from) == DateTime.to_unix(bucket)
  end

  defp selected_time_bucket?(_time_window, _bucket), do: false

  defp bucket_key(%{bucket: bucket}), do: bucket_key(bucket)
  defp bucket_key(%DateTime{} = bucket), do: DateTime.to_unix(bucket)
  defp bucket_key(_bucket), do: "unknown"

  defp throughput_title(%{bucket: %DateTime{} = bucket, total: total, failed: failed}) do
    "#{bucket_time_label(bucket)} - #{format_count(total)} #{gettext("runs")} / #{format_count(failed)} #{gettext("failed")}"
  end

  defp throughput_title(_bucket), do: "-"

  defp bucket_time_label(%{bucket: bucket}), do: bucket_time_label(bucket)

  defp bucket_time_label(%DateTime{} = bucket) do
    Calendar.strftime(bucket, "%H:%M")
  end

  defp bucket_time_label(_bucket), do: "-"

  defp format_count(value) when is_integer(value), do: Integer.to_string(value)
  defp format_count(_value), do: "0"

  defp timing_total(%{run_duration_ms: run_duration_ms}) when is_integer(run_duration_ms) do
    "#{gettext("total")} #{format_duration(run_duration_ms)}"
  end

  defp timing_total(%{step_ready_total_ms: step_ready_total_ms})
       when is_integer(step_ready_total_ms) do
    "#{gettext("total")} #{format_duration(step_ready_total_ms)}"
  end

  defp timing_total(_run), do: "-"

  defp timing_breakdown(run) do
    [
      duration_part(gettext("deps"), run.step_dependency_wait_ms),
      duration_part(gettext("queue"), run.step_queue_wait_ms),
      duration_part(gettext("exec"), run.step_execution_ms)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "#{gettext("updated")} #{relative_time(run.updated_at)}"
      parts -> Enum.join(parts, " / ")
    end
  end

  defp timing_step_total_detail(%{
         step_ready_total_ms: step_ready_total_ms,
         run_duration_ms: run_duration_ms
       })
       when is_integer(step_ready_total_ms) and is_integer(run_duration_ms) do
    "#{gettext("step")} #{gettext("total")} #{format_duration(step_ready_total_ms)}"
  end

  defp timing_step_total_detail(_run), do: nil

  defp execution_label(metadata) when is_map(metadata) do
    executor = Map.get(metadata, "executor") || "-"
    runtime = execution_runtime(metadata)

    cond do
      is_binary(Map.get(runtime, "node_name")) ->
        "#{executor} / #{Map.get(runtime, "node_name")}"

      is_binary(Map.get(runtime, "pod_name")) ->
        "#{executor} / #{Map.get(runtime, "pod_name")}"

      true ->
        executor
    end
  end

  defp execution_label(_metadata), do: "-"

  defp encoding_booster_badge(assigns) do
    usage =
      case assigns do
        %{steps: steps} ->
          encoding_booster_usage(steps)

        %{step_type: step_type, execution_metadata: metadata} ->
          encoding_booster_step_usage(step_type, metadata)

        _assigns ->
          nil
      end

    assigns = assign(assigns, :usage, usage)

    ~H"""
    <span
      :if={@usage}
      class={[
        "mt-1 inline-flex w-fit items-center rounded-full px-2 py-0.5 text-[0.68rem] font-medium",
        encoding_booster_usage_class(@usage)
      ]}
    >
      {encoding_booster_usage_label(@usage)}
    </span>
    """
  end

  defp encoding_booster_usage(steps) when is_list(steps) do
    usages =
      steps
      |> Enum.map(&encoding_booster_step_usage(&1.step_type, &1.execution_metadata))
      |> Enum.reject(&is_nil/1)

    Enum.find(usages, &(&1 == :used)) ||
      Enum.find(usages, &match?({:fallback, _reason}, &1)) ||
      Enum.find(usages, &(&1 == :attempted)) ||
      Enum.find(usages, &(&1 == :not_used))
  end

  defp encoding_booster_usage(_steps), do: nil

  defp encoding_booster_step_usage("media.transcode_h264_ladder", metadata)
       when is_map(metadata) do
    cond do
      Map.get(metadata, "encoding_booster_used") == true ->
        :used

      is_binary(Map.get(metadata, "encoding_booster_fallback")) ->
        {:fallback, Map.get(metadata, "encoding_booster_fallback")}

      Map.get(metadata, "encoding_booster_attempted") == true ->
        :attempted

      Map.get(metadata, "encoding_booster_used") == false ->
        :not_used

      Map.get(metadata, "executor") == "flame" ->
        :not_used

      true ->
        nil
    end
  end

  defp encoding_booster_step_usage("media.transcode_video", metadata) when is_map(metadata) do
    encoding_booster_step_usage("media.transcode_h264_ladder", metadata)
  end

  defp encoding_booster_step_usage(_step_type, _metadata), do: nil

  defp encoding_booster_usage_label(:used), do: gettext("Booster used")

  defp encoding_booster_usage_label({:fallback, reason}) do
    gettext("Booster → FLAME (%{reason})", reason: reason)
  end

  defp encoding_booster_usage_label(:attempted), do: gettext("Booster attempted")
  defp encoding_booster_usage_label(:not_used), do: gettext("Booster not used")

  defp encoding_booster_usage_class(:used), do: "bg-emerald-50 text-emerald-600"
  defp encoding_booster_usage_class({:fallback, _reason}), do: "bg-amber-50 text-amber-600"
  defp encoding_booster_usage_class(:attempted), do: "bg-blue-50 text-blue-600"
  defp encoding_booster_usage_class(:not_used), do: "bg-stone-100 text-stone-500"

  defp gpu_encoding_booster_badge(assigns) do
    usage =
      case assigns do
        %{steps: steps} ->
          gpu_encoding_booster_usage(steps)

        %{step_type: step_type, execution_metadata: metadata} ->
          gpu_encoding_booster_step_usage(step_type, metadata)

        _assigns ->
          nil
      end

    assigns = assign(assigns, :usage, usage)

    ~H"""
    <span
      :if={@usage}
      class={[
        "mt-1 inline-flex w-fit items-center rounded-full px-2 py-0.5 text-[0.68rem] font-medium",
        gpu_encoding_booster_usage_class(@usage)
      ]}
    >
      {gpu_encoding_booster_usage_label(@usage)}
    </span>
    """
  end

  defp gpu_encoding_booster_usage(steps) when is_list(steps) do
    usages =
      steps
      |> Enum.map(&gpu_encoding_booster_step_usage(&1.step_type, &1.execution_metadata))
      |> Enum.reject(&is_nil/1)

    Enum.find(usages, &(&1 == :used)) ||
      Enum.find(usages, &match?({:fallback, _reason}, &1)) ||
      Enum.find(usages, &(&1 == :attempted))
  end

  defp gpu_encoding_booster_usage(_steps), do: nil

  defp gpu_encoding_booster_step_usage(step_type, metadata)
       when step_type in ["media.transcode_h264_ladder", "media.transcode_video"] and
              is_map(metadata) do
    cond do
      Map.get(metadata, "gpu_encoding_booster_used") == true ->
        :used

      is_binary(Map.get(metadata, "gpu_encoding_booster_fallback")) ->
        {:fallback, Map.get(metadata, "gpu_encoding_booster_fallback")}

      Map.get(metadata, "gpu_encoding_booster_attempted") == true ->
        :attempted

      true ->
        nil
    end
  end

  defp gpu_encoding_booster_step_usage(_step_type, _metadata), do: nil

  defp gpu_encoding_booster_usage_label(:used), do: gettext("GPU Booster used")

  defp gpu_encoding_booster_usage_label({:fallback, reason}) do
    gettext("GPU Booster → CPU Booster (%{reason})", reason: reason)
  end

  defp gpu_encoding_booster_usage_label(:attempted), do: gettext("GPU Booster attempted")

  defp gpu_encoding_booster_usage_class(:used), do: "bg-violet-50 text-violet-600"

  defp gpu_encoding_booster_usage_class({:fallback, _reason}),
    do: "bg-fuchsia-50 text-fuchsia-600"

  defp gpu_encoding_booster_usage_class(:attempted), do: "bg-indigo-50 text-indigo-600"

  defp execution_detail(metadata) when is_map(metadata) do
    runtime = execution_runtime(metadata)

    [
      Map.get(runtime, "hardware_profile"),
      Map.get(runtime, "pod_name"),
      Map.get(runtime, "pod_ip"),
      flame_call_label(metadata),
      retry_policy_label(metadata)
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> case do
      [] -> "-"
      parts -> Enum.join(parts, " / ")
    end
  end

  defp execution_detail(_metadata), do: "-"

  defp execution_runtime(%{"runtime" => runtime}) when is_map(runtime), do: runtime
  defp execution_runtime(_metadata), do: %{}

  defp flame_call_label(%{"flame_call_ms" => ms}) when is_integer(ms) do
    "flame call #{format_duration(ms)}"
  end

  defp flame_call_label(_metadata), do: nil

  defp retry_policy_label(%{"retry_policy" => policy}) when is_map(policy) do
    attempts = Map.get(policy, "cycle_attempts")
    max_attempts = Map.get(policy, "max_execution_attempts")
    recoveries = Map.get(policy, "orphan_recoveries", 0)
    max_recoveries = Map.get(policy, "max_orphan_recoveries")

    cond do
      Map.get(policy, "exhausted") == true ->
        "automatic retry budget exhausted"

      is_integer(recoveries) and recoveries > 0 ->
        "cycle #{attempts}/#{max_attempts}, orphan recovery #{recoveries}/#{max_recoveries}"

      is_integer(attempts) and attempts > 1 ->
        "cycle #{attempts}/#{max_attempts}"

      true ->
        nil
    end
  end

  defp retry_policy_label(_metadata), do: nil

  defp ffmpeg_performance_label(%{"progress" => %{"source" => source} = progress})
       when source in ["ffmpeg", "encoding_booster"] do
    prefix = if source == "encoding_booster", do: "~", else: ""

    [
      performance_speed_part(progress),
      performance_fps_part(progress),
      performance_elapsed_part(progress)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> prefix <> Enum.join(parts, " / ")
    end
  end

  defp ffmpeg_performance_label(_metadata), do: nil

  defp execution_progress_percent(%{"progress" => %{"percent" => percent}}, status)
       when status in ["executing", "running"] and is_number(percent) do
    percent
    |> max(0)
    |> min(100)
    |> round()
  end

  defp execution_progress_percent(_metadata, _status), do: nil

  defp execution_progress_label(%{"progress" => %{} = progress} = metadata) do
    case execution_progress_percent(metadata, "executing") do
      nil ->
        nil

      percent ->
        prefix = if Map.get(progress, "source") == "encoding_booster", do: "~", else: ""
        suffix = if prefix == "~", do: gettext(" (estimated)"), else: ""

        "#{prefix}#{percent}% #{execution_progress_stage(Map.get(progress, "stage"))}#{suffix}"
    end
  end

  defp execution_progress_label(_metadata), do: nil

  defp execution_progress_stage("transcode"), do: gettext("encoding")
  defp execution_progress_stage("package_hls"), do: gettext("packaging")
  defp execution_progress_stage("extract_frame"), do: gettext("extracting")
  defp execution_progress_stage("generate_segments"), do: gettext("generating")
  defp execution_progress_stage("generate_storyboard"), do: gettext("generating")
  defp execution_progress_stage(_stage), do: gettext("processing")

  defp performance_speed_part(%{"speed_x" => speed_x}) when is_number(speed_x) do
    "#{format_speed(speed_x)} realtime"
  end

  defp performance_speed_part(_progress), do: nil

  defp performance_fps_part(%{"fps" => fps}) when is_number(fps), do: format_fps(fps)
  defp performance_fps_part(_progress), do: nil

  defp performance_elapsed_part(%{"ffmpeg_elapsed_ms" => ms}) when is_integer(ms) do
    "#{format_duration(ms)} FFmpeg"
  end

  defp performance_elapsed_part(_progress), do: nil

  defp ffmpeg_workload_label(metric) do
    [
      present_metric_part(metric.codec),
      ffmpeg_output_profile(metric),
      preset_label(metric.preset)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" / ")
  end

  defp ffmpeg_output_profile(%{variants: variants})
       when is_binary(variants) and variants != "-" do
    case Jason.decode(variants) do
      {:ok, values} when is_list(values) -> Enum.join(values, ", ")
      _other -> variants
    end
  end

  defp ffmpeg_output_profile(%{size: size}), do: present_metric_part(size)

  defp preset_label(preset) when is_binary(preset) and preset != "-", do: "preset #{preset}"
  defp preset_label(_preset), do: nil

  defp present_metric_part(value) when is_binary(value) and value != "-", do: value
  defp present_metric_part(_value), do: nil

  defp format_speed(value) when is_number(value), do: "#{Float.round(value * 1.0, 2)}×"
  defp format_speed(_value), do: "-"

  defp format_fps(value) when is_number(value) do
    value = Float.round(value * 1.0, 1)

    if value == trunc(value), do: "#{trunc(value)} fps", else: "#{value} fps"
  end

  defp format_fps(_value), do: "-"

  defp duration_part(_label, nil), do: nil
  defp duration_part(label, ms) when is_integer(ms), do: "#{label} #{format_duration(ms)}"

  defp format_duration(ms) when is_integer(ms) and ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when is_integer(ms), do: compact_duration(ms)
  defp format_duration(_ms), do: "-"

  defp compact_duration(ms) do
    total_seconds = div(ms, 1000)
    days = div(total_seconds, 86_400)
    hours = total_seconds |> rem(86_400) |> div(3_600)
    minutes = total_seconds |> rem(3_600) |> div(60)
    seconds = rem(total_seconds, 60)

    cond do
      days > 0 -> join_duration([{days, "d"}, {hours, "h"}])
      hours > 0 -> join_duration([{hours, "h"}, {minutes, "m"}])
      minutes > 0 -> join_duration([{minutes, "m"}, {seconds, "s"}])
      true -> "#{seconds}s"
    end
  end

  defp join_duration(parts) do
    parts
    |> Enum.reject(fn {value, _unit} -> value == 0 end)
    |> Enum.map_join(" ", fn {value, unit} -> "#{value}#{unit}" end)
  end

  defp relative_time(%DateTime{} = datetime) do
    seconds = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      seconds < 60 -> gettext("now")
      seconds < 3600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> "#{div(seconds, 3600)}h"
      true -> "#{div(seconds, 86_400)}d"
    end
  end

  defp relative_time(_datetime), do: "-"

  defp open_action(run) do
    case Application.get_env(:mave_core, :flow_runs_open_action) do
      {module, function} when is_atom(module) and is_atom(function) ->
        with true <- Code.ensure_loaded?(module),
             true <- function_exported?(module, function, 1) do
          apply(module, function, [run])
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp inspection_actions_for(run, step \\ nil) do
    case Application.get_env(:mave_core, :flow_runs_inspection_actions) do
      {module, function} when is_atom(module) and is_atom(function) ->
        with true <- Code.ensure_loaded?(module),
             true <- function_exported?(module, function, 1),
             actions when is_list(actions) <- apply(module, function, [%{run: run, step: step}]) do
          Enum.filter(actions, &valid_inspection_action?/1)
        else
          _ -> []
        end

      _ ->
        []
    end
  end

  defp valid_inspection_action?(%{to: to}) when is_binary(to), do: true
  defp valid_inspection_action?(_action), do: false
end
