defmodule MaveCore.Analytics.Sessions do
  @moduledoc """
  Versioned playback sessions, rebuilt in bounded buckets after source changes.

  PostgreSQL publishes the active generation only after its ClickHouse insert
  completes. Readers keep using the previous complete generation during refresh.
  Inventory revisions are measured from the rows actually used by the build, so
  an insert racing with a refresh is picked up by the following inventory poll.
  """
  alias MaveCore.Analytics.Sessions.Query
  alias MaveCore.{ClickHouseRepo, Repo, SharedStorageSpace}

  def enabled?, do: Application.get_env(:mave_core, :analytics_sessions, [])[:enabled] == true

  def enabled?(space_hash) do
    config = Application.get_env(:mave_core, :analytics_sessions, [])
    spaces = Keyword.get(config, :read_spaces, :all)
    enabled?() and (spaces == :all or (is_list(spaces) and space_hash in spaces))
  end

  def processing_enabled? do
    config = Application.get_env(:mave_core, :analytics_sessions, [])
    Keyword.get(config, :processor_enabled, enabled?()) == true
  end

  def data(space_hash, opts \\ []) do
    with :ok <- validate_hash(space_hash) do
      if SharedStorageSpace.hash?(space_hash) do
        {:ok, empty(space_hash)}
      else
        read_data(space_hash, opts)
      end
    end
  end

  defp read_data(space_hash, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, {generations, latest, due}} <- read_snapshot(space_hash),
         params = params(space_hash, generations, now),
         {query, unique_query} = overview_query(now, latest, due),
         {:ok, %{rows: rows}} <- ch(query, params, 15_000),
         {:ok, unique} <- maybe_unique(params, opts, unique_query) do
      {:ok, rows |> map_overview(space_hash) |> Map.put(:unique_watch_time, unique)}
    else
      {:empty, _} -> {:ok, empty(space_hash)}
      {:error, :preparing} -> {:error, :preparing}
      _ -> {:error, :analytics_unavailable}
    end
  end

  def monthly_watch_time(space_hash) do
    now = DateTime.utc_now()
    date = DateTime.to_date(now)
    from = DateTime.new!(Date.new!(date.year, date.month, 1), ~T[00:00:00])

    with {:ok, generations} <- generations(space_hash),
         {:ok, %{rows: [[value]]}} <-
           ch(Query.monthly_watch_time(), [space_hash, generations, from, now], 6_000) do
      {:ok, %{watch_time: %{month: value}}}
    else
      {:empty, _} -> {:ok, %{watch_time: %{month: 0}}}
      {:error, :preparing} -> {:error, :preparing}
      _ -> {:error, :analytics_unavailable}
    end
  end

  defp maybe_unique(params, opts, query) do
    if Keyword.get(opts, :include_unique, false) do
      case ch(query, params, 20_000) do
        {:ok, %{rows: [[today, month, year]]}} ->
          {:ok, %{today: today, month: month, year: year}}

        _ ->
          {:error, :analytics_unavailable}
      end
    else
      {:ok, nil}
    end
  end

  @doc """
  Bounded UTC range totals and buckets from prepared segments, never raw events.
  `to` is exclusive. Use `mode: :videos` for CSV batches/top lists and
  `embed_hashes: [...]` to restrict the work to a set of videos.
  """
  def range_data(space_hash, from, to, opts \\ [])

  def range_data(space_hash, %DateTime{} = from, %DateTime{} = to, opts) do
    granularity = Keyword.get(opts, :granularity, :day)
    mode = Keyword.get(opts, :mode, :series)
    hashes = Keyword.get(opts, :embed_hashes, [])

    with :ok <- validate_hash(space_hash),
         true <- granularity in [:day, :week, :month] and mode in [:series, :videos],
         true <- DateTime.diff(to, from) in 1..(732 * 86_400),
         true <-
           is_list(hashes) and length(hashes) <= 250 and
             Enum.all?(hashes, &(is_binary(&1) and byte_size(&1) in 1..128)),
         {:ok, generations} <- generations(space_hash),
         sql = range_query(space_hash, generations, from, to, granularity, mode),
         {:ok, %{rows: rows}} <-
           ch(sql, [space_hash, generations, from, to, hashes], 20_000) do
      {:ok,
       Map.new(rows, fn [key, views, watched, completion] ->
         {key, %{views: views, watch_seconds: watched, completion_rate: completion}}
       end)}
    else
      {:empty, _} -> {:ok, %{}}
      false -> {:error, :invalid_range}
      {:error, :preparing} -> {:error, :preparing}
      _ -> {:error, :analytics_unavailable}
    end
  end

  def range_data(_space_hash, _from, _to, _opts), do: {:error, :invalid_range}

  defp range_query(space, generations, from, to, granularity, mode) do
    if mode == :series and midnight?(from) and
         (midnight?(to) or reports_cover_time?(space, generations, to)) and
         reports_complete?(space, generations),
       do: Query.report_range(granularity),
       else: Query.range(granularity, mode)
  end

  defp midnight?(at), do: rem(DateTime.to_unix(at, :microsecond), 86_400_000_000) == 0

  defp reports_cover_time?(space, generations, to) do
    case Repo.query(
           "SELECT count(*), max(latest_event_at), min(refresh_after) FROM analytics_session_buckets WHERE space_hash=$1 AND generation::text = ANY($2)",
           [space, generations]
         ) do
      {:ok, %{rows: [[count, latest, nil]]}} ->
        count == Query.buckets() and
          (is_nil(latest) or NaiveDateTime.compare(naive(to), latest) != :lt)

      _ ->
        false
    end
  end

  defp reports_complete?(space, generations) do
    case ch(Query.report_coverage(), [space, generations], 5_000) do
      {:ok, %{rows: [[0]]}} -> true
      _ -> false
    end
  end

  @doc "Active immutable generations for custom reports on the session table."
  def generations(space_hash) do
    if SharedStorageSpace.hash?(space_hash),
      do: {:empty, space_hash},
      else: do_generations(space_hash)
  end

  defp do_generations(space_hash) do
    with :ok <- validate_hash(space_hash),
         {:ok, %{rows: rows}} <-
           Repo.query(
             "SELECT generation::text FROM analytics_session_buckets WHERE space_hash = $1 AND format_version = $2 ORDER BY bucket",
             [space_hash, Query.version()]
           ) do
      generation_result(space_hash, rows)
    end
  end

  defp generation_result(space, rows) do
    if length(rows) == Query.buckets(),
      do: {:ok, List.flatten(rows)},
      else: source_readiness(space)
  end

  defp source_readiness(space) do
    case ch("SELECT 1 FROM events PREWHERE space_hash = {$0:String} LIMIT 1", [space]) do
      {:ok, %{rows: []}} -> {:empty, space}
      {:ok, _} -> {:error, :preparing}
      _ -> {:error, :analytics_unavailable}
    end
  end

  @doc "Refresh changed buckets. Safe to retry after partial execution or a crash."
  def refresh_changed(opts \\ []) do
    limit = Keyword.get(opts, :limit, setting(:refresh_bucket_limit, 4))
    target = Keyword.get(opts, :space_hash)
    scope = Keyword.get(opts, :spaces, :all)

    with :ok <- validate_optional_hash(target),
         :ok <- validate_scope(scope),
         {:ok, %{rows: inventory}} <- ch(Query.inventory(), [], 30_000),
         {:ok, %{rows: published}} <-
           Repo.query(
             "SELECT space_hash, bucket, source_rows, fingerprint, updated_at, format_version, refresh_after FROM analytics_session_buckets"
           ) do
      current =
        published
        |> Enum.filter(fn [_, _, _, _, _, version, _] -> version == Query.version() end)
        |> Map.new(fn [space, bucket, count, hash, _, _, _] ->
          {{space, bucket}, {count, hash}}
        end)

      ages =
        Map.new(published, fn [space, bucket, _, _, updated, _, _] ->
          {{space, bucket}, to_string(updated)}
        end)

      due =
        Map.new(published, fn [space, bucket, _, _, _, _, at] ->
          {{space, bucket}, refresh_due?(at)}
        end)

      source =
        Map.new(inventory, fn [space, bucket, count, hash] -> {{space, bucket}, {count, hash}} end)

      spaces = Enum.uniq(Enum.map(Map.keys(source), &elem(&1, 0)) ++ Enum.map(published, &hd/1))
      spaces = Enum.filter(spaces, &(validate_hash(&1) == :ok))
      spaces = if target, do: Enum.filter(spaces, &(&1 == target)), else: spaces
      spaces = if scope == :all, do: spaces, else: Enum.filter(spaces, &(&1 in scope))

      changes =
        for space <- Enum.sort(spaces),
            not SharedStorageSpace.hash?(space),
            bucket <- 0..(Query.buckets() - 1),
            revision = Map.get(source, {space, bucket}, {0, "0"}),
            Map.get(current, {space, bucket}) != revision or Map.get(due, {space, bucket}, false),
            do: {space, bucket, revision}

      {count, errors} =
        changes
        |> Enum.sort_by(fn {space, bucket, _} ->
          {Map.get(ages, {space, bucket}, ""), space, bucket}
        end)
        |> Enum.take(limit)
        |> Enum.reduce({0, 0}, &rebuild_one/2)

      if errors == 0, do: {:ok, count}, else: {:error, {:buckets_failed, errors}}
    end
  end

  defp validate_scope(:all), do: :ok

  defp validate_scope(spaces) when is_list(spaces) do
    if Enum.all?(spaces, &(validate_hash(&1) == :ok)),
      do: :ok,
      else: {:error, :invalid_space_hash}
  end

  defp validate_scope(_spaces), do: {:error, :invalid_space_hash}

  defp rebuild_one({space, bucket, revision}, {count, errors}) do
    case refresh_bucket(space, bucket, revision) do
      {:ok, _} -> {count + 1, errors}
      {:error, _} -> {count, errors + 1}
    end
  end

  @doc false
  def refresh_bucket(space_hash, bucket, revision) do
    with :ok <- validate_hash(space_hash), true <- bucket in 0..(Query.buckets() - 1) do
      Repo.transaction(fn -> refresh_locked(space_hash, bucket, revision) end, timeout: 180_000)
    else
      _ -> {:error, :invalid_bucket}
    end
  end

  defp refresh_locked(space, bucket, revision) do
    lock!(space)

    existing =
      Repo.query!(
        "SELECT source_rows, fingerprint, format_version, refresh_after FROM analytics_session_buckets WHERE space_hash = $1 AND bucket = $2",
        [space, bucket]
      ).rows

    if unchanged?(existing, revision), do: :unchanged, else: build_bucket!(space, bucket)
  end

  defp build_bucket!(space_hash, bucket) do
    generation = Ecto.UUID.generate()
    {previous, changed, full, report_full, overview_full} = build_plan!(space_hash, bucket)
    params = [space_hash, bucket, generation, changed, full]

    with :ok <-
           copy_previous(
             space_hash,
             bucket,
             generation,
             previous,
             changed,
             report_full,
             overview_full
           ),
         {:ok, _} <- ch(Query.build(), params, 90_000),
         {:ok, _} <-
           ch(
             Query.build_overview(),
             [space_hash, bucket, generation, changed, overview_full],
             90_000
           ),
         {:ok, _} <-
           ch(
             Query.build_reports(),
             [space_hash, bucket, generation, changed, report_full],
             90_000
           ),
         {:ok, %{rows: [[count, fingerprint, refresh_after, latest]]}} <-
           ch(Query.revision(), Enum.take(params, 3)) do
      retire_previous!(space_hash, bucket)

      # Publication is the only mutable pointer. A failed build leaves this row
      # untouched, and a later attempt uses a different generation UUID.
      Repo.query!(
        """
        INSERT INTO analytics_session_buckets
          (space_hash, bucket, generation, source_rows, fingerprint, format_version, refresh_after, latest_event_at, updated_at)
        VALUES ($1, $2, $3::text::uuid, $4, $5, $6, $7, $8, now())
        ON CONFLICT (space_hash, bucket) DO UPDATE SET
          generation = EXCLUDED.generation, source_rows = EXCLUDED.source_rows,
          fingerprint = EXCLUDED.fingerprint, format_version = EXCLUDED.format_version,
          refresh_after = EXCLUDED.refresh_after, latest_event_at = EXCLUDED.latest_event_at, updated_at = EXCLUDED.updated_at
        """,
        [
          space_hash,
          bucket,
          generation,
          count,
          fingerprint,
          Query.version(),
          naive(refresh_after),
          naive(latest)
        ]
      )

      generation
    else
      _ ->
        discard_generation(space_hash, generation)
        Repo.rollback(:analytics_unavailable)
    end
  end

  defp build_plan!(space, bucket) do
    case Repo.query!(
           "SELECT generation::text, format_version, refresh_after FROM analytics_session_buckets WHERE space_hash = $1 AND bucket = $2",
           [space, bucket]
         ).rows do
      [[previous, version, due]] ->
        if version in [3, 4, Query.version()] and not refresh_due?(due) do
          {previous, changed, full} = changed_plan!(space, bucket, previous)

          {previous, changed, full, report_refresh_mode(version, full),
           overview_refresh_mode(version, full)}
        else
          {nil, [], 1, 1, 1}
        end

      [] ->
        {nil, [], 1, 1, 1}
    end
  end

  defp overview_refresh_mode(version, _full) when version in [3, 4], do: 1
  defp overview_refresh_mode(_version, full), do: full

  defp report_refresh_mode(3, _full), do: 1
  defp report_refresh_mode(_version, full), do: full

  defp changed_plan!(space, bucket, previous) do
    case ch(Query.changed_sessions(), [space, bucket, previous], 90_000) do
      {:ok, %{rows: rows}} when length(rows) <= 50_000 ->
        {previous, Enum.map(rows, fn [id] -> uuid_string(id) end), 0}

      {:ok, _} ->
        {nil, [], 1}

      _ ->
        Repo.rollback(:analytics_unavailable)
    end
  end

  defp uuid_string(<<_::128>> = value) do
    {:ok, uuid} = Ecto.UUID.load(value)
    uuid
  end

  defp uuid_string(value), do: value

  defp copy_previous(_space, _bucket, _generation, nil, _changed, _report_full, _overview_full),
    do: :ok

  defp copy_previous(space, bucket, generation, previous, changed, report_full, overview_full) do
    params = [space, bucket, generation, previous, changed]

    with {:ok, _} <- ch(Query.copy_sessions(), params, 90_000),
         :ok <- copy_overview(params, overview_full),
         do: copy_reports(params, report_full)
  end

  defp copy_overview(_params, 1), do: :ok

  defp copy_overview(params, 0) do
    case ch(Query.copy_overview(), params, 90_000) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp copy_reports(_params, 1), do: :ok

  defp copy_reports(params, 0) do
    case ch(Query.copy_reports(), params, 90_000) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp discard_generation(space, generation) do
    # This UUID was never published, so no reader can depend on its partitions.
    delete_retired(space, [generation])
    :ok
  end

  @doc "Hide retired analytics immediately; obsolete generations are collected separately."
  def invalidate(space_hash) do
    with :ok <- validate_hash(space_hash), do: invalidate_transaction(space_hash)
  end

  defp invalidate_transaction(space_hash) do
    case Repo.transaction(fn -> invalidate_locked(space_hash) end, timeout: 180_000) do
      {:ok, {:error, _} = error} -> error
      result -> result
    end
  end

  defp invalidate_locked(space) do
    lock!(space)
    Repo.query!("DELETE FROM analytics_session_buckets WHERE space_hash = $1", [space])

    with {:ok, _} <-
           ch(
             "ALTER TABLE analytics_sessions DELETE WHERE space_hash = {$0:String} SETTINGS mutations_sync = 1",
             [space],
             60_000
           ),
         {:ok, _} <-
           ch(
             "ALTER TABLE analytics_session_years DELETE WHERE space_hash = {$0:String} SETTINGS mutations_sync = 1",
             [space],
             60_000
           ),
         {:ok, _} <-
           ch(
             "ALTER TABLE analytics_session_reports DELETE WHERE space_hash = {$0:String} SETTINGS mutations_sync = 1",
             [space],
             60_000
           ) do
      Repo.query!("DELETE FROM analytics_session_retirements WHERE space_hash = $1", [space])
      :ok
    else
      _ -> {:error, :analytics_unavailable}
    end
  end

  @doc "Delete retired generations after the reader grace period, in batches per space."
  def cleanup do
    with {:ok, %{rows: rows}} <-
           Repo.query("""
           SELECT space_hash FROM analytics_session_buckets
           GROUP BY space_hash ORDER BY min(last_cleanup_at) ASC NULLS FIRST
           """),
         {:ok, %{rows: stored}} <- ch(Query.stored_spaces(), [], 60_000) do
      ((stored -- rows) ++ rows)
      |> Enum.take(setting(:cleanup_space_limit, 32))
      |> Enum.reduce_while(:ok, &cleanup_one/2)
    end
  end

  defp cleanup_one([space], :ok) do
    case Repo.transaction(fn -> cleanup_locked(space) end, timeout: 180_000) do
      {:ok, :ok} -> {:cont, :ok}
      _ -> {:halt, {:error, :cleanup_failed}}
    end
  end

  defp cleanup_locked(space) do
    lock!(space)
    discover_retired!(space)

    generations =
      Repo.query!(
        """
        SELECT r.generation::text FROM analytics_session_retirements r
        WHERE r.space_hash = $1 AND r.retired_at < now() - make_interval(secs => $2)
          AND NOT EXISTS (SELECT 1 FROM analytics_session_buckets b
            WHERE b.space_hash = r.space_hash AND b.generation = r.generation)
        ORDER BY r.retired_at LIMIT $3
        """,
        [
          space,
          max(120, setting(:reader_grace_seconds, 300)),
          setting(:cleanup_generation_limit, 64)
        ]
      ).rows
      |> List.flatten()

    case delete_retired(space, generations) do
      :ok ->
        Repo.query!(
          "DELETE FROM analytics_session_retirements WHERE space_hash = $1 AND generation = ANY($2::text[]::uuid[])",
          [space, generations]
        )

        Repo.query!(
          "UPDATE analytics_session_buckets SET last_cleanup_at = now() WHERE space_hash = $1",
          [space]
        )

        :ok

      _ ->
        Repo.rollback(:cleanup_failed)
    end
  end

  defp retire_previous!(space, bucket) do
    Repo.query!(
      """
      INSERT INTO analytics_session_retirements (space_hash, generation, retired_at)
      SELECT space_hash, generation, now() FROM analytics_session_buckets
      WHERE space_hash = $1 AND bucket = $2
      ON CONFLICT (space_hash, generation) DO UPDATE SET retired_at = EXCLUDED.retired_at
      """,
      [space, bucket]
    )
  end

  defp discover_retired!(space) do
    # Recover unpublished inserts left by a process crash. Start their grace
    # period at discovery; creation time cannot prove when a reader last used them.
    case ch(Query.stored_generations(), [space], 60_000) do
      {:ok, %{rows: rows}} ->
        Repo.query!(
          """
          INSERT INTO analytics_session_retirements (space_hash, generation, retired_at)
          SELECT $1, g::uuid, now() FROM unnest($2::text[]) AS g
          WHERE NOT EXISTS (SELECT 1 FROM analytics_session_buckets b
            WHERE b.space_hash = $1 AND b.generation = g::uuid)
          ON CONFLICT DO NOTHING
          """,
          [space, List.flatten(rows)]
        )

      _ ->
        Repo.rollback(:cleanup_failed)
    end
  end

  defp delete_retired(space, generations) do
    Enum.reduce_while(generations, :ok, fn generation, :ok ->
      with {:ok, _} <- ch(Query.cleanup(), [space, generation], 60_000),
           {:ok, _} <- ch(Query.cleanup_overview(), [space, generation], 60_000),
           {:ok, _} <- ch(Query.cleanup_reports(), [space, generation], 60_000) do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, :cleanup_failed}}
      end
    end)
  end

  defp setting(key, default) do
    Application.get_env(:mave_core, :analytics_sessions, []) |> Keyword.get(key, default)
  end

  defp unchanged?([[count, fingerprint, version, refresh_after]], {count, fingerprint}),
    do: version == Query.version() and not refresh_due?(refresh_after)

  defp unchanged?(_, _), do: false

  defp refresh_due?(nil), do: false
  defp refresh_due?(at), do: NaiveDateTime.compare(naive(at), NaiveDateTime.utc_now()) != :gt
  defp naive(nil), do: nil

  defp naive(%DateTime{} = at),
    do:
      at
      |> DateTime.to_unix(:microsecond)
      |> DateTime.from_unix!(:microsecond)
      |> DateTime.to_naive()

  defp naive(%NaiveDateTime{} = at), do: at

  defp read_snapshot(space) do
    # Read pointers and time boundaries in the same PostgreSQL snapshot. A
    # concurrent publication cannot switch the fast-path decision underneath
    # a reader that is still using the previous immutable generation.
    case Repo.query(
           "SELECT array_agg(generation::text ORDER BY bucket), max(latest_event_at), min(refresh_after), count(*) FROM analytics_session_buckets WHERE space_hash=$1 AND format_version=$2",
           [space, Query.version()]
         ) do
      {:ok, %{rows: [[generations, latest, due, 16]]}} ->
        {:ok, {generations, latest, due}}

      {:ok, _} ->
        source_readiness(space)

      _ ->
        {:error, :analytics_unavailable}
    end
  end

  defp overview_query(now, latest, due) do
    historical? = not is_nil(latest) and NaiveDateTime.compare(naive(now), latest) == :lt
    newly_visible? = not is_nil(due) and NaiveDateTime.compare(naive(now), due) != :lt

    if historical? or newly_visible?,
      do: {Query.overview_at(), Query.unique_watch_time()},
      else: {Query.overview(), Query.unique_overview()}
  end

  defp lock!(space_hash) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "analytics:" <> space_hash
    ])
  end

  defp params(space, generations, now) do
    date = DateTime.to_date(now)

    [
      space,
      generations,
      DateTime.new!(Date.new!(date.year, 1, 1), ~T[00:00:00]),
      DateTime.new!(Date.new!(date.year, date.month, 1), ~T[00:00:00]),
      DateTime.new!(date, ~T[00:00:00]),
      now
    ]
  end

  defp map_overview(rows, space_hash) do
    Enum.reduce(rows, empty(space_hash), fn
      ["total", _, _, year, today, month, wt, wm, wy], data ->
        %{
          data
          | views: %{today: today, month: month, year: year},
            watch_time: %{today: wt, month: wm, year: wy}
        }

      ["month", month, _, views | _], data ->
        %{
          data
          | views_by_month:
              List.replace_at(data.views_by_month, month - 1, %{month: month, views: views})
        }

      ["device", _, dimension, views | _], data ->
        %{data | devices: data.devices ++ [%{device: dimension || "Unknown", views: views}]}

      ["browser", _, dimension, views | _], data ->
        %{data | browsers: data.browsers ++ [%{browser: dimension || "Unknown", views: views}]}
    end)
  end

  defp empty(space) do
    %{
      id: space,
      views: %{today: 0, month: 0, year: 0},
      watch_time: %{today: 0, month: 0, year: 0},
      unique_watch_time: %{today: 0, month: 0, year: 0},
      views_by_month: Enum.map(1..12, &%{month: &1, views: 0}),
      devices: [],
      browsers: []
    }
  end

  defp validate_hash(hash) when is_binary(hash) do
    if Regex.match?(~r/\A[A-Za-z0-9]{5}\z/, hash), do: :ok, else: {:error, :invalid_space_hash}
  end

  defp validate_hash(_), do: {:error, :invalid_space_hash}

  defp validate_optional_hash(nil), do: :ok
  defp validate_optional_hash(hash), do: validate_hash(hash)

  defp ch(sql, params, timeout \\ 15_000) do
    ClickHouseRepo.query(sql, params, timeout: timeout)
  end
end
