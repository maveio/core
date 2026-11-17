defmodule MaveCoreWeb.Dashboard.Videos.ExperimentComponent do
  @moduledoc """
  The A/B test section of the video detail page: set up a test, follow its
  variants, and decide when the evidence is not clear enough to decide alone.
  """

  use MaveCoreWeb, :live_component
  import MaveCoreWeb.DashboardComponents, except: [icon: 1]

  alias MaveCore.Embeds.Embed
  alias MaveCore.Experiments
  alias MaveCore.Experiments.{Experiment, Metrics, Variant}
  alias MaveCoreWeb.DashboardRoutes
  alias MaveCoreWeb.Formatter

  @comparable_views 30

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:embed_id, nil)
     |> assign(:mode, :view)
     |> assign(:error, nil)
     |> reset_setup()}
  end

  @impl true
  def update(%{refresh: true}, socket), do: {:ok, load(socket)}

  def update(assigns, socket) do
    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:embed, assigns.embed)
      |> assign(:current_space, assigns.current_space)
      |> assign(:route_scope, assigns.route_scope)

    # The parent re-renders on every processing tick; only a different video
    # needs another look at the test and its statistics.
    if socket.assigns.embed_id == assigns.embed.id do
      {:ok, socket}
    else
      {:ok, socket |> assign(:embed_id, assigns.embed.id) |> assign(:mode, :view) |> load()}
    end
  end

  defp load(socket) do
    embed = socket.assigns.embed
    experiment = Experiments.current(embed)

    socket
    |> assign(:experiment, experiment)
    |> assign(:report, experiment && Experiments.report(experiment))
    |> assign(:eligibility, Experiments.eligible?(embed))
    |> assign(:now, DateTime.utc_now())
  end

  defp reset_setup(socket) do
    socket
    |> assign(:form, to_form(Experiments.change_settings(), as: :experiment))
    |> assign(:selected, [])
    |> assign(:query, "")
    |> assign(:suggestions, [])
  end

  @impl true
  def handle_event("setup", _params, socket) do
    {:noreply, socket |> reset_setup() |> assign(:mode, :setup) |> assign(:error, nil)}
  end

  def handle_event("cancel_setup", _params, socket) do
    {:noreply, socket |> assign(:mode, :view) |> assign(:error, nil)}
  end

  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, socket |> assign(:query, query) |> assign_suggestions()}
  end

  def handle_event("add_variant", %{"id" => id}, socket) do
    with true <- length(socket.assigns.selected) < Experiments.max_variants() - 1,
         %{} = suggestion <- Enum.find(socket.assigns.suggestions, &(&1.uuid == id)) do
      {:noreply,
       socket
       |> assign(:selected, socket.assigns.selected ++ [suggestion])
       |> assign(:query, "")
       |> assign(:suggestions, [])
       |> assign(:error, nil)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("remove_variant", %{"id" => id}, socket) do
    selected = Enum.reject(socket.assigns.selected, &(&1.uuid == id))
    {:noreply, socket |> assign(:selected, selected) |> assign_suggestions()}
  end

  def handle_event("validate", %{"experiment" => params}, socket) do
    form =
      params
      |> Experiments.change_settings()
      |> Map.put(:action, :validate)
      |> to_form(as: :experiment)

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("start", %{"experiment" => params}, socket) do
    ids = Enum.map(socket.assigns.selected, & &1.uuid)

    case Experiments.start(socket.assigns.embed, ids, params) do
      {:ok, _experiment} ->
        {:noreply, socket |> assign(:mode, :view) |> assign(:error, nil) |> load()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :experiment))}

      {:error, reason} ->
        {:noreply, assign(socket, :error, start_error(reason))}
    end
  end

  def handle_event("extend", %{"days" => days}, socket) do
    case Integer.parse(days) do
      {days, ""} when days in 1..90 -> decide(socket, &Experiments.extend(&1, days))
      _invalid -> {:noreply, socket}
    end
  end

  def handle_event("lock", %{"id" => variant_id}, socket) do
    decide(socket, &Experiments.choose_winner(&1, variant_id))
  end

  def handle_event("stop", _params, socket), do: decide(socket, &Experiments.stop/1)
  def handle_event("unlock", _params, socket), do: decide(socket, &Experiments.unlock/1)
  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  # Acts on the test as stored now, not as rendered, so a decision made in
  # another session or by the scheduled evaluation is never overwritten.
  defp decide(socket, action) do
    case Experiments.current(socket.assigns.embed) do
      %Experiment{} = experiment ->
        error =
          case action.(experiment) do
            {:ok, _experiment} -> nil
            {:error, _reason} -> gettext("This test changed in the meantime. Review it below.")
          end

        {:noreply, socket |> assign(:error, error) |> load()}

      nil ->
        {:noreply, load(socket)}
    end
  end

  defp assign_suggestions(socket) do
    %{current_space: space, embed: embed, query: query, selected: selected} = socket.assigns

    assign(
      socket,
      :suggestions,
      Experiments.search_candidates(space, embed, query, Enum.map(selected, & &1.uuid))
    )
  end

  defp start_error(:no_variants), do: gettext("Add at least one other video to compare with.")
  defp start_error(:too_many_variants), do: gettext("A test compares at most four videos.")

  defp start_error(reason) when reason in [:variant_not_found, :variant_not_playable],
    do: gettext("One of the videos can no longer be played. Remove it and try again.")

  defp start_error(_reason), do: gettext("This video cannot be tested right now.")

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <.video_data_section label={gettext("A/B test")}>
        <div class="px-6 py-5 text-sm text-stone-500">
          <div
            :if={@error}
            id={"#{@id}-error"}
            class="mb-4 rounded-md bg-rose-50 px-3 py-2.5 text-rose-500 ring-1 ring-inset ring-rose-200/70"
          >
            {@error}
          </div>

          <%= cond do %>
            <% @mode == :setup -> %>
              <.setup {assigns} />
            <% is_nil(@experiment) -> %>
              <.intro id={@id} myself={@myself} eligibility={@eligibility} />
            <% true -> %>
              <.overview {assigns} />
          <% end %>
        </div>
      </.video_data_section>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :myself, :any, required: true
  attr :eligibility, :any, required: true

  defp intro(assigns) do
    ~H"""
    <div class="flex items-center gap-6">
      <div class="grow">
        <div class="text-stone-600">
          {gettext("Find out which video connects best, without changing the embed code.")}
        </div>
        <div class="mt-1 text-stone-400">
          <%= case @eligibility do %>
            <% :ok -> %>
              {gettext(
                "Viewers of the iFrame embed are split evenly across this video and up to three others. After the test period the embed locks to the winner, if the result is clear."
              )}
            <% {:error, :private} -> %>
              {gettext("A/B tests need public playback. This video is private.")}
            <% {:error, :audio_only} -> %>
              {gettext("A/B tests compare videos. This upload has no picture.")}
            <% _ -> %>
              {gettext("A/B tests become available once this video is ready.")}
          <% end %>
        </div>
      </div>
      <.dash_button
        :if={@eligibility == :ok}
        id={"#{@id}-setup"}
        type="button"
        class="flex-none"
        phx-click="setup"
        phx-target={@myself}
      >
        {gettext("set up test")}
      </.dash_button>
    </div>
    """
  end

  defp setup(assigns) do
    ~H"""
    <div id={"#{@id}-form"}>
      <div class="text-xs font-medium uppercase tracking-wide text-stone-400">
        {gettext("videos to compare")}
      </div>
      <div class="mt-2 divide-y divide-stone-100 rounded-md ring-1 ring-stone-200/60">
        <.setup_row label="A" name={video_name(@embed)} note={gettext("this video")} />
        <.setup_row
          :for={{video, index} <- Enum.with_index(@selected, 1)}
          label={Variant.label(index)}
          name={video.name}
          thumb={video.thumb}
        >
          <button
            type="button"
            class="text-stone-400 hover:text-rose-500 cursor-pointer"
            phx-click="remove_variant"
            phx-value-id={video.uuid}
            phx-target={@myself}
          >
            {gettext("remove")}
          </button>
        </.setup_row>
      </div>

      <form
        :if={length(@selected) < Experiments.max_variants() - 1}
        id={"#{@id}-search"}
        class="mt-3"
        phx-change="search"
        phx-submit="search"
        phx-target={@myself}
      >
        <.dash_input
          name="query"
          value={@query}
          placeholder={
            gettext("Search a video to add as variant %{label}",
              label: Variant.label(length(@selected) + 1)
            )
          }
          phx-debounce="200"
        />
        <div
          :if={@suggestions != []}
          id={"#{@id}-suggestions"}
          class="mt-2 divide-y divide-stone-100 rounded-md ring-1 ring-stone-200/60"
        >
          <button
            :for={video <- @suggestions}
            type="button"
            id={"#{@id}-suggestion-#{video.uuid}"}
            class="flex w-full items-center gap-3 px-3 py-2 text-left hover:bg-stone-50 active:bg-blue-50 cursor-pointer"
            phx-click="add_variant"
            phx-value-id={video.uuid}
            phx-target={@myself}
          >
            <.thumb src={video.thumb} />
            <span class="grow truncate text-stone-600">{video.name}</span>
            <span class="text-blue-500">{gettext("add")}</span>
          </button>
        </div>
        <div
          :if={@suggestions == [] and String.length(String.trim(@query)) >= 2}
          class="mt-2 text-stone-400"
        >
          {gettext("No public, ready video matches.")}
        </div>
      </form>

      <.form
        for={@form}
        id={"#{@id}-settings"}
        class="mt-6"
        phx-change="validate"
        phx-submit="start"
        phx-target={@myself}
      >
        <div class="grid grid-cols-3 gap-4">
          <label class="block">
            <span class="text-xs font-medium uppercase tracking-wide text-stone-400">
              {gettext("success metric")}
            </span>
            <div class="mt-2">
              <.dash_select field={@form[:metric]} options={metric_options()} />
            </div>
          </label>
          <label class="block">
            <span class="text-xs font-medium uppercase tracking-wide text-stone-400">
              {gettext("test period in days")}
            </span>
            <div class="mt-2">
              <.dash_input field={@form[:duration_days]} type="number" />
            </div>
          </label>
          <label class="block">
            <span class="text-xs font-medium uppercase tracking-wide text-stone-400">
              {gettext("minimum views per video")}
            </span>
            <div class="mt-2">
              <.dash_input field={@form[:min_views]} type="number" />
            </div>
          </label>
        </div>

        <div class="mt-5">
          <.info_box>
            {gettext(
              "The test runs on the iFrame embed. Script, React and Vue embeds keep playing this video. At the end of the period the embed locks to the best video only if every video reached the minimum views and the difference is statistically clear; otherwise the test stays open for your decision."
            )}
          </.info_box>
        </div>

        <div class="mt-5 flex items-center justify-end gap-3">
          <.dash_button type="button" variant="ghost" phx-click="cancel_setup" phx-target={@myself}>
            {gettext("cancel")}
          </.dash_button>
          <.dash_button id={"#{@id}-start"} variant="primary" loading_on_submit>
            {gettext("start test")}
          </.dash_button>
        </div>
      </.form>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :name, :string, required: true
  attr :note, :string, default: nil
  attr :thumb, :string, default: nil
  slot :inner_block

  defp setup_row(assigns) do
    ~H"""
    <div class="flex items-center gap-3 px-3 py-2">
      <.variant_badge label={@label} />
      <.thumb :if={@thumb} src={@thumb} />
      <span class="grow truncate text-stone-600">{@name}</span>
      <span :if={@note} class="text-stone-400">{@note}</span>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :src, :string, default: nil

  defp thumb(assigns) do
    ~H"""
    <div class="h-7 w-12 flex-none overflow-hidden rounded bg-stone-100">
      <img :if={@src} src={@src} alt="" class="h-full w-full object-cover" loading="lazy" />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :tone, :atom, default: :plain

  defp variant_badge(assigns) do
    ~H"""
    <span class={[
      "flex h-6 w-6 flex-none items-center justify-center rounded text-xs font-medium",
      @tone == :plain && "bg-stone-100 text-stone-500",
      @tone == :winner && "bg-green-600 text-white"
    ]}>
      {@label}
    </span>
    """
  end

  defp overview(assigns) do
    assigns =
      assigns
      |> assign(:rows, rows(assigns.experiment, assigns.report))
      |> assign(:evaluation, evaluation(assigns.report))
      |> assign(:open, assigns.experiment.status in [:running, :needs_decision])

    ~H"""
    <div id={"#{@id}-overview"} data-status={@experiment.status}>
      <div class="flex items-start gap-6">
        <div class="grow">
          <div class="flex items-center gap-2.5 text-stone-600">
            <.status_dot status={@experiment.status} />
            <span id={"#{@id}-status"} class="font-medium">{status_title(@experiment)}</span>
          </div>
          <div class="mt-1 text-stone-400">{status_detail(@experiment, @evaluation, @now)}</div>
        </div>
        <div class="flex flex-none items-center gap-3">
          <.dash_button
            :if={@experiment.status == :needs_decision}
            id={"#{@id}-extend"}
            type="button"
            phx-click="extend"
            phx-value-days="7"
            phx-target={@myself}
          >
            {gettext("run 7 more days")}
          </.dash_button>
          <.dash_button
            :if={@open}
            id={"#{@id}-stop"}
            type="button"
            variant="ghost"
            phx-click="stop"
            phx-target={@myself}
            data-confirm={gettext("Stop this test? The embed goes back to playing only this video.")}
          >
            {gettext("stop test")}
          </.dash_button>
          <.dash_button
            :if={@experiment.status == :locked}
            id={"#{@id}-unlock"}
            type="button"
            variant="ghost"
            phx-click="unlock"
            phx-target={@myself}
            data-confirm={gettext("Remove the lock? The embed goes back to playing this video.")}
          >
            {gettext("remove lock")}
          </.dash_button>
          <.dash_button
            :if={@experiment.status == :ended and @eligibility == :ok}
            id={"#{@id}-setup"}
            type="button"
            phx-click="setup"
            phx-target={@myself}
          >
            {gettext("new test")}
          </.dash_button>
        </div>
      </div>

      <div
        :if={@experiment.status == :needs_decision}
        id={"#{@id}-decision"}
        class="mt-4 rounded-md bg-amber-50 px-3 py-2.5 text-amber-700 ring-1 ring-inset ring-amber-200/80"
      >
        {decision_message(@experiment, @rows)}
      </div>

      <div
        :if={match?({:error, _reason}, @report)}
        class="mt-4 rounded-md bg-stone-50 px-3 py-2.5 text-stone-400 ring-1 ring-inset ring-stone-200/70"
      >
        {gettext("Statistics are unavailable right now. The test itself is not affected.")}
      </div>

      <div
        :if={@rows != []}
        class="mt-5 grid grid-cols-[minmax(0,1fr)_4rem_13rem_6rem_auto] items-center gap-x-5 gap-y-3"
      >
        <div class="contents text-xs uppercase tracking-wide text-stone-400">
          <div>{gettext("video")}</div>
          <div class="text-right">{gettext("views")}</div>
          <div>{metric_label(@experiment.metric)}</div>
          <div class="text-right">{other_metric_label(@experiment.metric)}</div>
          <div></div>
        </div>

        <div :for={row <- @rows} id={"#{@id}-variant-#{row.label}"} class="contents">
          <div class="flex min-w-0 items-center gap-3">
            <.variant_badge label={row.label} tone={if row.winner, do: :winner, else: :plain} />
            <.link
              navigate={
                DashboardRoutes.video_path(@current_space, row.embed_id, :all, scope: @route_scope)
              }
              class="truncate text-stone-600 hover:text-blue-600"
            >
              {row.name}
            </.link>
            <span
              :if={row.tag}
              class={[
                "flex-none rounded-full px-2 py-0.5 text-xs",
                row.winner && "bg-green-50 text-green-700 ring-1 ring-inset ring-green-200",
                !row.winner && "bg-stone-100 text-stone-500"
              ]}
            >
              {row.tag}
            </span>
          </div>
          <div class="text-right tabular-nums text-stone-600">{format_number(row.views)}</div>
          <div class="flex items-center gap-3">
            <div class="h-1.5 grow overflow-hidden rounded-full bg-stone-100">
              <div
                class={[
                  "h-full rounded-full",
                  if(row.winner, do: "bg-green-500", else: "bg-blue-500")
                ]}
                style={"width: #{row.score_share}%"}
              >
              </div>
            </div>
            <div class="w-14 flex-none text-right tabular-nums text-stone-600">{row.score}</div>
          </div>
          <div class="text-right tabular-nums text-stone-600">{row.other}</div>
          <div class="flex justify-end">
            <button
              :if={@open}
              type="button"
              id={"#{@id}-lock-#{row.label}"}
              class="text-blue-500 hover:text-blue-700 cursor-pointer"
              phx-click="lock"
              phx-value-id={row.id}
              phx-target={@myself}
              data-confirm={
                gettext("Lock the embed to video %{label}? This ends the test.", label: row.label)
              }
            >
              {gettext("use this video")}
            </button>
          </div>
        </div>
      </div>

      <div class="mt-5 flex items-center gap-2 border-t border-stone-100 pt-4 text-xs text-stone-400">
        <div class="grow">{footnote(@experiment, @report)}</div>
        <button
          :if={@open}
          type="button"
          id={"#{@id}-refresh"}
          class="flex-none text-blue-500 hover:text-blue-700 cursor-pointer"
          phx-click="refresh"
          phx-target={@myself}
        >
          {gettext("refresh")}
        </button>
      </div>
    </div>
    """
  end

  attr :status, :atom, required: true

  defp status_dot(assigns) do
    ~H"""
    <span class={[
      "h-2 w-2 flex-none rounded-full",
      @status == :running && "bg-blue-500 animate-pulse",
      @status == :needs_decision && "bg-amber-500",
      @status == :locked && "bg-green-500",
      @status == :ended && "bg-stone-300"
    ]}></span>
    """
  end

  # The bar follows the metric the test is decided on; the other one is context.
  defp rows(%Experiment{} = experiment, {:ok, report}) do
    best = report.variants |> Enum.map(& &1.value) |> Enum.max(fn -> 0.0 end)
    lead_shown? = experiment.status in [:running, :needs_decision] and comparable?(report)

    experiment.variants
    |> Enum.zip(report.variants)
    |> Enum.map(fn {variant, metrics} ->
      winner? = experiment.winner_variant_id == variant.id
      {score, other} = scores(experiment.metric, metrics)

      %{
        id: variant.id,
        embed_id: variant.embed_id,
        label: Variant.label(variant),
        name: video_name(variant.embed),
        views: metrics.views,
        score: score,
        score_share: if(best > 0, do: round(metrics.value / best * 100), else: 0),
        other: other,
        winner: winner?,
        tag: tag(variant, winner?, lead_shown? and metrics.leader)
      }
    end)
  end

  defp rows(_experiment, _report), do: []

  defp scores(:watch_time, metrics),
    do: {format_seconds(metrics.watch_seconds), format_percent(metrics.completion_rate)}

  defp scores(:completion_rate, metrics),
    do: {format_percent(metrics.completion_rate), format_seconds(metrics.watch_seconds)}

  defp tag(_variant, true, _leading?), do: gettext("winner")
  defp tag(_variant, _winner?, true), do: gettext("leading")
  defp tag(%Variant{position: 0}, _winner?, _leading?), do: gettext("original")
  defp tag(_variant, _winner?, _leading?), do: nil

  # Below this many views per video a lead or a confidence figure is noise.
  defp comparable?(%{variants: variants}),
    do: Enum.all?(variants, &(&1.views >= @comparable_views))

  defp evaluation({:ok, report}), do: report.evaluation
  defp evaluation(_report), do: nil

  defp status_title(%Experiment{status: :running}), do: gettext("Test running")
  defp status_title(%Experiment{status: :needs_decision}), do: gettext("Needs your decision")

  defp status_title(%Experiment{status: :locked} = experiment) do
    case winner(experiment) do
      %Variant{position: 0} -> gettext("The original won")
      %Variant{} = variant -> gettext("Locked to video %{label}", label: Variant.label(variant))
      nil -> gettext("Locked")
    end
  end

  defp status_title(%Experiment{status: :ended, winner_variant_id: nil}),
    do: gettext("Test stopped without a winner")

  defp status_title(%Experiment{status: :ended}), do: gettext("Test ended, lock removed")

  defp status_detail(%Experiment{status: :running} = experiment, _evaluation, now) do
    gettext("Viewers of the iFrame embed are split evenly. %{left}",
      left: time_left(experiment.ends_at, now)
    )
  end

  defp status_detail(%Experiment{status: :needs_decision}, _evaluation, _now) do
    gettext(
      "The test period is over without a clear winner. Viewers are still split until you decide."
    )
  end

  defp status_detail(%Experiment{status: :locked} = experiment, _evaluation, _now) do
    how =
      case experiment.decided_by do
        :automatic ->
          gettext("Decided automatically on %{date}.", date: date(experiment.ended_at))

        _manual ->
          gettext("Chosen by hand on %{date}.", date: date(experiment.ended_at))
      end

    case winner(experiment) do
      %Variant{position: 0} ->
        gettext("%{how} The embed keeps playing this video.", how: how)

      %Variant{embed: embed} ->
        gettext("%{how} The iFrame embed now plays “%{name}” for every viewer.",
          how: how,
          name: video_name(embed)
        )

      nil ->
        how
    end
  end

  defp status_detail(%Experiment{status: :ended} = experiment, _evaluation, _now) do
    gettext("Ended on %{date}. The embed plays this video.", date: date(experiment.ended_at))
  end

  defp winner(%Experiment{winner_variant_id: id, variants: variants}),
    do: Enum.find(variants, &(&1.id == id))

  defp decision_message(%Experiment{outcome_reason: :insufficient_views} = experiment, rows) do
    fewest = rows |> Enum.map(& &1.views) |> Enum.min(fn -> 0 end)

    gettext(
      "Too few viewers: the smallest group has %{views} of the %{needed} views each video needs. Run the test longer, pick a video yourself, or stop the test.",
      views: format_number(fewest),
      needed: format_number(experiment.min_views)
    )
  end

  defp decision_message(%Experiment{}, _rows) do
    gettext(
      "No clear difference: with these numbers the leading video could be ahead by chance. Run the test longer, pick a video yourself, or stop the test."
    )
  end

  defp footnote(%Experiment{} = experiment, report) do
    base =
      gettext("Decided on %{metric}, with at least %{views} views per video.",
        metric: metric_label(experiment.metric),
        views: format_number(experiment.min_views)
      )

    with {:ok, %{evaluation: %{confidence: confidence, required_confidence: required}} = numbers}
         when is_float(confidence) <- report,
         true <- comparable?(numbers) do
      base <>
        " " <>
        gettext("Confidence that the leader is really better: %{now} (%{needed} needed).",
          now: format_confidence(confidence),
          needed: format_percent(required)
        )
    else
      _ -> base
    end
  end

  defp metric_options do
    [
      {gettext("Watch time per view"), "watch_time"},
      {gettext("Completed (%{percent}% watched)",
         percent: round(Metrics.completion_threshold() * 100)
       ), "completion_rate"}
    ]
  end

  defp metric_label(:watch_time), do: gettext("watch time per view")
  defp metric_label(:completion_rate), do: gettext("completion rate")

  defp other_metric_label(:watch_time), do: gettext("completed")
  defp other_metric_label(:completion_rate), do: gettext("watch time")

  defp time_left(ends_at, now) do
    case DateTime.diff(ends_at, now, :second) do
      seconds when seconds >= 2 * 86_400 ->
        gettext("%{count} days left.", count: div(seconds + 43_200, 86_400))

      seconds when seconds >= 2 * 3_600 ->
        gettext("%{count} hours left.", count: div(seconds, 3_600))

      seconds when seconds > 0 ->
        gettext("Ends within two hours.")

      _ ->
        gettext("The period is over; the result is being evaluated.")
    end
  end

  defp date(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%-d %b %Y")
  defp date(nil), do: ""

  defp video_name(%Embed{asset: %{name: name}}) when is_binary(name) and name != "", do: name

  defp video_name(%Embed{asset: %{current_video: %{file_name: name}}})
       when is_binary(name) and name != "",
       do: name

  defp video_name(%Embed{hash: hash}), do: hash

  defp format_number(number), do: Formatter.format_number(number)

  defp format_seconds(seconds) when seconds >= 60 do
    total = round(seconds)
    "#{div(total, 60)}:#{total |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp format_seconds(seconds), do: "#{:erlang.float_to_binary(seconds * 1.0, decimals: 1)} s"

  defp format_percent(share), do: "#{:erlang.float_to_binary(share * 100.0, decimals: 1)}%"

  # 99.96% must not read as certainty.
  defp format_confidence(confidence) when confidence > 0.999, do: "> 99.9%"
  defp format_confidence(confidence), do: format_percent(confidence)
end
