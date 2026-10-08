defmodule MaveCore.Flow.Diagnostics do
  @moduledoc """
  Durable flow-run diagnostics for dashboard and operations surfaces.

  The queries lean on flow state stored in Postgres, so this works in OSS
  deployments without requiring centralized production log ingestion.
  """

  import Ecto.Query

  alias MaveCore.Embeds
  alias MaveCore.Embeds.{Embed, SettingsSerializer}
  alias MaveCore.Flow.{Definition, Run, StepRun}
  alias MaveCore.Repo
  alias MaveCore.Spaces.Space

  @active_statuses ~w(queued running)
  @job_statuses ~w(queued running succeeded failed cancelled)
  @default_limit 25
  @max_limit 100
  @default_stale_minutes 30
  @default_since_hours 24
  @max_since_hours 72

  def global_diagnostics(opts \\ []) do
    now = DateTime.utc_now()
    limit = opts |> Keyword.get(:limit, @default_limit) |> normalize_limit()
    page = opts |> Keyword.get(:page, 1) |> normalize_page()
    status = opts |> Keyword.get(:status, "all") |> normalize_status()
    step_type = opts |> Keyword.get(:step_type) |> normalize_step_type()
    time_window = opts |> time_window_opt() |> normalize_time_window()
    stale_minutes = Keyword.get(opts, :stale_minutes, @default_stale_minutes)

    since_hours =
      opts |> Keyword.get(:since_hours, @default_since_hours) |> normalize_since_hours()

    stale_before = DateTime.add(now, -stale_minutes * 60, :second)
    since = DateTime.add(now, -since_hours * 60 * 60, :second)

    attention_page = attention_runs_page(nil, page, limit, status, step_type, time_window)

    runs =
      attention_page.entries
      |> Repo.preload([:flow_template, :flow_version, :step_runs])

    spaces_by_hash = spaces_by_hash(runs)
    embeds_by_key = embeds_by_key(runs, spaces_by_hash)

    %{
      generated_at: now,
      stale_minutes: stale_minutes,
      since_hours: since_hours,
      status_counts: status_counts(nil),
      performance: performance_summary(nil, since, since_hours, now),
      status: status,
      step_type_filter: step_type,
      time_window_filter: time_window,
      page: attention_page.page,
      total_pages: attention_page.total_pages,
      total_entries: attention_page.total_entries,
      attention_runs:
        Enum.map(
          runs,
          &summarize_run(&1, spaces_by_hash, embeds_by_key, stale_before, now, step_type)
        )
    }
  end

  def diagnostics_for_space(%Space{} = space, opts \\ []) do
    now = DateTime.utc_now()
    limit = opts |> Keyword.get(:limit, @default_limit) |> normalize_limit()
    page = opts |> Keyword.get(:page, 1) |> normalize_page()
    status = opts |> Keyword.get(:status, "all") |> normalize_status()
    step_type = opts |> Keyword.get(:step_type) |> normalize_step_type()
    time_window = opts |> time_window_opt() |> normalize_time_window()
    stale_minutes = Keyword.get(opts, :stale_minutes, @default_stale_minutes)

    since_hours =
      opts |> Keyword.get(:since_hours, @default_since_hours) |> normalize_since_hours()

    stale_before = DateTime.add(now, -stale_minutes * 60, :second)
    since = DateTime.add(now, -since_hours * 60 * 60, :second)

    attention_page = attention_runs_page(space, page, limit, status, step_type, time_window)

    runs =
      attention_page.entries
      |> Repo.preload([:flow_template, :flow_version, :step_runs])

    spaces_by_hash = %{space.hash => space}
    embeds_by_key = embeds_by_key(runs, spaces_by_hash)

    %{
      generated_at: now,
      stale_minutes: stale_minutes,
      since_hours: since_hours,
      status_counts: status_counts(space),
      performance: performance_summary(space, since, since_hours, now),
      status: status,
      step_type_filter: step_type,
      time_window_filter: time_window,
      page: attention_page.page,
      total_pages: attention_page.total_pages,
      total_entries: attention_page.total_entries,
      attention_runs:
        Enum.map(
          runs,
          &summarize_run(&1, spaces_by_hash, embeds_by_key, stale_before, now, step_type)
        )
    }
  end

  def run_diagnostics(flow_run_id, opts \\ [])

  def run_diagnostics(flow_run_id, opts) when is_binary(flow_run_id) do
    now = DateTime.utc_now()
    status = opts |> Keyword.get(:status, "all") |> normalize_status()
    step_type = opts |> Keyword.get(:step_type) |> normalize_step_type()
    time_window = opts |> time_window_opt() |> normalize_time_window()
    stale_minutes = Keyword.get(opts, :stale_minutes, @default_stale_minutes)
    stale_before = DateTime.add(now, -stale_minutes * 60, :second)

    with %Run{} = run <- run_diagnostics_query(flow_run_id, nil, status, step_type, time_window) do
      [run] = Repo.preload([run], [:flow_template, :flow_version, :step_runs])
      spaces_by_hash = spaces_by_hash([run])
      embeds_by_key = embeds_by_key([run], spaces_by_hash)

      summarize_run(run, spaces_by_hash, embeds_by_key, stale_before, now, step_type)
    end
  end

  def run_diagnostics(_flow_run_id, _opts), do: nil

  def run_diagnostics_for_space(space, flow_run_id, opts \\ [])

  def run_diagnostics_for_space(%Space{} = space, flow_run_id, opts)
      when is_binary(flow_run_id) do
    now = DateTime.utc_now()
    status = opts |> Keyword.get(:status, "all") |> normalize_status()
    step_type = opts |> Keyword.get(:step_type) |> normalize_step_type()
    time_window = opts |> time_window_opt() |> normalize_time_window()
    stale_minutes = Keyword.get(opts, :stale_minutes, @default_stale_minutes)
    stale_before = DateTime.add(now, -stale_minutes * 60, :second)

    with %Run{} = run <-
           run_diagnostics_query(flow_run_id, space, status, step_type, time_window) do
      [run] = Repo.preload([run], [:flow_template, :flow_version, :step_runs])
      spaces_by_hash = %{space.hash => space}
      embeds_by_key = embeds_by_key([run], spaces_by_hash)

      summarize_run(run, spaces_by_hash, embeds_by_key, stale_before, now, step_type)
    end
  end

  def run_diagnostics_for_space(_space, _flow_run_id, _opts), do: nil

  def retry_step(flow_run_id, step_id) when is_binary(flow_run_id) and is_binary(step_id) do
    with %Run{} = run <- run_for_retry(flow_run_id),
         true <- Enum.any?(run.step_runs, &(&1.step_id == step_id)) do
      MaveCore.Flow.retry_step(flow_run_id, step_id)
    else
      nil -> {:error, :not_found}
      false -> {:error, :step_not_found}
    end
  end

  def retry_step(_flow_run_id, _step_id), do: {:error, :invalid}

  def recover_run(flow_run_id) when is_binary(flow_run_id) do
    case run_for_retry(flow_run_id) do
      %Run{} -> MaveCore.Flow.recover_run(flow_run_id)
      nil -> {:error, :not_found}
    end
  end

  def recover_run(_flow_run_id), do: {:error, :invalid}

  def retry_step_for_space(%Space{} = space, flow_run_id, step_id)
      when is_binary(flow_run_id) and is_binary(step_id) do
    with %Run{} = run <- run_for_space(space, flow_run_id),
         true <- Enum.any?(run.step_runs, &(&1.step_id == step_id)) do
      MaveCore.Flow.retry_step(flow_run_id, step_id)
    else
      nil -> {:error, :not_found}
      false -> {:error, :step_not_found}
    end
  end

  def retry_step_for_space(_space, _flow_run_id, _step_id), do: {:error, :invalid}

  def retry_step_for_embed(%Space{} = space, %Embed{} = embed, flow_run_id, step_id)
      when is_binary(flow_run_id) and is_binary(step_id) do
    with true <- embed.space_id == space.id,
         %Run{} = run <- run_for_embed(space, embed, flow_run_id) do
      if Enum.any?(run.step_runs, &(&1.step_id == step_id)) do
        MaveCore.Flow.retry_step(flow_run_id, step_id)
      else
        {:error, :step_not_found}
      end
    else
      false -> {:error, :not_found}
      nil -> {:error, :not_found}
    end
  end

  def retry_step_for_embed(_space, _embed, _flow_run_id, _step_id), do: {:error, :invalid}

  def recover_run_for_space(%Space{} = space, flow_run_id) when is_binary(flow_run_id) do
    case run_for_space(space, flow_run_id) do
      %Run{} -> MaveCore.Flow.recover_run(flow_run_id)
      nil -> {:error, :not_found}
    end
  end

  def recover_run_for_space(_space, _flow_run_id), do: {:error, :invalid}

  defp attention_runs_page(space_or_nil, page, limit, status, step_type, time_window) do
    query = attention_runs_query(space_or_nil, status, step_type, time_window)
    total_entries = Repo.aggregate(query, :count, :id)
    total_pages = total_pages(total_entries, limit)
    page = min(page, max(total_pages, 1))

    entries =
      query
      |> order_attention_runs(step_type)
      |> limit(^limit)
      |> offset(^((page - 1) * limit))
      |> Repo.all()

    %{
      entries: entries,
      page: page,
      per_page: limit,
      total_pages: total_pages,
      total_entries: total_entries
    }
  end

  defp attention_runs_query(space_or_nil, status, nil, time_window) do
    base_attention_runs_query(space_or_nil, status, time_window)
  end

  defp attention_runs_query(space_or_nil, status, step_type, time_window)
       when is_binary(step_type) do
    step_metrics_query = step_type_run_metrics_query(step_type)

    space_or_nil
    |> base_attention_runs_query(status, time_window)
    |> join(:inner, [run], metric in subquery(step_metrics_query),
      on: metric.flow_run_id == run.id
    )
  end

  defp run_diagnostics_query(flow_run_id, space_or_nil, status, nil, time_window) do
    Run
    |> where([run], run.id == ^flow_run_id)
    |> maybe_filter_space(space_or_nil)
    |> maybe_filter_status(status)
    |> maybe_filter_time_window(time_window)
    |> Repo.one()
  end

  defp run_diagnostics_query(flow_run_id, space_or_nil, status, step_type, time_window)
       when is_binary(step_type) do
    Run
    |> where([run], run.id == ^flow_run_id)
    |> maybe_filter_space(space_or_nil)
    |> maybe_filter_status(status)
    |> maybe_filter_time_window(time_window)
    |> join(:inner, [run], step_run in StepRun,
      on: step_run.flow_run_id == run.id and step_run.step_type == ^step_type
    )
    |> distinct([run, _step_run], run.id)
    |> Repo.one()
  end

  defp base_attention_runs_query(space_or_nil, status, time_window) do
    Run
    |> maybe_filter_space(space_or_nil)
    |> maybe_filter_status(status)
    |> maybe_filter_time_window(time_window)
  end

  defp order_attention_runs(query, nil), do: order_by(query, [run], desc: run.updated_at)

  defp order_attention_runs(query, step_type) when is_binary(step_type) do
    order_by(query, [run, metric], desc: metric.step_sort_ms, desc: run.updated_at)
  end

  defp total_pages(0, _limit), do: 0
  defp total_pages(total_entries, limit), do: ceil(total_entries / limit)

  defp normalize_page(page) when is_integer(page) and page > 0, do: page

  defp normalize_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> 1
    end
  end

  defp normalize_page(_page), do: 1

  defp normalize_limit(limit) when is_integer(limit) and limit > 0,
    do: min(limit, @max_limit)

  defp normalize_limit(_limit), do: @default_limit

  defp normalize_since_hours(hours) when is_integer(hours) and hours > 0,
    do: min(hours, @max_since_hours)

  defp normalize_since_hours(hours) when is_binary(hours) do
    case Integer.parse(hours) do
      {parsed, ""} when parsed > 0 -> normalize_since_hours(parsed)
      _ -> @default_since_hours
    end
  end

  defp normalize_since_hours(_hours), do: @default_since_hours

  defp normalize_step_type(step_type) when is_binary(step_type) do
    step_type = String.trim(step_type)

    if step_type == "" or String.length(step_type) > 160 do
      nil
    else
      step_type
    end
  end

  defp normalize_step_type(_step_type), do: nil

  defp time_window_opt(opts) do
    Keyword.get(opts, :time_window, {Keyword.get(opts, :time_from), Keyword.get(opts, :time_to)})
  end

  defp normalize_time_window({%DateTime{} = from, %DateTime{} = to}) do
    from = DateTime.truncate(from, :second)
    to = DateTime.truncate(to, :second)

    if DateTime.compare(from, to) == :lt do
      {from, to}
    end
  end

  defp normalize_time_window(%{from: from, to: to}), do: normalize_time_window({from, to})
  defp normalize_time_window(_time_window), do: nil

  defp normalize_status(status) when status in @job_statuses, do: status
  defp normalize_status(_status), do: "all"

  defp maybe_filter_space(query, %Space{hash: space_hash}) do
    where(query, [run], fragment("?->>'space_hash' = ?", run.input, ^space_hash))
  end

  defp maybe_filter_space(query, nil), do: query

  defp maybe_filter_status(query, "all"), do: query
  defp maybe_filter_status(query, status), do: where(query, [run], run.status == ^status)

  defp maybe_filter_time_window(query, {%DateTime{} = from, %DateTime{} = to}) do
    where(query, [run], run.inserted_at >= ^from and run.inserted_at < ^to)
  end

  defp maybe_filter_time_window(query, _time_window), do: query

  defp maybe_filter_joined_run_space(query, %Space{hash: space_hash}) do
    where(query, [_step_run, run], fragment("?->>'space_hash' = ?", run.input, ^space_hash))
  end

  defp maybe_filter_joined_run_space(query, nil), do: query

  defp run_for_space(%Space{hash: space_hash}, flow_run_id) do
    Run
    |> where([run], run.id == ^flow_run_id)
    |> where([run], fragment("?->>'space_hash' = ?", run.input, ^space_hash))
    |> preload(:step_runs)
    |> Repo.one()
  end

  defp run_for_embed(%Space{hash: space_hash}, %Embed{hash: embed_hash}, flow_run_id) do
    Run
    |> where([run], run.id == ^flow_run_id)
    |> where([run], fragment("?->>'space_hash' = ?", run.input, ^space_hash))
    |> where([run], fragment("?->>'embed_hash' = ?", run.input, ^embed_hash))
    |> preload(:step_runs)
    |> Repo.one()
  end

  defp run_for_retry(flow_run_id) do
    Run
    |> where([run], run.id == ^flow_run_id)
    |> preload(:step_runs)
    |> Repo.one()
  end

  defp status_counts(space_or_nil) do
    counts =
      Run
      |> maybe_filter_space(space_or_nil)
      |> group_by([run], run.status)
      |> select([run], {run.status, count(run.id)})
      |> Repo.all()
      |> Map.new()

    activity_counts =
      Run
      |> where([run], run.status == "running")
      |> maybe_filter_space(space_or_nil)
      |> join(:left, [run], step_run in StepRun, on: step_run.flow_run_id == run.id)
      |> select([run, step_run], %{
        executing:
          filter(
            count(run.id, :distinct),
            step_run.status == "executing"
          ),
        published_background:
          filter(
            count(run.id, :distinct),
            step_run.step_type == "manifest.build" and step_run.status == "succeeded"
          )
      })
      |> Repo.one()

    then(counts, fn counts ->
      total =
        @job_statuses
        |> Enum.map(&Map.get(counts, &1, 0))
        |> Enum.sum()

      running = Map.get(counts, "running", 0)
      executing = activity_counts.executing

      %{
        total: total,
        queued: Map.get(counts, "queued", 0),
        running: running,
        executing: executing,
        awaiting_work: max(running - executing, 0),
        waiting: max(running - executing, 0),
        published_background: activity_counts.published_background,
        succeeded: Map.get(counts, "succeeded", 0),
        failed: Map.get(counts, "failed", 0),
        cancelled: Map.get(counts, "cancelled", 0)
      }
    end)
  end

  defp performance_summary(space_or_nil, since, since_hours, now) do
    %{
      since: since,
      since_hours: since_hours,
      runs: performance_run_summary(space_or_nil, since),
      throughput: throughput_buckets(space_or_nil, since, since_hours, now),
      step_metrics: performance_step_metrics(space_or_nil, since),
      ffmpeg_metrics: performance_ffmpeg_metrics(space_or_nil, since)
    }
  end

  defp step_type_run_metrics_query(step_type) do
    StepRun
    |> where([step_run], step_run.step_type == ^step_type)
    |> group_by([step_run], step_run.flow_run_id)
    |> select([step_run], %{
      flow_run_id: step_run.flow_run_id,
      step_sort_ms:
        max(
          fragment(
            "extract(epoch from (coalesce(?, now()) - coalesce(?, ?))) * 1000",
            step_run.completed_at,
            step_run.scheduled_at,
            step_run.inserted_at
          )
        )
    })
  end

  defp performance_run_summary(space_or_nil, since) do
    counts =
      Run
      |> where([run], run.inserted_at >= ^since)
      |> maybe_filter_space(space_or_nil)
      |> group_by([run], run.status)
      |> select([run], {run.status, count(run.id)})
      |> Repo.all()
      |> Map.new()

    duration =
      Run
      |> where([run], run.inserted_at >= ^since)
      |> maybe_filter_space(space_or_nil)
      |> where([run], not is_nil(run.started_at) and not is_nil(run.completed_at))
      |> select([run], %{
        completed: count(run.id),
        avg_duration_ms:
          fragment(
            "round(avg(extract(epoch from (? - ?)) * 1000))::bigint",
            run.completed_at,
            run.started_at
          ),
        p95_duration_ms:
          fragment(
            "round((percentile_cont(0.95) within group (order by extract(epoch from (? - ?)) * 1000))::numeric)::bigint",
            run.completed_at,
            run.started_at
          )
      })
      |> Repo.one()
      |> normalize_performance_duration()

    total =
      @job_statuses
      |> Enum.map(&Map.get(counts, &1, 0))
      |> Enum.sum()

    %{
      total: total,
      queued: Map.get(counts, "queued", 0),
      running: Map.get(counts, "running", 0),
      succeeded: Map.get(counts, "succeeded", 0),
      failed: Map.get(counts, "failed", 0),
      cancelled: Map.get(counts, "cancelled", 0),
      completed: duration.completed,
      avg_duration_ms: duration.avg_duration_ms,
      p95_duration_ms: duration.p95_duration_ms
    }
  end

  defp normalize_performance_duration(nil) do
    %{completed: 0, avg_duration_ms: nil, p95_duration_ms: nil}
  end

  defp normalize_performance_duration(duration) when is_map(duration) do
    %{
      completed: Map.get(duration, :completed, 0),
      avg_duration_ms: normalize_ms(Map.get(duration, :avg_duration_ms)),
      p95_duration_ms: normalize_ms(Map.get(duration, :p95_duration_ms))
    }
  end

  defp throughput_buckets(space_or_nil, since, since_hours, now) do
    rows =
      Run
      |> where([run], run.inserted_at >= ^since)
      |> maybe_filter_space(space_or_nil)
      |> group_by([run], fragment("date_trunc('hour', ?)", run.inserted_at))
      |> select([run], %{
        bucket: fragment("date_trunc('hour', ?)", run.inserted_at),
        total: count(run.id),
        failed: fragment("count(*) filter (where ? = 'failed')::bigint", run.status)
      })
      |> Repo.all()
      |> Map.new(fn row ->
        {bucket_key(row.bucket), %{total: row.total, failed: row.failed}}
      end)

    now
    |> DateTime.truncate(:second)
    |> Map.put(:minute, 0)
    |> Map.put(:second, 0)
    |> DateTime.add(-(since_hours - 1) * 60 * 60, :second)
    |> then(fn first_bucket ->
      Enum.map(0..(since_hours - 1), fn offset ->
        bucket = DateTime.add(first_bucket, offset * 60 * 60, :second)
        counts = Map.get(rows, bucket_key(bucket), %{total: 0, failed: 0})

        %{
          bucket: bucket,
          total: counts.total,
          failed: counts.failed
        }
      end)
    end)
  end

  defp performance_step_metrics(space_or_nil, since) do
    StepRun
    |> join(:inner, [step_run], run in assoc(step_run, :flow_run))
    |> where([step_run, _run], step_run.inserted_at >= ^since)
    |> maybe_filter_joined_run_space(space_or_nil)
    |> group_by([step_run, _run], step_run.step_type)
    |> select([step_run, _run], %{
      step_type: step_run.step_type,
      count: count(step_run.id),
      avg_dependency_wait_ms:
        fragment(
          "round(avg(extract(epoch from (? - ?)) * 1000))::bigint",
          step_run.scheduled_at,
          step_run.inserted_at
        ),
      avg_queue_wait_ms:
        fragment(
          "round(avg(extract(epoch from (? - ?)) * 1000))::bigint",
          step_run.started_at,
          step_run.scheduled_at
        ),
      p95_queue_wait_ms:
        fragment(
          "round((percentile_cont(0.95) within group (order by extract(epoch from (? - ?)) * 1000))::numeric)::bigint",
          step_run.started_at,
          step_run.scheduled_at
        ),
      avg_execution_ms:
        fragment(
          "round(avg(extract(epoch from (? - ?)) * 1000))::bigint",
          step_run.completed_at,
          step_run.started_at
        ),
      p95_execution_ms:
        fragment(
          "round((percentile_cont(0.95) within group (order by extract(epoch from (? - ?)) * 1000))::numeric)::bigint",
          step_run.completed_at,
          step_run.started_at
        ),
      avg_ready_total_ms:
        fragment(
          "round(avg(extract(epoch from (? - ?)) * 1000))::bigint",
          step_run.completed_at,
          step_run.inserted_at
        ),
      p95_ready_total_ms:
        fragment(
          "round((percentile_cont(0.95) within group (order by extract(epoch from (? - ?)) * 1000))::numeric)::bigint",
          step_run.completed_at,
          step_run.inserted_at
        )
    })
    |> Repo.all()
    |> Enum.map(&normalize_step_metric/1)
    |> Enum.sort_by(
      fn metric ->
        {metric_value(metric.p95_ready_total_ms), metric_value(metric.p95_queue_wait_ms),
         metric.step_type || ""}
      end,
      :desc
    )
  end

  defp normalize_step_metric(metric) do
    %{
      step_type: metric.step_type,
      count: metric.count,
      avg_dependency_wait_ms: normalize_ms(metric.avg_dependency_wait_ms),
      avg_queue_wait_ms: normalize_ms(metric.avg_queue_wait_ms),
      p95_queue_wait_ms: normalize_ms(metric.p95_queue_wait_ms),
      avg_execution_ms: normalize_ms(metric.avg_execution_ms),
      p95_execution_ms: normalize_ms(metric.p95_execution_ms),
      avg_ready_total_ms: normalize_ms(metric.avg_ready_total_ms),
      p95_ready_total_ms: normalize_ms(metric.p95_ready_total_ms)
    }
  end

  defp performance_ffmpeg_metrics(space_or_nil, since) do
    StepRun
    |> join(:inner, [step_run], run in assoc(step_run, :flow_run))
    |> where([step_run, _run], step_run.inserted_at >= ^since)
    |> where([step_run, _run], step_run.status == "succeeded")
    |> maybe_filter_joined_run_space(space_or_nil)
    |> where(
      [step_run, _run],
      fragment("?->'progress'->>'source' = 'ffmpeg'", step_run.execution_metadata)
    )
    |> where(
      [step_run, _run],
      fragment(
        "jsonb_typeof(?->'progress'->'speed_x') = 'number'",
        step_run.execution_metadata
      )
    )
    |> group_by(
      [step_run, _run],
      [
        step_run.step_type,
        fragment(
          "coalesce(nullif(?->'runtime'->>'hardware_profile', ''), 'unlabeled')",
          step_run.execution_metadata
        ),
        fragment(
          "coalesce(nullif(?->'progress'->>'codec', ''), '-')",
          step_run.execution_metadata
        ),
        fragment(
          "coalesce(nullif(?->'progress'->>'size', ''), '-')",
          step_run.execution_metadata
        ),
        fragment(
          "coalesce(nullif(?->'progress'->>'variants', ''), '-')",
          step_run.execution_metadata
        ),
        fragment(
          "coalesce(nullif(?->'progress'->>'preset', ''), '-')",
          step_run.execution_metadata
        )
      ]
    )
    |> select([step_run, _run], %{
      step_type: step_run.step_type,
      hardware_profile:
        fragment(
          "coalesce(nullif(?->'runtime'->>'hardware_profile', ''), 'unlabeled')",
          step_run.execution_metadata
        ),
      codec:
        fragment(
          "coalesce(nullif(?->'progress'->>'codec', ''), '-')",
          step_run.execution_metadata
        ),
      size:
        fragment(
          "coalesce(nullif(?->'progress'->>'size', ''), '-')",
          step_run.execution_metadata
        ),
      variants:
        fragment(
          "coalesce(nullif(?->'progress'->>'variants', ''), '-')",
          step_run.execution_metadata
        ),
      preset:
        fragment(
          "coalesce(nullif(?->'progress'->>'preset', ''), '-')",
          step_run.execution_metadata
        ),
      count: count(step_run.id),
      p50_speed_x:
        fragment(
          "percentile_cont(0.5) within group (order by ((?->'progress'->>'speed_x')::double precision))",
          step_run.execution_metadata
        ),
      p10_speed_x:
        fragment(
          "percentile_cont(0.1) within group (order by ((?->'progress'->>'speed_x')::double precision))",
          step_run.execution_metadata
        ),
      avg_fps:
        fragment(
          "avg(nullif(?->'progress'->>'fps', '')::double precision)",
          step_run.execution_metadata
        ),
      p95_ffmpeg_elapsed_ms:
        fragment(
          "round((percentile_cont(0.95) within group (order by (nullif(?->'progress'->>'ffmpeg_elapsed_ms', '')::double precision)))::numeric)::bigint",
          step_run.execution_metadata
        )
    })
    |> Repo.all()
    |> Enum.map(&normalize_ffmpeg_metric/1)
    |> Enum.sort_by(&{&1.hardware_profile, &1.step_type, &1.codec, &1.size, &1.preset})
  end

  defp normalize_ffmpeg_metric(metric) do
    %{
      step_type: metric.step_type,
      hardware_profile: metric.hardware_profile,
      codec: metric.codec,
      size: metric.size,
      variants: metric.variants,
      preset: metric.preset,
      count: metric.count,
      p50_speed_x: normalize_float(metric.p50_speed_x),
      p10_speed_x: normalize_float(metric.p10_speed_x),
      avg_fps: normalize_float(metric.avg_fps),
      p95_ffmpeg_elapsed_ms: normalize_ms(metric.p95_ffmpeg_elapsed_ms)
    }
  end

  defp normalize_ms(nil), do: nil
  defp normalize_ms(value) when is_integer(value), do: value
  defp normalize_ms(value) when is_float(value), do: round(value)
  defp normalize_ms(%Decimal{} = value), do: value |> Decimal.round() |> Decimal.to_integer()

  defp normalize_float(nil), do: nil
  defp normalize_float(value) when is_float(value), do: Float.round(value, 3)
  defp normalize_float(value) when is_integer(value), do: value * 1.0
  defp normalize_float(%Decimal{} = value), do: value |> Decimal.to_float() |> Float.round(3)

  defp metric_value(nil), do: 0
  defp metric_value(value) when is_integer(value), do: value

  defp bucket_key(%DateTime{} = bucket), do: DateTime.to_unix(bucket, :second)

  defp bucket_key(%NaiveDateTime{} = bucket) do
    bucket
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:second)
  end

  defp spaces_by_hash(runs) do
    space_hashes =
      runs
      |> Enum.map(&get_in(&1.input || %{}, ["space_hash"]))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    Space
    |> where([space], space.hash in ^space_hashes)
    |> preload(:domains)
    |> Repo.all()
    |> Map.new(&{&1.hash, &1})
  end

  defp embeds_by_key(runs, _spaces_by_hash) do
    pairs =
      runs
      |> Enum.map(fn run ->
        {get_in(run.input || %{}, ["space_hash"]), get_in(run.input || %{}, ["embed_hash"])}
      end)
      |> Enum.filter(fn {space_hash, embed_hash} ->
        is_binary(space_hash) and is_binary(embed_hash)
      end)
      |> Enum.uniq()

    embed_hashes =
      pairs
      |> Enum.map(fn {_space_hash, embed_hash} -> embed_hash end)
      |> Enum.uniq()

    Embed
    |> where([embed], embed.hash in ^embed_hashes)
    |> preload(space: :domains)
    |> Repo.all()
    |> Map.new(fn embed ->
      {{maybe_get(embed.space, :hash), embed.hash}, embed}
    end)
  end

  defp summarize_run(
         %Run{} = run,
         spaces_by_hash,
         embeds_by_key,
         stale_before,
         now,
         step_type_filter
       ) do
    selected_step = selected_step(run.step_runs, step_type_filter, now)
    failed_step = Enum.find(run.step_runs, &(&1.status == "failed"))
    stale_step = active_run_step(run, &stale_step?(&1, stale_before))

    active_step =
      active_run_step(run, &(&1.status == "executing")) ||
        active_run_step(run, &(&1.status == "scheduled")) ||
        active_run_step(run, &(&1.status == "queued"))

    completed_step = latest_completed_step(run.step_runs)

    focus_step =
      first_present([selected_step, failed_step, stale_step, active_step, completed_step])

    space_hash = get_in(run.input || %{}, ["space_hash"])
    embed_hash = get_in(run.input || %{}, ["embed_hash"])
    embed = embed_for_key(embeds_by_key, space_hash, embed_hash)
    space = space_for_run(embed, spaces_by_hash, space_hash)

    %{
      id: run.id,
      status: run.status,
      published?: published_run?(run),
      reason: run_reason(run, failed_step, stale_step, active_step, stale_before),
      template_slug: maybe_get(run.flow_template, :slug),
      flow_version_number: maybe_get(run.flow_version, :version),
      space_id: maybe_get(space, :id),
      space_hash: space_hash,
      space_domain: space_domain(space),
      embed_hash: embed_hash,
      embed: embed,
      dashboard_embed_id: dashboard_embed_id(embed),
      public_embed_id: public_embed_id(space, embed, embed_hash),
      selected_step_type: step_type_filter,
      step_id: maybe_get(focus_step, :step_id),
      step_type: maybe_get(focus_step, :step_type),
      step_status: maybe_get(focus_step, :status),
      step_attempt: maybe_get(focus_step, :attempt),
      execution_metadata: execution_metadata(focus_step),
      retry_step_id: maybe_get(failed_step, :step_id),
      recoverable?: recoverable_run?(run),
      error: compact_error(failure_error(failed_step, run)),
      run_duration_ms: runtime_ms(run, now),
      step_dependency_wait_ms: step_timing_ms(focus_step, now, :dependency),
      step_queue_wait_ms: step_timing_ms(focus_step, now, :queue),
      step_execution_ms: step_timing_ms(focus_step, now, :execution),
      step_ready_total_ms: step_timing_ms(focus_step, now, :ready_total),
      steps: summarize_steps(run, now),
      started_at: run.started_at,
      completed_at: run.completed_at,
      inserted_at: run.inserted_at,
      updated_at: run.updated_at
    }
  end

  defp first_present(values), do: Enum.find(values, &(not is_nil(&1)))

  defp published_run?(%Run{status: "running", step_runs: step_runs}) when is_list(step_runs) do
    Enum.any?(step_runs, fn step_run ->
      step_run.step_type == "manifest.build" and step_run.status == "succeeded"
    end)
  end

  defp published_run?(_run), do: false

  defp maybe_get(nil, _field), do: nil
  defp maybe_get(value, field), do: Map.get(value, field)

  defp space_for_hash(spaces_by_hash, space_hash) when is_binary(space_hash) do
    Map.get(spaces_by_hash, space_hash)
  end

  defp space_for_hash(_spaces_by_hash, _space_hash), do: nil

  defp embed_for_key(embeds_by_key, space_hash, embed_hash) when is_binary(embed_hash) do
    Map.get(embeds_by_key, {space_hash, embed_hash})
  end

  defp embed_for_key(_embeds_by_key, _space_hash, _embed_hash), do: nil

  defp space_for_run(%Embed{space: %Space{} = space}, _spaces_by_hash, _space_hash), do: space

  defp space_for_run(_embed, spaces_by_hash, space_hash),
    do: space_for_hash(spaces_by_hash, space_hash)

  defp failure_error(nil, run), do: run.error
  defp failure_error(failed_step, run), do: first_present([failed_step.error, run.error])

  defp recoverable_run?(%Run{status: "failed", flow_version: flow_version, step_runs: step_runs})
       when is_list(step_runs) do
    definition = maybe_get(flow_version, :definition) || %{}
    step_runs_by_id = Map.new(step_runs, fn step_run -> {step_run.step_id, step_run} end)

    Enum.any?(Definition.steps(definition), fn step_definition ->
      Definition.required?(step_definition) and
        match?(%{status: "failed"}, Map.get(step_runs_by_id, step_definition["id"]))
    end)
  end

  defp recoverable_run?(_run), do: false

  defp step_timing_ms(nil, _now, _kind), do: nil
  defp step_timing_ms(step, now, :dependency), do: dependency_wait_ms(step, now)
  defp step_timing_ms(step, now, :queue), do: queue_wait_ms(step, now)
  defp step_timing_ms(step, now, :execution), do: execution_ms(step, now)
  defp step_timing_ms(step, now, :ready_total), do: ready_total_ms(step, now)

  defp execution_metadata(%StepRun{execution_metadata: metadata}) when is_map(metadata) do
    metadata
  end

  defp execution_metadata(_step_run), do: %{}

  defp selected_step(step_runs, step_type, now)
       when is_list(step_runs) and is_binary(step_type) do
    step_runs
    |> Enum.filter(&(&1.step_type == step_type))
    |> Enum.max_by(&step_sort_ms(&1, now), fn -> nil end)
  end

  defp selected_step(_step_runs, _step_type, _now), do: nil

  defp summarize_steps(%Run{flow_version: %{definition: definition}, step_runs: step_runs}, now)
       when is_list(step_runs) do
    order = definition_step_order(definition)

    step_runs
    |> Enum.sort_by(&step_sort_key(&1, order))
    |> Enum.map(&summarize_step(&1, now))
  end

  defp summarize_steps(_run, _now), do: []

  defp summarize_step(%StepRun{} = step_run, now) do
    %{
      step_id: step_run.step_id,
      step_type: step_run.step_type,
      step_status: step_run.status,
      step_attempt: step_run.attempt,
      step_dependency_wait_ms: dependency_wait_ms(step_run, now),
      step_queue_wait_ms: queue_wait_ms(step_run, now),
      step_execution_ms: execution_ms(step_run, now),
      step_ready_total_ms: ready_total_ms(step_run, now),
      execution_metadata: execution_metadata(step_run),
      error: compact_error(step_run.error),
      scheduled_at: step_run.scheduled_at,
      started_at: step_run.started_at,
      completed_at: step_run.completed_at,
      inserted_at: step_run.inserted_at,
      updated_at: step_run.updated_at
    }
  end

  defp definition_step_order(definition) when is_map(definition) do
    definition
    |> Definition.steps()
    |> Enum.with_index()
    |> Map.new(fn {step, index} -> {Map.get(step, "id"), index} end)
  end

  defp definition_step_order(_definition), do: %{}

  defp step_sort_key(%StepRun{} = step_run, order) do
    {Map.get(order, step_run.step_id, 1_000_000), datetime_sort_value(step_run.inserted_at),
     step_run.step_id || ""}
  end

  defp step_sort_ms(%StepRun{} = step_run, now) do
    start = step_run.inserted_at
    finish = step_run.completed_at || now

    case {start, finish} do
      {%DateTime{} = start, %DateTime{} = finish} -> duration_ms(start, finish)
      _ -> 0
    end
  end

  defp datetime_sort_value(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)
  defp datetime_sort_value(_datetime), do: 0

  defp runtime_ms(
         %{started_at: %DateTime{} = started_at, completed_at: %DateTime{} = completed_at},
         _now
       ) do
    duration_ms(started_at, completed_at)
  end

  defp runtime_ms(%{started_at: %DateTime{} = started_at, completed_at: nil}, %DateTime{} = now) do
    duration_ms(started_at, now)
  end

  defp runtime_ms(_run_or_step, _now), do: nil

  defp dependency_wait_ms(
         %StepRun{
           scheduled_at: %DateTime{} = scheduled_at,
           inserted_at: %DateTime{} = inserted_at
         },
         _now
       ) do
    duration_ms(inserted_at, scheduled_at)
  end

  defp dependency_wait_ms(
         %StepRun{status: "queued", scheduled_at: nil, inserted_at: %DateTime{} = inserted_at},
         %DateTime{} = now
       ) do
    duration_ms(inserted_at, now)
  end

  defp dependency_wait_ms(_step_run, _now), do: nil

  defp queue_wait_ms(
         %StepRun{scheduled_at: %DateTime{} = scheduled_at, started_at: %DateTime{} = started_at},
         _now
       ) do
    duration_ms(scheduled_at, started_at)
  end

  defp queue_wait_ms(
         %StepRun{scheduled_at: %DateTime{} = scheduled_at, started_at: nil},
         %DateTime{} = now
       ) do
    duration_ms(scheduled_at, now)
  end

  defp queue_wait_ms(_step_run, _now), do: nil

  defp execution_ms(
         %StepRun{started_at: %DateTime{} = started_at, completed_at: %DateTime{} = completed_at},
         _now
       ) do
    duration_ms(started_at, completed_at)
  end

  defp execution_ms(
         %StepRun{started_at: %DateTime{} = started_at, completed_at: nil},
         %DateTime{} = now
       ) do
    duration_ms(started_at, now)
  end

  defp execution_ms(_step_run, _now), do: nil

  defp ready_total_ms(
         %StepRun{
           inserted_at: %DateTime{} = inserted_at,
           completed_at: %DateTime{} = completed_at
         },
         _now
       ) do
    duration_ms(inserted_at, completed_at)
  end

  defp ready_total_ms(
         %StepRun{inserted_at: %DateTime{} = inserted_at, completed_at: nil},
         %DateTime{} = now
       ) do
    duration_ms(inserted_at, now)
  end

  defp ready_total_ms(_step_run, _now), do: nil

  defp duration_ms(%DateTime{} = started_at, %DateTime{} = finished_at) do
    max(DateTime.diff(finished_at, started_at, :millisecond), 0)
  end

  defp stale_step?(%StepRun{status: status, updated_at: %DateTime{} = updated_at}, stale_before) do
    status in ["executing", "scheduled"] and
      DateTime.compare(updated_at, stale_before) == :lt
  end

  defp stale_step?(_step, _stale_before), do: false

  defp active_run_step(%Run{status: status, step_runs: step_runs}, predicate)
       when status in @active_statuses and is_list(step_runs) and is_function(predicate, 1) do
    Enum.find(step_runs, predicate)
  end

  defp active_run_step(_run, _predicate), do: nil

  defp latest_completed_step(step_runs) when is_list(step_runs) do
    step_runs
    |> Enum.filter(&completed_step?/1)
    |> Enum.max_by(&DateTime.to_unix(&1.completed_at, :microsecond), fn -> nil end)
  end

  defp completed_step?(%StepRun{status: status, completed_at: %DateTime{}}) do
    status in ["succeeded", "failed", "cancelled", "skipped"]
  end

  defp completed_step?(_step_run), do: false

  defp run_reason(%Run{status: "failed"}, _failed_step, _stale_step, _active_step, _stale_before),
    do: :failed

  defp run_reason(_run, %StepRun{}, _stale_step, _active_step, _stale_before),
    do: :failed_step

  defp run_reason(_run, _failed_step, %StepRun{}, _active_step, _stale_before),
    do: :stale_step

  defp run_reason(
         %Run{status: status, updated_at: %DateTime{} = updated_at},
         _failed,
         _stale,
         active_step,
         stale_before
       )
       when status in @active_statuses do
    if DateTime.compare(updated_at, stale_before) == :lt do
      :stale_run
    else
      active_run_reason(active_step)
    end
  end

  defp run_reason(
         %Run{status: "cancelled"},
         _failed_step,
         _stale_step,
         _active_step,
         _stale_before
       ),
       do: :cancelled

  defp run_reason(
         %Run{status: "succeeded"},
         _failed_step,
         _stale_step,
         _active_step,
         _stale_before
       ),
       do: :succeeded

  defp run_reason(_run, _failed_step, _stale_step, _active_step, _stale_before), do: :attention

  defp active_run_reason(%StepRun{status: "executing"}), do: :executing

  defp active_run_reason(%StepRun{status: status}) when status in ["scheduled", "queued"],
    do: :waiting

  defp active_run_reason(_step_run), do: :waiting

  defp dashboard_embed_id(%Embed{} = embed), do: Embeds.dashboard_embed_id(embed)
  defp dashboard_embed_id(_embed), do: nil

  defp public_embed_id(%Space{} = space, %Embed{version: 2} = embed, _embed_hash) do
    SettingsSerializer.public_embed_id(space, embed)
  end

  defp public_embed_id(_space, _embed, embed_hash), do: embed_hash

  defp space_domain(%Space{domains: domains}) when is_list(domains) do
    case List.first(domains) do
      %{domain: domain} when is_binary(domain) -> domain
      _ -> nil
    end
  end

  defp space_domain(_space), do: nil

  defp compact_error(nil), do: nil

  defp compact_error(error) when is_binary(error) do
    error
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 240)
  end

  defp compact_error(error), do: error |> inspect() |> compact_error()
end
