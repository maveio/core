defmodule MaveCore.DeliveryStandby do
  @moduledoc """
  Keeps a copy of public media at an independent storage provider, so an
  operator can move delivery there when the primary provider is unavailable or
  compromised.

  `sync/1` copies the public media of every space into same-named buckets at the
  standby and removes what is no longer public. `check/1` reports whether that
  copy is complete and recent, and whether the standby answers the public media
  URLs with the access rules of the primary.

  Neither function moves traffic. The switch itself is a DNS change, described
  with its limits in `docs/emergency_delivery_failover.md`.

  Configure `:mave_core, :delivery_standby` with:

    * `:storage` - S3 settings of the standby (`:endpoint`, `:access_key_id`,
      `:secret_access_key`, `:region`, `:bucket_prefix`, `:object_acl`)
    * `:edge_url` - where the standby answers before DNS points at it
    * `:status_bucket` - bucket that holds the report of the last sync
    * `:max_age_seconds` - oldest sync that still counts as ready
  """

  import Ecto.Query

  require Logger

  alias MaveCore.DeliveryStandby.{Plan, Probe}
  alias MaveCore.Embeds.Embed
  alias MaveCore.Media.Storage
  alias MaveCore.Repo
  alias MaveCore.Spaces.Space
  alias MaveCore.StorageProfiles

  @status_key "status.json"
  @default_status_bucket "mave-delivery-standby"
  @default_max_age_seconds 24 * 60 * 60
  @default_min_coverage 0.99
  @default_concurrency 8
  # A wiped or tampered primary must not empty the standby through a sync.
  @orphan_hold_ratio 0.25
  @orphan_hold_minimum 20
  @failure_sample 5

  @type finding :: %{
          severity: :critical | :warning,
          code: atom(),
          space: String.t() | nil,
          detail: String.t()
        }

  @doc "Returns whether a standby storage provider is configured."
  @spec configured?() :: boolean()
  def configured?, do: match?({:ok, _storage}, storage())

  @doc "Returns the configured standby storage profile."
  @spec storage() :: {:ok, map()} | {:error, :delivery_standby_not_configured}
  def storage do
    case config()[:storage] do
      %{endpoint: endpoint, access_key_id: key, secret_access_key: secret} = storage
      when is_binary(endpoint) and endpoint != "" and is_binary(key) and is_binary(secret) ->
        {:ok, storage}

      _missing ->
        {:error, :delivery_standby_not_configured}
    end
  end

  @doc """
  Brings the standby in line with the public media of the primary.

  Options:

    * `:space` - limit the run to one space hash
    * `:dry_run` - report the plan without changing the standby
    * `:force_deletes` - also delete when most of a space vanished from the primary
    * `:concurrency` - parallel object copies per space

  Objects that stopped being public are always removed. Objects that merely
  disappeared from the primary are kept when they are a large share of the
  space, until an operator confirms with `:force_deletes`.
  """
  @spec sync(keyword()) :: {:ok, map()} | {:error, :delivery_standby_not_configured}
  def sync(opts \\ []) do
    with {:ok, standby} <- storage() do
      started_at = DateTime.utc_now()
      spaces = opts |> list_spaces() |> Enum.map(&sync_space(&1, standby, opts))

      report = %{
        version: 1,
        dry_run: Keyword.get(opts, :dry_run, false),
        partial: is_binary(opts[:space]),
        started_at: started_at,
        finished_at: DateTime.utc_now(),
        spaces: spaces,
        totals: totals(spaces)
      }

      {:ok, maybe_write_status(report, standby)}
    end
  end

  @doc """
  Reports whether delivery could be switched to the standby now.

  Options:

    * `:space` - limit the check to one space hash
    * `:max_age_seconds` - oldest sync that still counts as ready
    * `:min_coverage` - share of public objects that must be current (default 0.99)
    * `:probe_embeds` - public embeds per space requested through the standby edge

  The result is ready when it holds no critical finding.
  """
  @spec check(keyword()) :: {:ok, map()} | {:error, :delivery_standby_not_configured}
  def check(opts \\ []) do
    with {:ok, standby} <- storage() do
      spaces = opts |> list_spaces() |> Enum.map(&check_space(&1, standby, opts))
      status = read_status(standby)

      findings =
        status_findings(status, opts) ++
          edge_findings() ++ Enum.flat_map(spaces, & &1.findings)

      {:ok,
       %{
         ready?: not Enum.any?(findings, &(&1.severity == :critical)),
         checked_at: DateTime.utc_now(),
         last_sync: status,
         edge_url: edge_url(),
         spaces: Enum.map(spaces, &Map.delete(&1, :findings)),
         totals: totals(spaces),
         findings: findings
       }}
    end
  end

  @doc "Returns the report stored by the last complete sync, if any."
  @spec last_sync() :: {:ok, map()} | {:error, term()}
  def last_sync do
    with {:ok, standby} <- storage(), do: read_status(standby)
  end

  @doc "Returns the standby bucket that mirrors a space's bucket."
  @spec bucket_for_space(String.t(), map()) :: String.t()
  def bucket_for_space(space_hash, standby), do: Storage.bucket_for_space(space_hash, standby)

  defp sync_space(%Space{} = space, standby, opts) do
    base = space_result(space)

    with {:ok, context} <- space_context(space, standby),
         :ok <- ensure_standby_bucket(context, opts),
         {:ok, base} <- apply_access(base, space, context, opts),
         {:ok, context} <- plan(context) do
      apply_plan(base, context, opts)
    else
      {:error, reason} -> %{base | error: describe(reason)}
    end
  end

  defp check_space(%Space{} = space, standby, opts) do
    base = Map.put(space_result(space), :findings, [])

    with {:ok, context} <- space_context(space, standby),
         {:ok, context} <- plan(context) do
      result = planned(base, context.plan)
      {passed, probe_findings} = Probe.run(space, context, edge_url(), opts)
      findings = coverage_findings(result, opts) ++ leak_findings(result) ++ probe_findings

      %{result | probes_passed: passed, findings: findings}
    else
      {:error, reason} ->
        %{
          base
          | error: describe(reason),
            findings: [finding(:critical, :space_check_failed, space.hash, describe(reason))]
        }
    end
  end

  defp space_context(%Space{} = space, standby) do
    profile = StorageProfiles.for_space(space)

    embeds =
      Repo.all(
        from(e in Embed,
          where: e.space_id == ^space.id and is_nil(e.deleted_at),
          select: %{
            hash: e.hash,
            public: e.playback_visibility == :public and e.playback_status == :public
          }
        )
      )

    {public, private} = Enum.split_with(embeds, & &1.public)

    {:ok,
     %{
       space: space,
       primary_profile: profile,
       primary_bucket: Storage.bucket_for_space(space.hash, profile),
       standby: standby,
       standby_bucket: bucket_for_space(space.hash, standby),
       public_hashes: MapSet.new(public, & &1.hash),
       private_hashes: Enum.map(private, & &1.hash)
     }}
  end

  defp plan(context) do
    with {:ok, primary} <-
           list(:primary_listing_failed, context.primary_bucket, context.primary_profile),
         {:ok, standby} <-
           list(:standby_listing_failed, context.standby_bucket, context.standby) do
      {:ok, Map.put(context, :plan, Plan.build(primary, standby, context.public_hashes))}
    end
  end

  defp list(failure, bucket, profile) do
    case Storage.list_objects(bucket, "", profile) do
      {:ok, objects} -> {:ok, objects}
      {:error, reason} -> {:error, {failure, reason}}
    end
  end

  defp ensure_standby_bucket(context, opts) do
    if opts[:dry_run] do
      :ok
    else
      case Storage.ensure_bucket(context.standby_bucket, context.standby) do
        :ok -> :ok
        {:error, reason} -> {:error, {:standby_bucket_failed, reason}}
      end
    end
  end

  # The standby enforces the same read rules through its own bucket policy. A
  # hotlink-protected space is not copied to a standby that cannot apply them.
  defp apply_access(base, space, context, opts) do
    result =
      if opts[:dry_run],
        do: :ok,
        else: Storage.put_space_access(space, context.standby_bucket, context.standby)

    case {result, space.hotlink_protection_enabled == true} do
      {:ok, _protected} ->
        {:ok, base}

      {{:error, reason}, true} ->
        {:error, {:hotlink_protection_not_applied, reason}}

      {{:error, reason}, false} ->
        {:ok, %{base | warnings: ["access policy not applied: #{describe(reason)}"]}}
    end
  end

  defp apply_plan(base, %{plan: plan} = context, opts) do
    result = planned(base, plan)

    if opts[:dry_run] do
      result
    else
      # Revoke first: a failed copy must never delay removing protected media.
      {held, orphaned} = held_orphans(plan, opts)
      revoked = delete(plan.revoke, context)
      copied = copy(plan.copy, context, opts)
      removed = delete(orphaned, context)
      failures = revoked.failed ++ copied.failed ++ removed.failed

      %{
        result
        | copied: copied.done,
          copied_bytes: copied.bytes,
          revoked: revoked.done,
          orphans_deleted: removed.done,
          orphans_held: length(held),
          failed: length(failures),
          failures: Enum.take(failures, @failure_sample),
          warnings: result.warnings ++ held_warning(held)
      }
    end
  end

  defp held_orphans(%Plan{orphaned: orphaned} = plan, opts) do
    standby_public = plan.in_sync + length(orphaned) + stale_count(plan)
    count = length(orphaned)

    hold? =
      not Keyword.get(opts, :force_deletes, false) and count > @orphan_hold_minimum and
        count > standby_public * @orphan_hold_ratio

    if hold?, do: {orphaned, []}, else: {[], orphaned}
  end

  defp held_warning([]), do: []

  defp held_warning(held),
    do: [
      "kept #{length(held)} objects that vanished from the primary; confirm with force_deletes"
    ]

  defp copy(entries, context, opts) do
    entries
    |> Task.async_stream(
      fn {_reason, object} -> {object, copy_object(object, context)} end,
      max_concurrency: concurrency(opts),
      ordered: false,
      timeout: :infinity
    )
    |> collect()
  end

  defp copy_object(object, context) do
    Storage.copy_public_between_profiles(
      context.standby_bucket,
      object.key,
      context.standby,
      context.primary_bucket,
      object.key,
      context.primary_profile
    )
  end

  defp delete(objects, context) do
    objects
    |> Task.async_stream(
      fn object ->
        {object, Storage.delete_object(context.standby_bucket, object.key, context.standby)}
      end,
      max_concurrency: @default_concurrency,
      ordered: false,
      timeout: :infinity
    )
    |> collect()
  end

  defp collect(stream) do
    Enum.reduce(stream, %{done: 0, bytes: 0, failed: []}, fn
      {:ok, {object, :ok}}, acc ->
        %{acc | done: acc.done + 1, bytes: acc.bytes + object.size_bytes}

      {:ok, {object, {:ok, _result}}}, acc ->
        %{acc | done: acc.done + 1, bytes: acc.bytes + object.size_bytes}

      {:ok, {object, {:error, reason}}}, acc ->
        %{acc | failed: [%{key: object.key, reason: describe(reason)} | acc.failed]}

      {:exit, reason}, acc ->
        %{acc | failed: [%{key: nil, reason: describe(reason)} | acc.failed]}
    end)
  end

  defp planned(base, %Plan{} = plan) do
    missing = Enum.count(plan.copy, &match?({:missing, _object}, &1))
    pending_bytes = plan.copy |> Enum.map(fn {_reason, object} -> object.size_bytes end)

    %{
      base
      | objects: plan.in_sync + length(plan.copy),
        bytes: plan.in_sync_bytes + Enum.sum(pending_bytes),
        current: plan.in_sync,
        missing: missing,
        stale: length(plan.copy) - missing,
        not_public: length(plan.revoke),
        orphaned: length(plan.orphaned)
    }
  end

  defp stale_count(%Plan{copy: copy}), do: Enum.count(copy, &match?({:stale, _object}, &1))

  defp space_result(%Space{} = space) do
    %{
      space: space.hash,
      hotlink_protection: space.hotlink_protection_enabled == true,
      objects: 0,
      bytes: 0,
      current: 0,
      missing: 0,
      stale: 0,
      not_public: 0,
      orphaned: 0,
      copied: 0,
      copied_bytes: 0,
      revoked: 0,
      orphans_deleted: 0,
      orphans_held: 0,
      failed: 0,
      failures: [],
      probes_passed: 0,
      warnings: [],
      error: nil
    }
  end

  defp coverage_findings(%{objects: 0}, _opts), do: []

  defp coverage_findings(result, opts) do
    behind = result.missing + result.stale
    coverage = result.current / result.objects
    minimum = Keyword.get(opts, :min_coverage, @default_min_coverage)

    cond do
      behind == 0 ->
        []

      coverage < minimum ->
        [
          finding(
            :critical,
            :copy_incomplete,
            result.space,
            "#{behind} of #{result.objects} public objects are missing or outdated on the standby"
          )
        ]

      true ->
        [
          finding(
            :warning,
            :copy_behind,
            result.space,
            "#{behind} of #{result.objects} public objects are waiting for the next sync"
          )
        ]
    end
  end

  defp leak_findings(%{not_public: 0}), do: []

  defp leak_findings(result) do
    [
      finding(
        :critical,
        :not_public_on_standby,
        result.space,
        "#{result.not_public} objects on the standby are not public; run a sync before switching"
      )
    ]
  end

  defp status_findings({:ok, %{"finished_at" => finished_at}}, opts) do
    max_age =
      Keyword.get(opts, :max_age_seconds) || config()[:max_age_seconds] ||
        @default_max_age_seconds

    with {:ok, time, _offset} <- DateTime.from_iso8601(finished_at),
         age when age <= max_age <- DateTime.diff(DateTime.utc_now(), time) do
      []
    else
      age when is_integer(age) ->
        [
          finding(
            :critical,
            :sync_too_old,
            nil,
            "the last complete sync finished #{age} seconds ago; the limit is #{max_age}"
          )
        ]

      _invalid ->
        [finding(:critical, :sync_status_unreadable, nil, "the sync status has no usable time")]
    end
  end

  defp status_findings(_missing, _opts) do
    [finding(:critical, :never_synced, nil, "no complete sync has been recorded on the standby")]
  end

  defp edge_findings do
    case edge_url() do
      nil ->
        [
          finding(
            :warning,
            :edge_not_configured,
            nil,
            "no standby edge is configured, so the public URLs were not tested"
          )
        ]

      _url ->
        []
    end
  end

  # Only a complete, real run describes the state of the whole standby.
  defp maybe_write_status(%{dry_run: false, partial: false} = report, standby) do
    bucket = status_bucket()

    body =
      Jason.encode!(%{
        version: report.version,
        started_at: report.started_at,
        finished_at: report.finished_at,
        totals: report.totals,
        spaces_with_errors: Enum.count(report.spaces, &is_binary(&1.error))
      })

    with :ok <- Storage.ensure_bucket(bucket, standby),
         {:ok, _response} <- Storage.put(bucket, @status_key, body, "application/json", standby) do
      Map.put(report, :status_written, true)
    else
      error ->
        Logger.warning("Delivery standby status was not stored: #{describe(error)}")
        Map.put(report, :status_written, false)
    end
  end

  defp maybe_write_status(report, _standby), do: Map.put(report, :status_written, false)

  defp read_status(standby) do
    with {:ok, body} <- Storage.get(status_bucket(), @status_key, standby),
         {:ok, %{} = status} <- decode(body) do
      {:ok, status}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_status}
    end
  end

  defp decode(%{} = body), do: {:ok, body}
  defp decode(body) when is_binary(body), do: Jason.decode(body)
  defp decode(_body), do: {:error, :invalid_status}

  defp totals(spaces) do
    keys =
      ~w(objects bytes current missing stale not_public orphaned copied copied_bytes revoked
         orphans_deleted orphans_held failed probes_passed)a

    spaces
    |> Enum.reduce(Map.new(keys, &{&1, 0}), fn space, acc ->
      Map.new(acc, fn {key, value} -> {key, value + Map.get(space, key, 0)} end)
    end)
    |> Map.put(:spaces, length(spaces))
  end

  defp list_spaces(opts) do
    query = from(s in Space, where: is_nil(s.deleted_at), order_by: s.hash, preload: [:domains])

    query =
      case opts[:space] do
        hash when is_binary(hash) -> where(query, [s], s.hash == ^hash)
        _all -> query
      end

    Repo.all(query)
  end

  defp finding(severity, code, space, detail),
    do: %{severity: severity, code: code, space: space, detail: detail}

  defp concurrency(opts) do
    case Keyword.get(opts, :concurrency) do
      value when is_integer(value) and value > 0 -> value
      _default -> @default_concurrency
    end
  end

  defp edge_url do
    case config()[:edge_url] do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _missing -> nil
    end
  end

  defp status_bucket do
    case config()[:status_bucket] do
      bucket when is_binary(bucket) and bucket != "" -> bucket
      _default -> @default_status_bucket
    end
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  defp config, do: Application.get_env(:mave_core, :delivery_standby, [])
end
