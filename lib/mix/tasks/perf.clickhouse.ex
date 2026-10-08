defmodule Mix.Tasks.Perf.Clickhouse do
  use Mix.Task

  alias Mix.Tasks.Perf.{ClickHouseHTTP, ClickHouseSeed, LatencyStats}

  @shortdoc "Stress test ClickHouse-backed API endpoints"

  @moduledoc """
  Stress tests the ClickHouse-backed API endpoints:

    - GET /api/v1/spaces/:space_hash/data
    - GET /api/v1/videos/:embed_id/data

  It can also seed ClickHouse with synthetic data via ClickHouse's HTTP API.

  Examples:

    mix perf.clickhouse --seed-sessions 200000 --truncate
    mix perf.clickhouse --target spaces --requests 2000 --concurrency 50
    mix perf.clickhouse --target videos --embed-id ubg50LeDE9v86ye

  Notes:

    - This task does NOT start the Phoenix server. Run `mix phx.server` (or `docker compose up app`) separately.
    - ClickHouse connection defaults come from CLICKHOUSE_* env vars.
  """

  @impl true
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          base_url: :string,
          target: :string,
          space: :string,
          embed_id: :string,
          requests: :integer,
          concurrency: :integer,
          warmup: :integer,
          seed_sessions: :integer,
          truncate: :boolean,
          db_name: :string,
          log_file: :string,
          tag: :string,
          summary: :boolean,
          limit: :integer,
          best: :boolean,
          repeat: :integer,
          clickhouse_profile: :boolean
        ]
      )

    config = build_run_config(opts)

    maybe_run_summary!(opts, config.log_file)
    maybe_run_best!(opts, config.log_file)
    maybe_run_clickhouse_profile!(opts, config.db_name)
    maybe_prepare_seed_data!(opts, config)

    # Simple sanity ping so failures are obvious.
    _ = ClickHouseHTTP.execute!("SELECT 1")

    validate_repeat_tag!(config.repeat, config.tag)
    benchmark_urls(config)
  end

  defp run_clickhouse_profile!(opts, db_name) do
    config = build_run_config(opts)
    urls = target_urls(config.base_url, config.target, config.space_hash, config.embed_id)

    # Bound query-log results to this profiling run.
    started_at_iso = DateTime.utc_now() |> DateTime.to_iso8601()

    _ = ClickHouseHTTP.execute!("SYSTEM FLUSH LOGS")

    Enum.each(urls, fn url ->
      IO.puts("\n==> Profiling ClickHouse queries for #{url}")
      _ = run_load(url, 1, 1)
    end)

    _ = ClickHouseHTTP.execute!("SYSTEM FLUSH LOGS")

    profile_sql = """
    SELECT
      event_time_microseconds,
      query_duration_ms,
      read_rows,
      read_bytes,
      result_rows,
      memory_usage,
      substring(query, 1, 80) AS tag
    FROM system.query_log
    WHERE type = 'QueryFinish'
      AND current_database = #{string_literal(db_name)}
      AND event_time >= parseDateTimeBestEffort(#{string_literal(started_at_iso)})
      AND position(query, 'mave_perf:') > 0
    ORDER BY event_time_microseconds ASC
    LIMIT 200
    """

    resp = ClickHouseHTTP.execute!(profile_sql <> "\nFORMAT JSONEachRow")
    body = to_string(resp.body || "")

    rows =
      body
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    if rows == [] do
      IO.puts("\n(no ClickHouse query_log rows found for mave_perf tags)")
      IO.puts("If this persists, check ClickHouse query_log settings.")
    else
      IO.puts("\n==> ClickHouse query_log (tagged)\n")

      Enum.each(rows, fn row ->
        IO.puts(
          [
            "tag=",
            Map.get(row, "tag", ""),
            " dur_ms=",
            to_string(Map.get(row, "query_duration_ms", "")),
            " read_rows=",
            to_string(Map.get(row, "read_rows", "")),
            " read_bytes=",
            to_string(Map.get(row, "read_bytes", "")),
            " result_rows=",
            to_string(Map.get(row, "result_rows", "")),
            " mem=",
            to_string(Map.get(row, "memory_usage", "")),
            " event_us=",
            to_string(Map.get(row, "event_time_microseconds", ""))
          ]
          |> IO.iodata_to_binary()
        )
      end)
    end
  end

  defp print_seed_stats!(db_name) do
    resp =
      ClickHouseHTTP.execute!(
        "SELECT count() AS rows, uniqExact(session_id) AS sessions, min(timestamp) AS min_ts, max(timestamp) AS max_ts FROM #{db_name}.events FORMAT TabSeparated"
      )

    case String.trim(to_string(resp.body)) do
      "" ->
        raise "seed verification failed: empty ClickHouse response"

      line ->
        [rows, sessions, min_ts, max_ts] = String.split(line, "\t", parts: 4)

        rows_i = String.to_integer(rows)
        sessions_i = String.to_integer(sessions)

        IO.puts("\n==> Seed verification")
        IO.puts("rows=#{rows_i} sessions=#{sessions_i} min_ts=#{min_ts} max_ts=#{max_ts}")

        if rows_i == 0 or sessions_i == 0 do
          raise "seed verification failed: no rows inserted"
        end
    end
  end

  defp string_literal(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("'", "\\'")

    "'#{escaped}'"
  end

  defp print_repeat_aggregate(url, results) when is_list(results) and results != [] do
    rps = Enum.map(results, fn r -> r.stats.rps end)
    p50 = Enum.map(results, fn r -> r.stats.p50_ms end)
    p95 = Enum.map(results, fn r -> r.stats.p95_ms end)

    IO.puts("\n==> Aggregate for #{url}")

    IO.puts(
      [
        "rps_mean=",
        format_float(mean(rps)),
        " rps_stddev=",
        format_float(stddev(rps)),
        " p50_mean=",
        format_float(mean_int(p50)),
        "ms",
        " p95_mean=",
        format_float(mean_int(p95)),
        "ms\n"
      ]
      |> IO.iodata_to_binary()
    )
  end

  defp mean(values) when is_list(values) and values != [] do
    Enum.sum(values) / length(values)
  end

  defp stddev(values) when is_list(values) and length(values) >= 2 do
    m = mean(values)

    var =
      Enum.reduce(values, 0.0, fn v, acc -> acc + :math.pow(v - m, 2) end) / (length(values) - 1)

    :math.sqrt(var)
  end

  defp stddev(_values), do: 0.0

  defp mean_int(values) when is_list(values) and values != [] do
    values
    |> Enum.map(&to_number/1)
    |> mean()
  end

  defp to_number(v) when is_integer(v), do: v * 1.0
  defp to_number(v) when is_float(v), do: v

  defp to_number(v) when is_binary(v) do
    case Integer.parse(v) do
      {int, _} -> int * 1.0
      _ -> 0.0
    end
  end

  defp append_log!(path, opts) do
    tag = Keyword.get(opts, :tag, "")
    url = Keyword.fetch!(opts, :url)
    seed_sessions = Keyword.get(opts, :seed_sessions)
    requests = Keyword.fetch!(opts, :requests)
    concurrency = Keyword.fetch!(opts, :concurrency)
    warmup = Keyword.fetch!(opts, :warmup)
    wall_ms = Keyword.fetch!(opts, :wall_ms)
    stats = Keyword.fetch!(opts, :stats)

    header =
      "utc\ttag\tgit\turl\tseed_sessions\trequests\tconcurrency\twarmup\twall_ms\tcount\tfailures\trps\tmin_ms\tp50_ms\tp95_ms\tp99_ms\tmax_ms\tmean_ms\n"

    row =
      [
        DateTime.utc_now() |> DateTime.to_iso8601(),
        tag,
        git_sha(),
        url,
        to_string(seed_sessions || ""),
        to_string(requests),
        to_string(concurrency),
        to_string(warmup),
        to_string(wall_ms),
        to_string(stats.count),
        to_string(stats.failures),
        Float.to_string(stats.rps),
        to_string(stats.min_ms),
        to_string(stats.p50_ms),
        to_string(stats.p95_ms),
        to_string(stats.p99_ms),
        to_string(stats.max_ms),
        Float.to_string(stats.mean_ms)
      ]
      |> Enum.join("\t")
      |> Kernel.<>("\n")

    content = if File.exists?(path), do: row, else: header <> row
    File.write!(path, content, [:append])
  end

  defp git_sha do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> ""
    end
  end

  defp print_summary!(path, limit) when is_integer(limit) and limit > 0 do
    rows = read_tsv_rows!(path)

    IO.puts("\n==> Last #{min(limit, length(rows))} runs from #{path}\n")

    rows
    |> Enum.sort_by(& &1.utc, {:desc, DateTime})
    |> Enum.take(limit)
    |> Enum.each(fn row ->
      IO.puts(
        [
          DateTime.to_iso8601(row.utc),
          " ",
          "tag=",
          row.tag,
          " ",
          "url=",
          row.url,
          " ",
          "rps=",
          format_float(row.rps),
          " ",
          "p50=",
          row.p50_ms,
          "ms ",
          "p95=",
          row.p95_ms,
          "ms ",
          "p99=",
          row.p99_ms,
          "ms ",
          "fail=",
          row.failures
        ]
        |> IO.iodata_to_binary()
      )
    end)

    IO.puts("\n==> Best (max rps) per url\n")

    rows
    |> Enum.group_by(& &1.url)
    |> Enum.each(fn {url, url_rows} ->
      best = Enum.max_by(url_rows, & &1.rps, fn -> nil end)

      if best do
        IO.puts(
          [
            url,
            " ",
            "best_rps=",
            format_float(best.rps),
            " tag=",
            best.tag,
            " p50=",
            best.p50_ms,
            "ms",
            " p95=",
            best.p95_ms,
            "ms"
          ]
          |> IO.iodata_to_binary()
        )
      end
    end)
  end

  defp print_best!(path) do
    rows = read_tsv_rows!(path)

    candidates =
      rows
      |> Enum.map(fn row ->
        {kind_from_url(row.url), row}
      end)
      |> Enum.reject(fn {kind, _row} -> kind == :unknown end)
      |> Enum.group_by(fn {_kind, row} -> row.tag end)
      |> Enum.flat_map(fn {tag, tagged} ->
        by_kind = Enum.into(tagged, %{}, fn {kind, row} -> {kind, row} end)

        case {Map.get(by_kind, :spaces), Map.get(by_kind, :videos)} do
          {nil, _} ->
            []

          {_, nil} ->
            []

          {spaces_row, videos_row} ->
            score = min(spaces_row.rps, videos_row.rps)

            [
              %{
                tag: tag,
                score: score,
                spaces: spaces_row,
                videos: videos_row,
                latest_utc: max_datetime(spaces_row.utc, videos_row.utc)
              }
            ]
        end
      end)

    best =
      candidates
      |> Enum.sort_by(fn c -> {c.score, c.latest_utc} end, :desc)
      |> List.first()

    if best do
      IO.puts("\n==> Best tag by combined score (maximize min(rps_spaces, rps_videos))\n")

      IO.puts(
        [
          "tag=",
          best.tag,
          " score=",
          format_float(best.score),
          " (spaces_rps=",
          format_float(best.spaces.rps),
          ", videos_rps=",
          format_float(best.videos.rps),
          ")\n",
          "spaces: p50=",
          best.spaces.p50_ms,
          "ms p95=",
          best.spaces.p95_ms,
          "ms\n",
          "videos: p50=",
          best.videos.p50_ms,
          "ms p95=",
          best.videos.p95_ms,
          "ms\n"
        ]
        |> IO.iodata_to_binary()
      )
    else
      IO.puts(
        "\n==> No combined candidates found. Ensure your TSV has rows for BOTH endpoints using the same tag (run with --target both).\n"
      )
    end
  end

  defp kind_from_url(url) when is_binary(url) do
    cond do
      String.contains?(url, "/api/v1/spaces/") -> :spaces
      String.contains?(url, "/api/v1/videos/") -> :videos
      true -> :unknown
    end
  end

  defp max_datetime(a, b) do
    case DateTime.compare(a, b) do
      :gt -> a
      :eq -> a
      :lt -> b
    end
  end

  defp read_tsv_rows!(path) do
    contents = File.read!(path)
    lines = String.split(contents, "\n", trim: true)

    case lines do
      [] ->
        []

      [_header | data_lines] ->
        Enum.flat_map(data_lines, &parse_tsv_row/1)
    end
  end

  defp build_run_config(opts) do
    %{
      base_url:
        Keyword.get(opts, :base_url, "http://localhost:4000") |> String.trim_trailing("/"),
      target: Keyword.get(opts, :target, "both"),
      space_hash: Keyword.get(opts, :space, "ubg50"),
      embed_id: Keyword.get(opts, :embed_id, "ubg50LeDE9v86ye"),
      requests: Keyword.get(opts, :requests, 1000),
      concurrency: Keyword.get(opts, :concurrency, 50),
      warmup: Keyword.get(opts, :warmup, 50),
      log_file: Keyword.get(opts, :log_file),
      tag: Keyword.get(opts, :tag, ""),
      repeat: normalized_repeat(Keyword.get(opts, :repeat, 1)),
      db_name:
        Keyword.get(opts, :db_name, System.get_env("CLICKHOUSE_DATABASE") || "mave_metrics"),
      seed_sessions: Keyword.get(opts, :seed_sessions)
    }
  end

  defp normalized_repeat(repeat) when is_integer(repeat) and repeat > 0, do: repeat
  defp normalized_repeat(_repeat), do: 1

  defp maybe_run_summary!(opts, log_file) do
    if Keyword.get(opts, :summary, false) do
      path = require_log_file!(log_file, "--summary requires --log-file <path>")
      print_summary!(path, Keyword.get(opts, :limit, 20))
      System.halt(0)
    end
  end

  defp maybe_run_best!(opts, log_file) do
    if Keyword.get(opts, :best, false) do
      path = require_log_file!(log_file, "--best requires --log-file <path>")
      print_best!(path)
      System.halt(0)
    end
  end

  defp maybe_run_clickhouse_profile!(opts, db_name) do
    if Keyword.get(opts, :clickhouse_profile, false) do
      run_clickhouse_profile!(opts, db_name)
      System.halt(0)
    end
  end

  defp require_log_file!(path, _message) when is_binary(path) and path != "", do: path
  defp require_log_file!(_path, message), do: raise(message)

  defp maybe_prepare_seed_data!(opts, config) do
    if Keyword.get(opts, :truncate, false) do
      ClickHouseSeed.truncate_events!(config.db_name)
    end

    maybe_seed_sessions!(config)
  end

  defp maybe_seed_sessions!(%{seed_sessions: seed_sessions} = config)
       when is_integer(seed_sessions) and seed_sessions > 0 do
    embed_hash = embed_hash_from_embed_id!(config.embed_id)

    ClickHouseSeed.seed_sessions!(
      db_name: config.db_name,
      sessions: seed_sessions,
      space_hash: config.space_hash,
      embed_hash: embed_hash
    )

    print_seed_stats!(config.db_name)
  end

  defp maybe_seed_sessions!(_config), do: :ok

  defp validate_repeat_tag!(repeat, tag) do
    if repeat > 1 and (tag == "" or not is_binary(tag)) do
      raise "--repeat requires --tag so runs can be distinguished in the log"
    end
  end

  defp benchmark_urls(config) do
    config.base_url
    |> target_urls(config.target, config.space_hash, config.embed_id)
    |> Enum.each(&benchmark_url(&1, config))
  end

  defp benchmark_url(url, config) do
    results =
      Enum.map(1..config.repeat, fn index ->
        benchmark_iteration(url, index, config)
      end)

    if config.repeat > 1 do
      print_repeat_aggregate(url, results)
    end
  end

  defp benchmark_iteration(url, index, config) do
    run_tag = iteration_tag(config.tag, config.repeat, index)

    IO.puts("\n==> Benchmarking #{url} (#{index}/#{config.repeat})")
    maybe_run_warmup(url, config.warmup, config.concurrency)

    {wall_ms, {latencies_ms, failures}} =
      :timer.tc(fn -> run_load(url, config.requests, config.concurrency) end)
      |> then(fn {us, result} -> {div(us, 1000), result} end)

    stats = LatencyStats.summarize(latencies_ms, wall_ms, failures)
    IO.puts(LatencyStats.format(stats))
    maybe_append_log(config, run_tag, url, wall_ms, stats)

    %{tag: run_tag, url: url, stats: stats}
  end

  defp iteration_tag(tag, 1, _index), do: tag
  defp iteration_tag(tag, _repeat, index), do: "#{tag}-r#{index}"

  defp maybe_run_warmup(url, warmup, concurrency) when warmup > 0 do
    _ = run_load(url, warmup, min(concurrency, warmup))
  end

  defp maybe_run_warmup(_url, _warmup, _concurrency), do: :ok

  defp maybe_append_log(%{log_file: path} = config, run_tag, url, wall_ms, stats)
       when is_binary(path) and path != "" do
    append_log!(path,
      tag: run_tag,
      url: url,
      seed_sessions: config.seed_sessions,
      requests: config.requests,
      concurrency: config.concurrency,
      warmup: config.warmup,
      wall_ms: wall_ms,
      stats: stats
    )
  end

  defp maybe_append_log(_config, _run_tag, _url, _wall_ms, _stats), do: :ok

  defp target_urls(base_url, "spaces", space_hash, _embed_id),
    do: [spaces_url(base_url, space_hash)]

  defp target_urls(base_url, "videos", _space_hash, embed_id),
    do: [videos_url(base_url, embed_id)]

  defp target_urls(base_url, _target, space_hash, embed_id) do
    [spaces_url(base_url, space_hash), videos_url(base_url, embed_id)]
  end

  defp parse_tsv_row(line) do
    case String.split(line, "\t") do
      [
        utc,
        tag,
        _git,
        url,
        _seed_sessions,
        _requests,
        _concurrency,
        _warmup,
        _wall_ms,
        _count,
        failures,
        rps,
        _min_ms,
        p50_ms,
        p95_ms,
        p99_ms,
        _max_ms,
        _mean_ms
      ] ->
        build_tsv_row(utc, tag, url, failures, rps, p50_ms, p95_ms, p99_ms)

      _ ->
        []
    end
  end

  defp build_tsv_row(utc, tag, url, failures, rps, p50_ms, p95_ms, p99_ms) do
    case DateTime.from_iso8601(utc) do
      {:ok, dt, _offset} ->
        [
          %{
            utc: dt,
            tag: tag,
            url: url,
            failures: failures,
            rps: parse_float(rps),
            p50_ms: p50_ms,
            p95_ms: p95_ms,
            p99_ms: p99_ms
          }
        ]

      _ ->
        []
    end
  end

  defp parse_float(nil), do: 0.0

  defp parse_float(str) when is_binary(str) do
    case Float.parse(str) do
      {val, _} -> val
      _ -> 0.0
    end
  end

  defp format_float(float) when is_float(float), do: :erlang.float_to_binary(float, decimals: 2)

  defp run_load(url, requests, concurrency) do
    stream =
      Task.async_stream(
        1..requests,
        fn _ ->
          started = System.monotonic_time()

          res =
            Req.get!(url,
              receive_timeout: 60_000,
              retry: false
            )

          elapsed_ms =
            System.monotonic_time()
            |> Kernel.-(started)
            |> System.convert_time_unit(:native, :millisecond)

          if res.status in 200..299 do
            {:ok, elapsed_ms}
          else
            {:error, elapsed_ms}
          end
        end,
        max_concurrency: concurrency,
        timeout: :infinity,
        ordered: false
      )

    Enum.reduce(stream, {[], 0}, fn
      {:ok, {:ok, ms}}, {acc, failures} -> {[ms | acc], failures}
      {:ok, {:error, _ms}}, {acc, failures} -> {acc, failures + 1}
      {:exit, _reason}, {acc, failures} -> {acc, failures + 1}
    end)
    |> then(fn {latencies, failures} -> {Enum.reverse(latencies), failures} end)
  end

  defp spaces_url(base_url, space_hash), do: "#{base_url}/api/v1/spaces/#{space_hash}/data"

  defp videos_url(base_url, embed_id), do: "#{base_url}/api/v1/videos/#{embed_id}/data"

  defp embed_hash_from_embed_id!(embed_id) do
    embed_id = String.trim(embed_id)

    case embed_id do
      <<_space_hash::binary-size(5), embed_hash::binary-size(10)>> -> embed_hash
      _ -> raise "embed_id must be 15 chars (5+10): got #{inspect(embed_id)}"
    end
  end
end
