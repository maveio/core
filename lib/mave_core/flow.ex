defmodule MaveCore.Flow do
  @moduledoc """
  Flow engine context for template/version/run lifecycle and step execution.
  """
  import Ecto.Query
  require Logger

  alias Ecto.Adapters.SQL
  alias MaveCore.Assets
  alias MaveCore.Assets.{Asset, AudioTrack, Rendition, Subtitle, Video}
  alias MaveCore.Embeds
  alias MaveCore.Embeds.{Embed, ManifestPublisher, PlayerPublisher}
  alias MaveCore.Embeds.Events, as: EmbedEvents
  alias MaveCore.EncodingBooster
  alias MaveCore.GpuEncodingBooster

  alias MaveCore.Flow.{
    ArtifactRef,
    Definition,
    Events,
    ExecutionMetadata,
    FairQueue,
    ProgressReporter,
    RetryPolicy,
    Run,
    StepRegistry,
    StepRun,
    Template,
    Version
  }

  alias MaveCore.Flow.Presets
  alias MaveCore.Flow.Steps.MediaTranscodeWaveformStep
  alias MaveCore.Flow.Steps.Support, as: StepSupport
  alias MaveCore.LegacyShortUUID
  alias MaveCore.Media.Storage
  alias MaveCore.Repo
  alias MaveCore.Spaces
  alias MaveCore.Spaces.Space
  alias MaveCore.Uploads.Events, as: UploadEvents
  alias MaveCore.Workers.{FlowCoordinatorWorker, FlowStepWorker}
  alias Oban.Job

  @active_oban_step_job_states ~w(available scheduled retryable executing)
  @demanding_oban_step_job_states ~w(available executing)
  @default_max_execution_attempts 3
  @default_resumable_chunk_max_execution_attempts 8
  @default_booster_gateway_max_execution_attempts 5
  @default_booster_gateway_backoff_seconds [10, 30, 60, 120]
  @default_max_orphan_recoveries 1
  @import_finalizer_step_types ~w(
    media.build_hls_master
    manifest.build
    cdn.purge
    event.notify_webhook
  )
  @source_preparation_step_types ~w(
    source.resolve
    storage.ensure_space_bucket
    asset.upload_original
  )

  @terminal_statuses ~w(succeeded failed cancelled skipped)
  @terminal_run_statuses ~w(succeeded failed cancelled)
  @failed_run_executing_step_error "interrupted because flow run failed"
  @failed_run_pending_step_error "not executed because flow run failed"
  @default_flame_pool MaveCore.Workers.FlameRunner
  @media_step_types ~w(
    media.extract_frame
    media.generate_audio_peaks
    media.generate_segments
    media.generate_storyboard
    media.package_hls_audio
    media.package_hls_variant
    media.transcode_audio
    media.transcode_h264_ladder
    media.transcode_video
  )
  @media_flame_pool_step_types MapSet.new(@media_step_types ++ ["asset.upload_original"])
  @flame_timeout_keys %{
    "media.extract_frame" => :media_extract_frame,
    "media.generate_audio_peaks" => :media_generate_audio_peaks,
    "media.generate_segments" => :media_generate_segments,
    "media.generate_storyboard" => :media_generate_storyboard,
    "media.package_hls_audio" => :media_package_hls_audio,
    "media.package_hls_variant" => :media_package_hls_variant,
    "media.transcode_audio" => :media_transcode_audio,
    "media.transcode_h264_ladder" => :media_transcode_h264_ladder,
    "media.transcode_video" => :media_transcode_video
  }
  @ambient_dependency_output_step_ids ~w(source upload_original inspect_media audio_peaks)
  @ready_video_statuses ~w(ready playable)
  @db_rendition_types ~w(
    audio
    video
    poster
    thumbnail
    placeholder
    storyboard
    segments
    clip_keyframes
    clip
    custom_thumbnail
  )
  @db_rendition_codecs ~w(webp webm jpg h264 hevc av1 mp3 aac)
  @db_rendition_containers ~w(webp webm jpg mp4 avif hls mp3)
  @db_rendition_sizes ~w(sd hd fhd qhd uhd)

  def list_step_types do
    StepRegistry.all()
  end

  def list_presets do
    Presets.all()
  end

  def list_templates do
    preset_map =
      Presets.all()
      |> Map.new(fn preset ->
        {preset["slug"],
         %{
           slug: preset["slug"],
           name: preset["name"],
           description: preset["description"],
           builtin: true,
           installed: false
         }}
      end)

    installed_templates =
      Template
      |> order_by([template], asc: template.name, asc: template.slug)
      |> Repo.all()
      |> Enum.map(fn template ->
        base = Map.get(preset_map, template.slug, %{})

        Map.merge(base, %{
          slug: template.slug,
          name: template.name,
          description: template.description,
          builtin: Map.get(base, :builtin, false),
          installed: true
        })
      end)

    installed_by_slug = Map.new(installed_templates, &{&1.slug, &1})

    (installed_templates ++
       Enum.reject(Map.values(preset_map), &Map.has_key?(installed_by_slug, &1.slug)))
    |> Enum.sort_by(fn template ->
      {if(template.builtin, do: 0, else: 1), String.downcase(template.name || template.slug)}
    end)
  end

  def install_preset(preset_slug) when is_binary(preset_slug) do
    with {:ok, preset} <- Presets.fetch(preset_slug) do
      Repo.transaction(fn ->
        template = upsert_preset_template(preset)
        checksum = checksum_for_definition(preset["definition"])
        existing_version = find_matching_version(template.id, checksum)
        version = install_preset_version(template, preset, existing_version)

        %{
          template: template,
          version: version,
          version_created: is_nil(existing_version)
        }
      end)
      |> unwrap_transaction()
    end
  end

  def get_run(run_id) when is_binary(run_id) do
    Run
    |> where([run], run.id == ^run_id)
    |> preload([:flow_template, :flow_version, :step_runs, :artifact_refs])
    |> Repo.one()
  end

  def get_run!(run_id) when is_binary(run_id) do
    Run
    |> Repo.get!(run_id)
    |> Repo.preload([:flow_template, :flow_version, :step_runs, :artifact_refs])
  end

  def create_template(attrs) when is_map(attrs) do
    %Template{}
    |> Template.changeset(attrs)
    |> Repo.insert()
  end

  def create_version(template_selector, attrs) when is_map(attrs) do
    with {:ok, template} <- fetch_template(template_selector) do
      version_number =
        Map.get(attrs, "version") ||
          Map.get(attrs, :version) ||
          next_version_number(template.id)

      definition = Map.get(attrs, "definition") || Map.get(attrs, :definition)
      status = Map.get(attrs, "status") || Map.get(attrs, :status) || "active"

      checksum =
        case definition do
          map when is_map(map) ->
            map
            |> Jason.encode!()
            |> then(&:crypto.hash(:sha256, &1))
            |> Base.encode16(case: :lower)

          _ ->
            nil
        end

      %Version{}
      |> Version.changeset(%{
        flow_template_id: template.id,
        version: version_number,
        status: status,
        definition: definition,
        checksum: checksum
      })
      |> Repo.insert()
    end
  end

  def start_run(template_selector, input \\ %{}, opts \\ []) when is_map(input) do
    enqueue? = Keyword.get(opts, :enqueue, true)
    input = persist_run_video_id(input)

    with :ok <- maybe_sync_builtin_preset(template_selector),
         {:ok, template} <- fetch_template(template_selector),
         {:ok, version} <- fetch_version(template.id, opts) do
      Repo.transaction(fn -> create_started_run(template, version, input, enqueue?) end)
      |> unwrap_transaction()
      |> case do
        {:ok, run} ->
          Events.broadcast_updated(run.id, %{"status" => run.status})
          maybe_broadcast_processing_started(run.input)
          {:ok, get_run!(run.id)}

        other ->
          other
      end
    end
  end

  def run_inline(template_selector, input \\ %{}, opts \\ []) when is_map(input) do
    max_cycles = Keyword.get(opts, :max_cycles, 200)
    opts = opts |> Keyword.delete(:max_cycles) |> Keyword.put(:enqueue, false)

    with {:ok, run} <- start_run(template_selector, input, opts) do
      run_inline_loop(run.id, max_cycles)
    end
  end

  def cancel_runs_for_embed(space_hash, embed_hash)
      when is_binary(space_hash) and is_binary(embed_hash) do
    Repo.transaction(fn ->
      runs =
        Run
        |> where([run], run.status in ["queued", "running"])
        |> where(
          [run],
          fragment("?->>'space_hash' = ?", run.input, ^space_hash) and
            fragment("?->>'embed_hash' = ?", run.input, ^embed_hash)
        )
        |> preload(:step_runs)
        |> Repo.all()

      Enum.each(runs, &cancel_run/1)

      length(runs)
    end)
    |> unwrap_transaction()
  end

  def retry_step(flow_run_id, step_id, opts \\ [])
      when is_binary(flow_run_id) and is_binary(step_id) do
    enqueue_jobs? = Keyword.get(opts, :enqueue_jobs, true)

    with {:ok, run} <- reset_step_subtree(flow_run_id, step_id) do
      reconcile_run(run.id, enqueue_jobs: enqueue_jobs?)
    end
  end

  def recover_run(flow_run_id, opts \\ []) when is_binary(flow_run_id) do
    enqueue_jobs? = Keyword.get(opts, :enqueue_jobs, true)

    with {:ok, run} <- reset_recoverable_subtrees(flow_run_id) do
      reconcile_run(run.id, enqueue_jobs: enqueue_jobs?)
    end
  end

  def recover_stale_executing_steps(opts \\ []) when is_list(opts) do
    cutoff = stale_step_cutoff(opts)
    limit = stale_step_recovery_limit(opts)

    result =
      cutoff
      |> stale_executing_step_candidates(limit)
      |> Enum.reduce(%{recovered: 0, exhausted: 0}, fn candidate, counts ->
        case recover_stale_executing_step(candidate, opts) do
          :recovered -> Map.update!(counts, :recovered, &(&1 + 1))
          :exhausted -> Map.update!(counts, :exhausted, &(&1 + 1))
          :skipped -> counts
        end
      end)

    {:ok, result}
  end

  def recover_stale_nonexecuting_runs(opts \\ []) when is_list(opts) do
    cutoff = stale_step_cutoff(opts)
    limit = stale_step_recovery_limit(opts)

    result =
      cutoff
      |> stale_nonexecuting_run_candidates(limit)
      |> Enum.reduce_while(%{reconciled: 0, skipped: 0, errors: 0}, fn flow_run_id, counts ->
        if counts.reconciled >= limit do
          {:halt, counts}
        else
          {:cont, reconcile_stale_nonexecuting_run(flow_run_id, counts)}
        end
      end)

    {:ok, result}
  end

  def reconcile_run(flow_run_id, opts \\ []) when is_binary(flow_run_id) do
    enqueue_jobs? = Keyword.get(opts, :enqueue_jobs, true)

    with :ok <- maybe_repair_scheduled_step_jobs(flow_run_id, enqueue_jobs?) do
      Repo.transaction(fn ->
        flow_run_id
        |> load_run_for_reconcile()
        |> reconcile_loaded_run(enqueue_jobs?)
      end)
      |> unwrap_transaction()
      |> maybe_cancel_terminal_step_jobs()
      |> maybe_broadcast_flow_run()
      |> maybe_broadcast_reconciled_run()
    end
  end

  def execute_step(flow_run_id, step_id, opts \\ [])
      when is_binary(flow_run_id) and is_binary(step_id) do
    enqueue_coordinator? = Keyword.get(opts, :enqueue_coordinator, true)

    case claim_step(flow_run_id, step_id, opts) do
      {:ok, :already_succeeded} ->
        maybe_return_step_success(flow_run_id, enqueue_coordinator?, :already_succeeded)

      {:ok, {:automatic_attempts_exhausted, step_run}} ->
        Events.broadcast_updated(flow_run_id, %{
          "step_status" => "failed",
          "step_type" => step_run.step_type
        })

        maybe_broadcast_processing_progress(flow_run_id, step_run.step_type)
        _ = maybe_enqueue_coordinator(flow_run_id, enqueue_coordinator?)
        {:error, :automatic_attempts_exhausted}

      {:ok, execution} ->
        maybe_broadcast_processing_progress(flow_run_id, execution.step_run.step_type)
        {execution, progress_reporter} = maybe_start_progress_reporter(execution)

        maybe_log_flow_timing("step_start",
          flow_run_id: flow_run_id,
          step_id: step_id,
          step_type: execution.step_definition["type"],
          executor: execution_executor(execution),
          attempt: execution.step_run.attempt,
          previous_status: execution.previous_status,
          queue_wait_ms: execution.queue_wait_ms
        )

        {step_result, step_duration_ms} =
          try do
            timed_ms(fn -> run_step_safely(execution) end)
          after
            safe_stop_progress_reporter(progress_reporter)
          end

        handle_step_result(step_result, execution, step_duration_ms, enqueue_coordinator?, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_step_result(
         {:ok, output, artifacts, execution_metadata},
         execution,
         step_duration_ms,
         enqueue_coordinator?,
         _opts
       ) do
    maybe_log_flow_timing("step_finish",
      flow_run_id: execution.run.id,
      step_id: execution.step_run.step_id,
      step_type: execution.step_definition["type"],
      status: "succeeded",
      duration_ms: step_duration_ms,
      artifacts_count: length(artifacts)
    )

    persist_step_success(execution.step_run.id, output, artifacts, execution_metadata)
    maybe_return_step_success(execution.run.id, enqueue_coordinator?, output)
  end

  defp handle_step_result(
         {:error, reason},
         execution,
         step_duration_ms,
         enqueue_coordinator?,
         opts
       ) do
    execution_metadata = step_execution_metadata(execution_executor(execution))

    handle_step_result(
      {:error, reason, execution_metadata},
      execution,
      step_duration_ms,
      enqueue_coordinator?,
      opts
    )
  end

  defp handle_step_result(
         {:error, reason, execution_metadata},
         execution,
         step_duration_ms,
         enqueue_coordinator?,
         opts
       ) do
    maybe_log_flow_timing("step_finish",
      flow_run_id: execution.run.id,
      step_id: execution.step_run.step_id,
      step_type: execution.step_definition["type"],
      status: "failed",
      duration_ms: step_duration_ms,
      error: inspect(reason)
    )

    maybe_retry_or_fail_step(execution, reason, execution_metadata, enqueue_coordinator?, opts)
  end

  defp maybe_retry_or_fail_step(execution, reason, execution_metadata, enqueue_coordinator?, opts) do
    if booster_capacity_deferral?(reason, opts) do
      seconds = booster_capacity_snooze_seconds(opts)

      case persist_step_capacity_deferral(execution.step_run.id, execution_metadata) do
        {:ok, :ok} -> {:error, {:booster_capacity_busy, seconds}}
        {:error, persist_reason} -> {:error, persist_reason}
      end
    else
      case maybe_schedule_transient_step_retry(execution, reason, execution_metadata, opts) do
        {:retry, seconds} ->
          {:error, {:transient_step_retry_scheduled, reason, seconds}}

        :terminal ->
          persist_step_failure(execution.step_run.id, reason, execution_metadata)
          _ = maybe_enqueue_coordinator(execution.run.id, enqueue_coordinator?)
          {:error, reason}
      end
    end
  end

  defp booster_capacity_deferral?(reason, opts) do
    Keyword.get(opts, :fair_queue) in [
      :flow_booster,
      :flow_booster_background,
      "flow_booster",
      "flow_booster_background"
    ] and RetryPolicy.capacity_error?(reason)
  end

  defp booster_capacity_snooze_seconds(opts) do
    case fair_queue_config(Keyword.get(opts, :fair_queue)) do
      {:ok, _queue, config} ->
        config
        |> Keyword.get(:capacity_snooze_seconds, Keyword.get(config, :snooze_seconds, 5))
        |> positive_integer(5)

      :skip ->
        5
    end
  end

  defp upsert_preset_template(preset) do
    case Repo.get_by(Template, slug: preset["slug"]) do
      nil ->
        %Template{}
        |> Template.changeset(%{
          slug: preset["slug"],
          name: preset["name"],
          description: preset["description"]
        })
        |> Repo.insert!()

      template ->
        template
        |> Template.changeset(%{
          name: preset["name"],
          description: preset["description"]
        })
        |> Repo.update!()
    end
  end

  defp checksum_for_definition(definition) when is_map(definition) do
    definition
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp checksum_for_definition(_definition), do: nil

  defp find_matching_version(template_id, checksum) do
    Version
    |> where(
      [version],
      version.flow_template_id == ^template_id and version.checksum == ^checksum
    )
    |> order_by([version], desc: version.version)
    |> limit(1)
    |> Repo.one()
  end

  defp create_active_preset_version(template, preset) do
    Version
    |> where(
      [version],
      version.flow_template_id == ^template.id and version.status == "active"
    )
    |> Repo.update_all(set: [status: "archived"])

    {:ok, created_version} =
      create_version(template, %{
        "definition" => preset["definition"],
        "status" => "active"
      })

    created_version
  end

  defp ensure_active_version(%Version{status: "active"} = version), do: version

  defp ensure_active_version(%Version{} = version) do
    version
    |> Version.changeset(%{status: "active"})
    |> Repo.update!()
  end

  defp install_preset_version(template, preset, nil) do
    create_active_preset_version(template, preset)
  end

  defp install_preset_version(_template, _preset, %Version{} = existing_version) do
    ensure_active_version(existing_version)
  end

  defp create_started_run(template, version, input, enqueue?) do
    now = now_utc()

    with {:ok, run} <- insert_run_record(template, version, input, now),
         :ok <- insert_step_runs(run.id, version.definition),
         :ok <- maybe_mark_video_preparing(input),
         :ok <- maybe_enqueue_coordinator(run.id, enqueue?) do
      run
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        Repo.rollback({:changeset, changeset})

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp insert_run_record(template, version, input, now) do
    %Run{}
    |> Run.changeset(%{
      flow_template_id: template.id,
      flow_version_id: version.id,
      status: "running",
      input: input,
      context: %{},
      started_at: now
    })
    |> Repo.insert()
  end

  defp load_run_for_reconcile(flow_run_id) do
    case Run |> Repo.get(flow_run_id) do
      nil -> Repo.rollback(:not_found)
      run -> Repo.preload(run, [:flow_version, :step_runs])
    end
  end

  defp reconcile_loaded_run(%Run{status: "failed"} = run, _enqueue_jobs?) do
    terminalize_failed_run_steps(run.id, now_utc())
    reload_run(run)
  end

  defp reconcile_loaded_run(%Run{} = run, _enqueue_jobs?) when run.status in @terminal_statuses do
    reload_run(run)
  end

  defp reconcile_loaded_run(%Run{} = run, enqueue_jobs?) do
    run
    |> mark_blocked_steps()
    |> reload_run()
    |> continue_reconcile_run(enqueue_jobs?)
  end

  defp maybe_repair_scheduled_step_jobs(_flow_run_id, false), do: :ok

  defp maybe_repair_scheduled_step_jobs(flow_run_id, true) do
    Run
    |> Repo.get(flow_run_id)
    |> Repo.preload([:flow_version, :step_runs])
    |> repair_scheduled_step_jobs()
  end

  defp repair_scheduled_step_jobs(%Run{status: status}) when status in @terminal_statuses,
    do: :ok

  defp repair_scheduled_step_jobs(%Run{} = run) do
    run.step_runs
    |> Enum.filter(&(&1.status == "scheduled"))
    |> Enum.reduce_while(:ok, &repair_scheduled_step_job(run, &1, &2))
  end

  defp repair_scheduled_step_jobs(nil), do: :ok

  defp repair_scheduled_step_job(run, step_run, :ok) do
    if active_step_job?(run.id, step_run.step_id) do
      {:cont, :ok}
    else
      enqueue_repaired_step_job(run, step_run)
    end
  end

  defp enqueue_repaired_step_job(run, step_run) do
    step = fetch_step_definition!(run.flow_version.definition, step_run.step_id)

    case enqueue_step_job(run, step) do
      {:ok, _job} -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, {:enqueue_failed, reason}}}
    end
  end

  defp continue_reconcile_run(%Run{} = run, enqueue_jobs?) do
    cond do
      required_step_failed?(run) ->
        fail_reconciled_run(run)

      run_complete?(run) ->
        complete_reconciled_run(run)

      true ->
        schedule_reconciled_steps(run, enqueue_jobs?)
    end
  end

  defp fail_reconciled_run(%Run{} = run) do
    completed_at = now_utc()
    terminalize_failed_run_steps(run.id, completed_at)

    run
    |> Run.changeset(%{
      status: "failed",
      completed_at: completed_at,
      error: "one or more required steps failed"
    })
    |> Repo.update!()
    |> reload_run()
  end

  defp terminalize_failed_run_steps(flow_run_id, completed_at) do
    StepRun
    |> where(
      [step_run],
      step_run.flow_run_id == ^flow_run_id and step_run.status == "executing"
    )
    |> Repo.update_all(
      set: [
        status: "cancelled",
        completed_at: completed_at,
        error: @failed_run_executing_step_error
      ]
    )

    StepRun
    |> where(
      [step_run],
      step_run.flow_run_id == ^flow_run_id and step_run.status in ["queued", "scheduled"]
    )
    |> Repo.update_all(
      set: [
        status: "cancelled",
        completed_at: completed_at,
        error: @failed_run_pending_step_error
      ]
    )

    :ok
  end

  defp terminalize_step_for_run(%StepRun{status: status} = step_run, _run_status)
       when status in @terminal_statuses,
       do: step_run

  defp terminalize_step_for_run(%StepRun{} = step_run, run_status) do
    error =
      case {run_status, step_run.status} do
        {"failed", "executing"} -> @failed_run_executing_step_error
        {"failed", _status} -> @failed_run_pending_step_error
        {"cancelled", _status} -> step_run.error || "flow cancelled"
        {"succeeded", _status} -> step_run.error || "flow already completed"
      end

    step_run
    |> StepRun.changeset(%{
      status: "cancelled",
      completed_at: step_run.completed_at || now_utc(),
      error: error
    })
    |> Repo.update!()
  end

  defp complete_reconciled_run(%Run{} = run) do
    maybe_finalize_video_run(run)

    run =
      run
      |> Run.changeset(%{status: "succeeded", completed_at: now_utc(), error: nil})
      |> Repo.update!()
      |> reload_run()

    run
  end

  defp schedule_reconciled_steps(%Run{} = run, enqueue_jobs?) do
    step_runs_by_id = Map.new(run.step_runs, fn step_run -> {step_run.step_id, step_run} end)

    results =
      run.flow_version.definition
      |> Definition.next_ready_steps(step_runs_by_id)
      |> Enum.map(&schedule_reconciled_step(run, step_runs_by_id, &1, enqueue_jobs?))

    reconciled_run =
      run
      |> ensure_running()
      |> reload_run()

    if Enum.any?(results, &(&1 == :skipped_before_queue)) do
      continue_reconcile_run(reconciled_run, enqueue_jobs?)
    else
      reconciled_run
    end
  end

  defp schedule_reconciled_step(%Run{} = run, step_runs_by_id, step, enqueue_jobs?) do
    step_id = step["id"]
    step_type = step["type"]
    step_run = Map.fetch!(step_runs_by_id, step_id)

    case pre_queue_skip_output(step, step_runs_by_id) do
      {:skip, output, artifacts} ->
        mark_step_succeeded_without_queue!(run.id, step_run, step_type, output, artifacts)
        :skipped_before_queue

      {:skip, output} ->
        mark_step_succeeded_without_queue!(run.id, step_run, step_type, output)
        :skipped_before_queue

      :run ->
        schedule_step_job(run, step_run, step, enqueue_jobs?)
        :scheduled
    end
  end

  defp schedule_step_job(%Run{} = run, step_run, step, enqueue_jobs?) do
    step_id = step["id"]
    step_type = step["type"]
    scheduled_at = step_run.scheduled_at || now_utc()

    step_run
    |> StepRun.changeset(%{status: "scheduled", scheduled_at: scheduled_at})
    |> Repo.update!()

    maybe_log_flow_timing("step_scheduled",
      flow_run_id: run.id,
      step_id: step_id,
      step_type: step_type,
      attempt: step_run.attempt + 1
    )

    maybe_enqueue_step_job(run, step, enqueue_jobs?)
  end

  defp mark_step_succeeded_without_queue!(
         flow_run_id,
         step_run,
         step_type,
         output,
         artifacts \\ []
       ) do
    step_run
    |> StepRun.changeset(%{
      status: "succeeded",
      output: output,
      error: nil,
      completed_at: now_utc()
    })
    |> Repo.update!()

    replace_step_artifacts(flow_run_id, step_run.step_id, artifacts)

    Events.broadcast_updated(flow_run_id, %{
      "step_status" => "succeeded",
      "step_type" => step_type
    })

    maybe_broadcast_processing_progress(flow_run_id, step_type)
  end

  defp pre_queue_skip_output(%{"type" => "media.transcode_waveform"} = step, _step_runs) do
    {:ok, output, []} = MediaTranscodeWaveformStep.run(step, %{})
    {:skip, output}
  end

  defp pre_queue_skip_output(
         %{"id" => step_id, "type" => "media.package_hls_variant"} = step,
         step_runs_by_id
       ) do
    params = Map.get(step, "params", %{})
    source_step_id = string_value(Map.get(params, "source_step_id"))
    codec = normalize_media_param(Map.get(params, "codec"), "h264")
    size = normalize_media_param(Map.get(params, "size"), "sd")
    dependency_outputs = dependency_outputs_for_step(step, step_runs_by_id)

    with false <-
           params["audio_only"] == true and
             not StepSupport.inspect_reports_no_video?(dependency_outputs),
         source_step_id when is_binary(source_step_id) <- source_step_id,
         %StepRun{status: "succeeded", output: %{} = source_output} <-
           Map.get(step_runs_by_id, source_step_id),
         {:skip, reason, source_variant} <-
           skipped_hls_source_variant(source_output, codec, size) do
      {:skip, hls_variant_skip_output(step_id, codec, size, reason, source_variant)}
    else
      true -> {:skip, hls_variant_skip_output(step_id, codec, size, "source has video", %{})}
      _ -> :run
    end
  end

  defp pre_queue_skip_output(
         %{"id" => step_id, "type" => "media.extract_frame"} = step,
         step_runs_by_id
       ) do
    params = Map.get(step, "params", %{})
    role = normalize_media_param(Map.get(params, "role"), infer_frame_role(step_id))
    codec = normalize_frame_codec(Map.get(params, "codec"), "jpg")
    at_seconds = float_value(Map.get(params, "at_seconds")) || 0.0
    dependency_outputs = dependency_outputs_for_step(step, step_runs_by_id)
    skip_reason = StepSupport.frame_skip_reason(params, dependency_outputs)

    cond do
      is_binary(skip_reason) ->
        {:skip, frame_skip_output(step_id, role, codec, skip_reason)}

      prepackaged_frame_request?(role, codec, at_seconds) ->
        case prepackaged_frame_output(step, step_runs_by_id, role, codec) do
          %{} = output ->
            output = Map.put(output, "step_id", step_id)
            {:skip, output, frame_artifacts(output)}

          _ ->
            :run
        end

      true ->
        :run
    end
  end

  defp pre_queue_skip_output(_step, _step_runs_by_id), do: :run

  defp dependency_outputs_for_step(step, step_runs_by_id) do
    step
    |> Map.get("depends_on", [])
    |> list_value()
    |> Enum.flat_map(fn dependency_id ->
      case Map.get(step_runs_by_id, dependency_id) do
        %StepRun{status: "succeeded", output: %{} = output} -> [{dependency_id, output}]
        _other -> []
      end
    end)
    |> Map.new()
  end

  defp prepackaged_frame_request?(role, codec, at_seconds) do
    role in ~w(poster thumbnail placeholder) and codec == "jpg" and at_seconds == 0.0
  end

  defp prepackaged_frame_output(step, step_runs_by_id, role, codec) do
    step
    |> prepackaged_frame_source_step_ids()
    |> Enum.find_value(fn source_step_id ->
      case Map.get(step_runs_by_id, source_step_id) do
        %StepRun{
          status: "succeeded",
          output: %{"step_type" => "media.transcode_h264_ladder", "status" => "ok"} = output
        } ->
          output
          |> map_value("frame_outputs", %{})
          |> map_value(frame_output_key(role, codec))
          |> usable_prepackaged_frame_output()

        _other ->
          nil
      end
    end)
  end

  defp prepackaged_frame_source_step_ids(step) do
    params = Map.get(step, "params", %{})

    [
      string_value(Map.get(params, "source_step_id")),
      "video_h264_ladder" | list_value(Map.get(step, "depends_on", []))
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp usable_prepackaged_frame_output(%{"status" => "ok", "uri" => uri} = output)
       when is_binary(uri) and uri != "" do
    output
    |> Map.put("mode", "prepackaged")
    |> Map.put("step_type", "media.extract_frame")
  end

  defp usable_prepackaged_frame_output(_output), do: nil

  defp frame_artifacts(%{} = output) do
    uri = map_value(output, "uri")

    if is_binary(uri) and uri != "" do
      role = normalize_media_param(map_value(output, "role"), "frame")
      codec = normalize_frame_codec(map_value(output, "codec"), "jpg")

      [
        %{
          name: "#{role}_frame",
          uri: uri,
          media_type: frame_media_type(codec),
          size_bytes: integer_value(map_value(output, "file_size")),
          metadata: %{
            "type" => "image",
            "role" => role,
            "codec" => codec,
            "space_hash" => map_value(output, "space_hash"),
            "embed_hash" => map_value(output, "embed_hash"),
            "version" => integer_value(map_value(output, "version")) || 0,
            "source_step_id" => map_value(output, "source_step_id"),
            "source_size" => map_value(output, "source_size")
          }
        }
      ]
    else
      []
    end
  end

  defp frame_skip_output(step_id, role, codec, reason) do
    %{
      "status" => "skipped",
      "step_type" => "media.extract_frame",
      "mode" => "skipped",
      "step_id" => step_id,
      "role" => role,
      "codec" => codec,
      "reason" => reason
    }
  end

  defp infer_frame_role(step_id) when is_binary(step_id) do
    cond do
      String.contains?(step_id, "poster") -> "poster"
      String.contains?(step_id, "thumbnail") -> "thumbnail"
      String.contains?(step_id, "placeholder") -> "placeholder"
      true -> "frame"
    end
  end

  defp infer_frame_role(_step_id), do: "frame"

  defp normalize_frame_codec(value, default) do
    case normalize_media_param(value, default) do
      "jpeg" -> "jpg"
      codec -> codec
    end
  end

  defp frame_output_key(role, codec), do: "#{role}:#{codec}"

  defp frame_media_type("jpg"), do: "image/jpeg"
  defp frame_media_type("jpeg"), do: "image/jpeg"
  defp frame_media_type("png"), do: "image/png"
  defp frame_media_type("webp"), do: "image/webp"
  defp frame_media_type("avif"), do: "image/avif"
  defp frame_media_type(_codec), do: "application/octet-stream"

  defp skipped_hls_source_variant(
         %{"step_type" => "media.transcode_h264_ladder", "status" => "ok"} = output,
         codec,
         size
       )
       when codec == "h264" do
    case ladder_variant_output(output, size) do
      %{} = variant when map_size(variant) > 0 ->
        case map_value(variant, "status") do
          status when status in ["skipped", "unavailable"] ->
            {:skip, map_value(variant, "reason", status), variant}

          _ ->
            :run
        end

      _ ->
        active_sizes = output |> map_value("sizes", []) |> normalize_media_sizes()

        if active_sizes != [] and size not in active_sizes do
          {:skip, "source_resolution_below_variant", %{"size" => size}}
        else
          :run
        end
    end
  end

  defp skipped_hls_source_variant(%{"status" => status} = output, _codec, _size)
       when status in ["skipped", "unavailable"] do
    {:skip, map_value(output, "reason", status), output}
  end

  defp skipped_hls_source_variant(_output, _codec, _size), do: :run

  defp ladder_variant_output(output, size) do
    case map_value(output, "variant_outputs", %{}) do
      %{} = variant_outputs when map_size(variant_outputs) > 0 ->
        case map_value(variant_outputs, size) do
          %{} = variant -> variant
          _ -> ladder_variant_from_list(output, size)
        end

      _ ->
        ladder_variant_from_list(output, size)
    end
  end

  defp ladder_variant_from_list(output, size) do
    output
    |> map_value("variants", [])
    |> list_value()
    |> Kernel.++(list_value(map_value(output, "skipped_variants", [])))
    |> Enum.find(%{}, fn
      %{} = variant -> normalize_media_param(map_value(variant, "size"), nil) == size
      _ -> false
    end)
  end

  defp hls_variant_skip_output(step_id, codec, size, reason, source_variant) do
    %{
      "status" => "skipped",
      "step_type" => "media.package_hls_variant",
      "step_id" => step_id,
      "codec" => codec,
      "size" => size,
      "container" => "hls",
      "reason" => reason,
      "source_step_type" => map_value(source_variant, "step_type"),
      "source_width" => map_value(source_variant, "source_width"),
      "source_height" => map_value(source_variant, "source_height"),
      "source_long_edge" => map_value(source_variant, "source_long_edge")
    }
  end

  defp maybe_enqueue_step_job(_run, _step, false), do: :ok

  defp maybe_enqueue_step_job(%Run{} = run, step, true) do
    case enqueue_step_job(run, step) do
      {:ok, _job} -> :ok
      {:error, reason} -> Repo.rollback({:enqueue_failed, reason})
    end
  end

  defp maybe_return_step_success(flow_run_id, enqueue_coordinator?, output) do
    case maybe_enqueue_coordinator(flow_run_id, enqueue_coordinator?) do
      :ok -> {:ok, output}
      {:error, reason} -> {:error, reason}
    end
  end

  defp claim_step(flow_run_id, step_id, opts) do
    Repo.transaction(fn ->
      run = load_run_for_claim(flow_run_id)
      ensure_claimable_run!(run)

      maybe_enforce_fair_queue!(
        run,
        Keyword.get(opts, :fair_queue),
        {flow_run_id, step_id},
        oban_retry_attempt?(opts)
      )

      flow_run_id
      |> load_step_run_for_claim(step_id)
      |> claim_step_run(run, flow_run_id, step_id, opts)
    end)
    |> unwrap_transaction()
  end

  defp run_step(execution) do
    step_type = execution.step_definition["type"]
    context = step_context(execution)
    executor = executor_for_step(execution.step_definition, context)

    case StepRegistry.handler_for(step_type) do
      nil ->
        {:error, {:unknown_step_type, step_type}, step_execution_metadata(executor)}

      handler ->
        handler
        |> run_handler(execution.step_definition, context, step_type, executor)
        |> normalize_step_response(executor)
    end
  end

  defp executor_for_step(%{"type" => step_type} = step_definition, _context)
       when step_type in ["media.transcode_h264_ladder", "media.transcode_video"] do
    cond do
      GpuEncodingBooster.eligible_step?(step_definition) and
          GpuEncodingBooster.enabled?() ->
        :gpu_encoding_booster

      EncodingBooster.enabled?() ->
        :encoding_booster

      true ->
        :flame
    end
  end

  defp executor_for_step(%{"type" => "media.package_hls_variant"}, _context) do
    if EncodingBooster.enabled?(),
      do: :encoding_booster,
      else: :inline
  end

  defp executor_for_step(%{"type" => step_type}, _context)
       when step_type in [
              "media.transcode_audio",
              "media.generate_audio_peaks",
              "media.extract_frame",
              "media.package_hls_audio",
              "media.generate_segments",
              "media.generate_storyboard"
            ] do
    if EncodingBooster.enabled?(),
      do: :encoding_booster,
      else: StepRegistry.executor_for(step_type)
  end

  defp executor_for_step(%{"type" => step_type}, _context),
    do: StepRegistry.executor_for(step_type)

  defp execution_executor(execution) do
    executor_for_step(execution.step_definition, step_context(execution))
  end

  defp step_context(execution) do
    %{
      flow_run_id: execution.run.id,
      run_input: execution.run.input,
      step_run_input: execution.step_run.input,
      execution_metadata: execution.step_run.execution_metadata,
      dependency_outputs: execution.dependency_outputs,
      dependency_artifacts: execution.dependency_artifacts,
      resolved_input: resolve_input(execution),
      progress_reporter: Map.get(execution, :progress_reporter)
    }
  end

  defp maybe_start_progress_reporter(%{step_run: %{step_type: step_type}} = execution)
       when step_type in @media_step_types do
    case ProgressReporter.start_link(
           flow_run_id: execution.run.id,
           step_run_id: execution.step_run.id,
           step_id: execution.step_run.step_id,
           step_type: step_type
         ) do
      {:ok, pid} -> {Map.put(execution, :progress_reporter, pid), pid}
      {:error, _reason} -> {execution, nil}
    end
  end

  defp maybe_start_progress_reporter(execution), do: {execution, nil}

  defp safe_stop_progress_reporter(nil), do: :ok

  defp safe_stop_progress_reporter(pid) when is_pid(pid) do
    ProgressReporter.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  defp normalize_step_response({:ok, output, artifacts}, executor)
       when is_map(output) and is_list(artifacts) do
    {:ok, output, artifacts, step_execution_metadata(executor)}
  end

  defp normalize_step_response({:ok, output, artifacts, execution_metadata}, _executor)
       when is_map(output) and is_list(artifacts) do
    {:ok, output, artifacts, execution_metadata}
  end

  defp normalize_step_response({:ok, output}, executor) when is_map(output) do
    {:ok, output, [], step_execution_metadata(executor)}
  end

  defp normalize_step_response({:error, reason}, executor) do
    {:error, reason, step_execution_metadata(executor)}
  end

  defp normalize_step_response({:error, reason, execution_metadata}, _executor) do
    {:error, reason, execution_metadata}
  end

  defp normalize_step_response(other, executor) do
    {:error, {:invalid_step_response, other}, step_execution_metadata(executor)}
  end

  defp run_step_safely(execution) do
    run_step(execution)
  rescue
    error ->
      {:error,
       {:step_crashed, execution.step_definition["type"], Exception.message(error),
        Exception.format(:error, error, __STACKTRACE__)},
       step_execution_metadata(execution_executor(execution), crashed: true)}
  catch
    kind, reason ->
      {:error,
       {:step_crashed, execution.step_definition["type"], "#{kind} #{inspect(reason)}",
        Exception.format_banner(kind, reason)},
       step_execution_metadata(execution_executor(execution), crashed: true)}
  end

  defp run_handler(handler, step_definition, context, step_type, :inline) do
    run_handler_with_metadata(:inline, step_type, fn ->
      handler.run(step_definition, context)
    end)
  end

  defp run_handler(handler, step_definition, context, step_type, :flame) do
    run_input = Map.get(context, :run_input, %{})
    flow_run_id = Map.get(context, :flow_run_id)
    step_id = step_definition["id"]

    if force_inline_step_execution?(run_input) do
      maybe_log_flow_timing("flame_step_forced_inline",
        flow_run_id: flow_run_id,
        step_id: step_id,
        step_type: step_type
      )

      run_handler_with_metadata(:inline, step_type, [requested_executor: :flame], fn ->
        handler.run(step_definition, context)
      end)
    else
      flame_pool = flame_pool_for_step(step_definition, step_type)

      try do
        maybe_log_flow_timing("flame_call_start",
          flow_run_id: flow_run_id,
          step_id: step_id,
          step_type: step_type,
          flame_pool: flame_pool
        )

        {result, flame_duration_ms} =
          timed_ms(fn ->
            call_flame(
              flame_pool,
              fn ->
                run_handler_with_metadata(:flame, step_type, [flame_pool: flame_pool], fn ->
                  handler.run(step_definition, context)
                end)
              end,
              flame_call_options(step_definition, flame_pool)
            )
          end)

        maybe_log_flow_timing("flame_call_finish",
          flow_run_id: flow_run_id,
          step_id: step_id,
          step_type: step_type,
          duration_ms: flame_duration_ms,
          flame_pool: flame_pool
        )

        append_execution_metadata(result, flame_call_ms: flame_duration_ms)
      rescue
        error ->
          maybe_log_flow_timing("flame_call_failed",
            flow_run_id: flow_run_id,
            step_id: step_id,
            step_type: step_type,
            flame_pool: flame_pool,
            error: Exception.message(error)
          )

          Logger.error(
            "FLAME step execution failed for #{step_type}: #{Exception.message(error)}"
          )

          {:error, {:flame_execution_failed, step_type, Exception.message(error)},
           step_execution_metadata(:flame,
             failed_before_runner_metadata: true,
             flame_pool: flame_pool,
             error: Exception.message(error)
           )}
      catch
        kind, reason ->
          maybe_log_flow_timing("flame_call_failed",
            flow_run_id: flow_run_id,
            step_id: step_id,
            step_type: step_type,
            flame_pool: flame_pool,
            error: "#{kind} #{inspect(reason)}"
          )

          Logger.error("FLAME step execution failed for #{step_type}: #{kind} #{inspect(reason)}")

          {:error, {:flame_execution_failed, step_type, kind, reason},
           step_execution_metadata(:flame,
             failed_before_runner_metadata: true,
             flame_pool: flame_pool,
             error: "#{kind} #{inspect(reason)}"
           )}
      end
    end
  end

  defp run_handler(handler, step_definition, context, step_type, :encoding_booster) do
    direct_context = Map.put(context, :encoding_booster_dispatch, :direct)

    direct_result =
      :encoding_booster
      |> run_handler_with_metadata(step_type, fn ->
        handler.run(step_definition, direct_context)
      end)
      |> annotate_encoding_booster_usage()

    case direct_result do
      {:error, {:encoding_booster_fallback_required, error_code, _reason}, direct_metadata} ->
        fallback_context =
          context
          |> Map.put(:encoding_booster_dispatch, :fallback)
          |> Map.put(:encoding_booster_fallback_code, error_code)

        handler
        |> run_handler(step_definition, fallback_context, step_type, :flame)
        |> append_execution_metadata(
          encoding_booster_fallback: error_code,
          encoding_booster_attempted: true,
          encoding_booster_used: false,
          requested_executor: :encoding_booster,
          encoding_booster_execution: direct_metadata
        )

      result ->
        result
    end
  end

  defp run_handler(handler, step_definition, context, step_type, :gpu_encoding_booster) do
    direct_context = Map.put(context, :gpu_encoding_booster_dispatch, :direct)

    direct_result =
      :gpu_encoding_booster
      |> run_handler_with_metadata(step_type, fn ->
        handler.run(step_definition, direct_context)
      end)
      |> annotate_gpu_encoding_booster_usage()

    case direct_result do
      {:error, {:gpu_encoding_booster_fallback_required, error_code, _reason}, direct_metadata} ->
        cpu_fallback_context =
          context
          |> Map.put(:gpu_encoding_booster_dispatch, :cpu_fallback)
          |> Map.put(:gpu_encoding_booster_fallback_code, error_code)

        handler
        |> run_handler(step_definition, cpu_fallback_context, step_type, :encoding_booster)
        |> append_execution_metadata(
          gpu_encoding_booster_fallback: error_code,
          gpu_encoding_booster_attempted: true,
          gpu_encoding_booster_used: false,
          requested_executor: :gpu_encoding_booster,
          gpu_encoding_booster_execution: direct_metadata
        )

      result ->
        result
    end
  end

  defp run_handler(handler, step_definition, context, step_type, _executor) do
    run_handler_with_metadata(:inline, step_type, fn ->
      handler.run(step_definition, context)
    end)
  end

  defp annotate_encoding_booster_usage(
         {:ok, %{"mode" => "encoding_booster"} = output, artifacts, metadata}
       ) do
    {:ok, output, artifacts,
     Map.merge(metadata, %{
       "encoding_booster_attempted" => true,
       "encoding_booster_used" => true
     })}
  end

  defp annotate_encoding_booster_usage({:ok, output, artifacts, metadata}) do
    {:ok, output, artifacts,
     Map.merge(metadata, %{
       "encoding_booster_attempted" => false,
       "encoding_booster_used" => false
     })}
  end

  defp annotate_encoding_booster_usage({:error, reason, metadata}) do
    {:error, reason,
     Map.merge(metadata, %{
       "encoding_booster_attempted" => true,
       "encoding_booster_used" => false
     })}
  end

  defp annotate_encoding_booster_usage(result), do: result

  defp annotate_gpu_encoding_booster_usage(
         {:ok, %{"mode" => "gpu_encoding_booster"} = output, artifacts, metadata}
       ) do
    {:ok, output, artifacts,
     Map.merge(metadata, %{
       "gpu_encoding_booster_attempted" => true,
       "gpu_encoding_booster_used" => true
     })}
  end

  defp annotate_gpu_encoding_booster_usage({:ok, output, artifacts, metadata}) do
    {:ok, output, artifacts,
     Map.merge(metadata, %{
       "gpu_encoding_booster_attempted" => false,
       "gpu_encoding_booster_used" => false
     })}
  end

  defp annotate_gpu_encoding_booster_usage({:error, reason, metadata}) do
    {:error, reason,
     Map.merge(metadata, %{
       "gpu_encoding_booster_attempted" => true,
       "gpu_encoding_booster_used" => false
     })}
  end

  defp annotate_gpu_encoding_booster_usage(result), do: result

  defp run_handler_with_metadata(executor, step_type, fun) when is_function(fun, 0) do
    run_handler_with_metadata(executor, step_type, [], fun)
  end

  defp run_handler_with_metadata(executor, step_type, extra, fun) when is_function(fun, 0) do
    with_execution_metadata(executor, fun.(), extra)
  rescue
    error ->
      {:error,
       {:step_crashed, step_type, Exception.message(error),
        Exception.format(:error, error, __STACKTRACE__)},
       step_execution_metadata(executor, Keyword.put(extra, :crashed, true))}
  catch
    kind, reason ->
      {:error,
       {:step_crashed, step_type, "#{kind} #{inspect(reason)}",
        Exception.format_banner(kind, reason)},
       step_execution_metadata(executor, Keyword.put(extra, :crashed, true))}
  end

  defp with_execution_metadata(executor, result, extra) do
    metadata = step_execution_metadata(executor, extra)

    case result do
      {:ok, output, artifacts} -> {:ok, output, artifacts, metadata}
      {:ok, output} -> {:ok, output, [], metadata}
      {:error, reason} -> {:error, reason, metadata}
      other -> other
    end
  end

  defp append_execution_metadata({:ok, output, artifacts, metadata}, extra) do
    {:ok, output, artifacts, Map.merge(metadata, metadata_extra(extra))}
  end

  defp append_execution_metadata({:error, reason, metadata}, extra) do
    {:error, reason, Map.merge(metadata, metadata_extra(extra))}
  end

  defp append_execution_metadata(other, _extra), do: other

  defp call_flame(pool, fun, options) do
    case Application.get_env(:mave_core, :flow_flame_caller) do
      caller when is_function(caller, 3) -> caller.(pool, fun, options)
      _caller -> FLAME.call(pool, fun, options)
    end
  end

  defp metadata_extra(extra) do
    Map.new(extra, fn {key, value} -> {to_string(key), value} end)
  end

  defp step_execution_metadata(executor, extra \\ []) do
    ExecutionMetadata.current(executor, extra)
  end

  defp force_inline_step_execution?(run_input) when is_map(run_input) do
    run_input["flow_step_executor"] in ["inline", :inline] or
      run_input["flow_disable_flame_steps"] in [true, "true", 1, "1"]
  end

  defp force_inline_step_execution?(_), do: false

  defp flame_pool_for_step(step_definition, step_type) do
    pool_key = flame_pool_key_for_step(step_definition, step_type)
    pools = Application.get_env(:mave_core, :flow_flame_pools, [])

    Keyword.get(pools, pool_key) ||
      Application.get_env(:mave_core, :flow_flame_pool, @default_flame_pool)
  end

  defp flame_pool_key_for_step(%{"params" => %{"flame_pool" => pool}}, _step_type) do
    normalize_flame_pool_key(pool)
  end

  defp flame_pool_key_for_step(_step_definition, step_type) do
    if MapSet.member?(@media_flame_pool_step_types, step_type), do: :media, else: :default
  end

  defp normalize_flame_pool_key(pool) when is_atom(pool), do: pool

  defp normalize_flame_pool_key(pool) when is_binary(pool) do
    pool
    |> String.trim()
    |> String.downcase()
    |> case do
      "media" -> :media
      "image" -> :image
      "default" -> :default
      _other -> :default
    end
  end

  defp normalize_flame_pool_key(_pool), do: :default

  defp flame_call_options(step_definition, flame_pool) do
    timeout = flame_call_timeout(step_definition, flame_pool)

    case timeout do
      timeout when is_integer(timeout) and timeout > 0 -> [timeout: timeout]
      :infinity -> [timeout: :infinity]
      _ -> []
    end
  end

  defp flame_call_timeout(step_definition, flame_pool) do
    step_timeout(step_definition) || flame_pool_timeout(flame_pool)
  end

  defp step_timeout(%{"type" => step_type}) when is_binary(step_type) do
    case step_timeout_key(step_type) do
      nil ->
        nil

      timeout_key ->
        :mave_core
        |> Application.get_env(:flow_flame_timeouts, [])
        |> Keyword.get(timeout_key)
    end
  end

  defp step_timeout(_step_definition), do: nil

  defp step_timeout_key(step_type) do
    Map.get(@flame_timeout_keys, step_type)
  end

  defp flame_pool_timeout(flame_pool) do
    flame_pool
    |> flame_pool_config()
    |> Keyword.get(:timeout)
  end

  defp flame_pool_config(flame_pool) do
    case Application.get_env(:mave_core, :flame_pools, []) do
      pools when is_list(pools) ->
        Keyword.get(pools, flame_pool, Application.get_env(:mave_core, :flame_pool, []))

      _other ->
        Application.get_env(:mave_core, :flame_pool, [])
    end
  end

  defp queue_wait_ms(
         %StepRun{status: "scheduled", scheduled_at: %DateTime{} = scheduled_at},
         claimed_at
       ) do
    DateTime.diff(claimed_at, scheduled_at, :millisecond)
  end

  defp queue_wait_ms(
         %StepRun{status: "scheduled", updated_at: %DateTime{} = scheduled_at},
         claimed_at
       ) do
    DateTime.diff(claimed_at, scheduled_at, :millisecond)
  end

  defp queue_wait_ms(_, _), do: nil

  defp timed_ms(func) do
    started_at = System.monotonic_time(:millisecond)
    result = func.()
    {result, System.monotonic_time(:millisecond) - started_at}
  end

  defp maybe_log_flow_timing(event, meta) do
    if Application.get_env(:mave_core, :flow_timing_logs, false) do
      Logger.info("flow_timing #{event} #{inspect(meta)}")
    end
  end

  defp resolve_input(execution) do
    %{
      "declared_inputs" => Map.get(execution.step_run.input || %{}, "inputs", %{}),
      "params" => Map.get(execution.step_run.input || %{}, "params", %{}),
      "run_input" => execution.run.input,
      "dependency_outputs" => execution.dependency_outputs,
      "dependency_artifacts" => execution.dependency_artifacts
    }
  end

  defp persist_step_success(step_run_id, output, artifacts, execution_metadata) do
    result =
      Repo.transaction(fn ->
        step_run = Repo.get!(StepRun, step_run_id)
        run = Repo.get!(Run, step_run.flow_run_id)
        flow_run_id = step_run.flow_run_id
        producer_step_id = step_run.step_id

        if run.status in @terminal_run_statuses do
          terminal_step_run = terminalize_step_for_run(step_run, run.status)

          {:terminal, terminal_step_run.flow_run_id, terminal_step_run.step_type,
           terminal_step_run.status}
        else
          completed_step_run =
            step_run
            |> StepRun.changeset(%{
              status: "succeeded",
              output: output,
              execution_metadata:
                merge_step_execution_metadata(step_run.execution_metadata, execution_metadata),
              error: nil,
              completed_at: now_utc()
            })
            |> Repo.update!()

          replace_step_artifacts(flow_run_id, producer_step_id, artifacts)

          {flow_run_id, completed_step_run.id, completed_step_run.step_type}
        end
      end)
      |> unwrap_transaction()

    case result do
      {:ok, {:terminal, flow_run_id, step_type, step_status}} ->
        Events.broadcast_updated(flow_run_id, %{
          "step_status" => step_status,
          "step_type" => step_type
        })

        maybe_broadcast_processing_progress(flow_run_id, step_type)
        {:ok, :cancelled}

      {:ok, {flow_run_id, step_run_id, step_type}} ->
        Events.broadcast_updated(flow_run_id, %{
          "step_status" => "succeeded",
          "step_type" => step_type
        })

        maybe_publish_processing_manifest(step_run_id, flow_run_id, step_type, output)
        maybe_enqueue_ready_webhooks_for_step(flow_run_id, output)
        maybe_sync_completed_media_metadata(flow_run_id, step_type, output)
        maybe_broadcast_processing_progress(flow_run_id, step_type)
        {:ok, :ok}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_step_failure(step_run_id, reason, execution_metadata) do
    result =
      Repo.transaction(fn ->
        step_run = Repo.get!(StepRun, step_run_id)
        run = Repo.get!(Run, step_run.flow_run_id)

        updated_step_run =
          if run.status in @terminal_run_statuses do
            terminalize_step_for_run(step_run, run.status)
          else
            step_run
            |> StepRun.changeset(%{
              status: "failed",
              execution_metadata:
                merge_step_execution_metadata(step_run.execution_metadata, execution_metadata),
              error: normalize_step_error(reason),
              completed_at: now_utc()
            })
            |> Repo.update!()
          end

        {updated_step_run.flow_run_id, updated_step_run.status, updated_step_run.step_type}
      end)
      |> unwrap_transaction()

    case result do
      {:ok, {flow_run_id, status, step_type}} ->
        Events.broadcast_updated(flow_run_id, %{"step_status" => status, "step_type" => step_type})

        maybe_broadcast_processing_progress(flow_run_id, step_type)

        {:ok, :ok}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_schedule_transient_step_retry(execution, reason, execution_metadata, opts) do
    attempt = execution_cycle_attempts(execution.step_run)
    max_attempts = transient_step_retry_max_attempts(reason)

    cond do
      not transient_step_auto_retry_requested?(opts) ->
        :terminal

      attempt >= max_attempts ->
        :terminal

      not RetryPolicy.transient_error?(reason) ->
        :terminal

      true ->
        seconds = transient_step_retry_backoff_seconds(execution, reason, attempt)

        persist_step_retry(
          execution.step_run.id,
          reason,
          execution_metadata,
          attempt,
          max_attempts,
          seconds
        )

        maybe_log_flow_timing("step_retry_scheduled",
          flow_run_id: execution.run.id,
          step_id: execution.step_run.step_id,
          step_type: execution.step_definition["type"],
          attempt: attempt,
          max_attempts: max_attempts,
          backoff_seconds: seconds,
          error: inspect(reason)
        )

        {:retry, seconds}
    end
  end

  defp merge_step_execution_metadata(existing, metadata)
       when is_map(existing) and is_map(metadata) do
    Map.merge(existing, metadata, fn
      "progress", old, new when is_map(old) and is_map(new) -> Map.merge(old, new)
      _key, _old, new -> new
    end)
  end

  defp merge_step_execution_metadata(_existing, metadata) when is_map(metadata), do: metadata
  defp merge_step_execution_metadata(existing, _metadata) when is_map(existing), do: existing
  defp merge_step_execution_metadata(_existing, _metadata), do: %{}

  defp persist_step_retry(step_run_id, reason, execution_metadata, attempt, max_attempts, seconds) do
    result =
      Repo.transaction(fn ->
        step_run = Repo.get!(StepRun, step_run_id)
        run = Repo.get!(Run, step_run.flow_run_id)

        updated_step_run =
          if run.status in @terminal_run_statuses do
            terminalize_step_for_run(step_run, run.status)
          else
            step_run
            |> StepRun.changeset(%{
              status: "scheduled",
              started_at: nil,
              completed_at: nil,
              execution_metadata:
                step_run.execution_metadata
                |> merge_step_execution_metadata(execution_metadata)
                |> retry_execution_metadata(attempt, max_attempts, seconds),
              error: transient_retry_error(reason, attempt, max_attempts, seconds)
            })
            |> Repo.update!()
          end

        {updated_step_run.flow_run_id, updated_step_run.status, updated_step_run.step_type}
      end)
      |> unwrap_transaction()

    case result do
      {:ok, {flow_run_id, status, step_type}} ->
        Events.broadcast_updated(flow_run_id, %{"step_status" => status, "step_type" => step_type})

        maybe_broadcast_processing_progress(flow_run_id, step_type)

        {:ok, :ok}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_step_capacity_deferral(step_run_id, execution_metadata) do
    result =
      Repo.transaction(fn ->
        step_run = Repo.get!(StepRun, step_run_id)
        run = Repo.get!(Run, step_run.flow_run_id)

        updated_step_run =
          if run.status in @terminal_run_statuses do
            terminalize_step_for_run(step_run, run.status)
          else
            step_run
            |> StepRun.changeset(%{
              status: "scheduled",
              attempt: max((step_run.attempt || 1) - 1, 0),
              started_at: nil,
              completed_at: nil,
              execution_metadata:
                capacity_deferral_metadata(step_run.execution_metadata, execution_metadata),
              error: nil
            })
            |> Repo.update!()
          end

        {updated_step_run.flow_run_id, updated_step_run.status, updated_step_run.step_type}
      end)
      |> unwrap_transaction()

    case result do
      {:ok, {flow_run_id, status, step_type}} ->
        Events.broadcast_updated(flow_run_id, %{"step_status" => status, "step_type" => step_type})

        maybe_broadcast_processing_progress(flow_run_id, step_type)
        {:ok, :ok}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp capacity_deferral_metadata(existing, execution_metadata) do
    metadata =
      existing
      |> merge_step_execution_metadata(execution_metadata)
      |> Map.delete("retry")
      |> mark_progress_queued()

    cycle_attempts =
      metadata
      |> get_in(["retry_policy", "cycle_attempts"])
      |> then(fn
        attempts when is_integer(attempts) and attempts > 0 -> attempts - 1
        _other -> 0
      end)

    deferrals =
      case get_in(metadata, ["capacity", "deferrals"]) do
        count when is_integer(count) and count >= 0 -> count + 1
        _other -> 1
      end

    metadata
    |> put_retry_policy_metadata(%{"cycle_attempts" => cycle_attempts, "exhausted" => false})
    |> Map.put("capacity", %{
      "deferrals" => deferrals,
      "last_reason" => "encoding_booster_busy",
      "last_deferred_at" => DateTime.to_iso8601(now_utc())
    })
  end

  defp transient_step_auto_retry_requested?(opts) do
    Keyword.get(opts, :auto_retry, Keyword.has_key?(opts, :oban_attempt)) and
      transient_step_retry_max_attempts() > 1
  end

  defp transient_step_retry_max_attempts do
    case Application.get_env(:mave_core, :flow_step_auto_retry, []) do
      false ->
        1

      config when is_list(config) ->
        config
        |> Keyword.get(:max_attempts, @default_max_execution_attempts)
        |> positive_integer(@default_max_execution_attempts)
        |> min(max_execution_attempts())

      _other ->
        max_execution_attempts()
    end
  end

  defp transient_step_retry_max_attempts(reason) do
    cond do
      RetryPolicy.resumable_chunk_error?(reason) ->
        :resumable_chunk_max_attempts
        |> flow_step_auto_retry_config_value(@default_resumable_chunk_max_execution_attempts)
        |> positive_integer(@default_resumable_chunk_max_execution_attempts)

      RetryPolicy.booster_gateway_error?(reason) ->
        :booster_gateway_max_attempts
        |> flow_step_auto_retry_config_value(@default_booster_gateway_max_execution_attempts)
        |> positive_integer(@default_booster_gateway_max_execution_attempts)

      true ->
        transient_step_retry_max_attempts()
    end
  end

  defp transient_step_retry_backoff_seconds(execution, reason, attempt) do
    {config_key, default} =
      if RetryPolicy.booster_gateway_error?(reason) do
        {:booster_gateway_backoff_seconds, @default_booster_gateway_backoff_seconds}
      else
        {:backoff_seconds, [10, 30]}
      end

    base_seconds =
      config_key
      |> flow_step_auto_retry_config_value(default)
      |> backoff_seconds_for_attempt(attempt)

    jitter_seconds =
      :jitter_seconds
      |> flow_step_auto_retry_config_value(5)
      |> non_negative_integer(5)

    base_seconds + retry_jitter_seconds(execution, attempt, jitter_seconds)
  end

  defp flow_step_auto_retry_config_value(key, default) do
    case Application.get_env(:mave_core, :flow_step_auto_retry, []) do
      false -> default
      config when is_list(config) -> Keyword.get(config, key, default)
      _other -> default
    end
  end

  defp backoff_seconds_for_attempt(seconds, _attempt) when is_integer(seconds) do
    positive_integer(seconds, 10)
  end

  defp backoff_seconds_for_attempt(seconds, attempt) when is_list(seconds) do
    seconds
    |> Enum.at(max(attempt - 1, 0))
    |> case do
      value when is_integer(value) and value > 0 -> value
      _ -> 10
    end
  end

  defp backoff_seconds_for_attempt(_seconds, _attempt), do: 10

  defp retry_jitter_seconds(_execution, _attempt, 0), do: 0

  defp retry_jitter_seconds(execution, attempt, jitter_seconds) do
    :erlang.phash2({execution.run.id, execution.step_run.step_id, attempt}, jitter_seconds + 1)
  end

  defp retry_execution_metadata(metadata, attempt, max_attempts, seconds) when is_map(metadata) do
    metadata
    |> put_retry_policy_metadata(%{"max_execution_attempts" => max_attempts})
    |> Map.put("retry", %{
      "automatic" => true,
      "reason" => "transient",
      "attempt" => attempt,
      "next_attempt" => attempt + 1,
      "max_attempts" => max_attempts,
      "backoff_seconds" => seconds
    })
  end

  defp retry_execution_metadata(_metadata, attempt, max_attempts, seconds) do
    retry_execution_metadata(%{}, attempt, max_attempts, seconds)
  end

  defp transient_retry_error(reason, attempt, max_attempts, seconds) do
    "retrying transient failure #{attempt}/#{max_attempts} in #{seconds}s: #{normalize_step_error(reason)}"
    |> String.slice(0, 255)
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp non_negative_integer(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value, default), do: default

  defp load_run_for_claim(flow_run_id) do
    case Run |> Repo.get(flow_run_id) do
      nil -> Repo.rollback(:run_not_found)
      run -> Repo.preload(run, [:flow_version])
    end
  end

  defp ensure_claimable_run!(%Run{} = run) do
    if run.status in ["cancelled", "failed", "succeeded"] do
      Repo.rollback(:run_not_running)
    end
  end

  defp maybe_enforce_fair_queue!(
         %Run{id: flow_run_id, input: input},
         fair_queue,
         current_step,
         retry_attempt?
       ) do
    case fair_queue_config(fair_queue) do
      {:ok, queue, config} ->
        space_hash = Map.get(input || %{}, "space_hash")
        exclude_step = fair_queue_exclude_step(current_step, retry_attempt?)

        maybe_lock_fair_queue_global!(queue, config)
        maybe_lock_fair_queue_run!(queue, config, flow_run_id)
        enforce_global_fair_queue!(queue, config, exclude_step)
        enforce_background_fair_queue!(queue, config, exclude_step)
        enforce_step_type_fair_queue!(queue, config, current_step, exclude_step)
        enforce_run_fair_queue!(flow_run_id, queue, config, exclude_step)

        space_concurrency = effective_space_fair_queue_concurrency(queue, config)

        enforce_space_fair_queue!(
          space_hash,
          queue,
          space_concurrency,
          Keyword.fetch!(config, :snooze_seconds),
          exclude_step
        )

      :skip ->
        :ok
    end
  end

  defp enforce_space_fair_queue!(
         space_hash,
         queue,
         space_concurrency,
         snooze_seconds,
         exclude_step
       )
       when is_binary(space_hash) and space_hash != "" do
    lock_fair_queue_space!(queue, space_hash)

    active_count =
      active_fair_queue_steps(
        space_hash,
        fair_queue_filters(queue),
        exclude_step
      )

    if active_count >= space_concurrency do
      Repo.rollback({:fair_queue_busy, snooze_seconds})
    end
  end

  defp enforce_space_fair_queue!(
         _space_hash,
         _queue,
         _space_concurrency,
         _snooze_seconds,
         _exclude_step
       ),
       do: :ok

  defp enforce_global_fair_queue!(queue, config, exclude_step) do
    case Keyword.get(config, :global_concurrency) do
      concurrency when is_integer(concurrency) and concurrency > 0 ->
        active_count = active_fair_queue_steps(nil, fair_queue_filters(queue), exclude_step)

        if active_count >= concurrency do
          Repo.rollback({:fair_queue_busy, Keyword.fetch!(config, :snooze_seconds)})
        end

      _other ->
        :ok
    end
  end

  defp enforce_background_fair_queue!(:flow_booster_background, config, exclude_step) do
    case effective_background_fair_queue_concurrency(config) do
      concurrency when is_integer(concurrency) and concurrency >= 0 ->
        filters =
          :flow_booster_background
          |> fair_queue_filters()
          |> Keyword.put(:execution_queues, ["flow_booster_background"])

        if active_fair_queue_steps(nil, filters, exclude_step) >= concurrency do
          Repo.rollback({:fair_queue_busy, Keyword.fetch!(config, :snooze_seconds)})
        end

      _other ->
        :ok
    end
  end

  defp enforce_background_fair_queue!(_queue, _config, _exclude_step), do: :ok

  defp effective_background_fair_queue_concurrency(config) do
    if foreground_booster_waiting?() do
      Keyword.get(
        config,
        :background_concurrency_when_foreground_waiting,
        Keyword.get(config, :background_concurrency)
      )
    else
      Keyword.get(config, :background_concurrency)
    end
  end

  defp foreground_booster_waiting? do
    Job
    |> where([job], job.worker == ^worker_name(FlowStepWorker))
    |> where([job], job.state == "available")
    |> where([job], job.queue == "flow_booster")
    |> Repo.exists?()
  end

  defp enforce_step_type_fair_queue!(queue, config, current_step, exclude_step) do
    limits = Keyword.get(config, :step_type_concurrency, %{})

    with step_type when is_binary(step_type) <- fair_queue_step_type(current_step),
         concurrency when is_integer(concurrency) and concurrency > 0 <-
           Map.get(limits, step_type) do
      filters =
        queue
        |> fair_queue_filters()
        |> Keyword.put(:step_types, [step_type])

      if active_fair_queue_steps(nil, filters, exclude_step) >= concurrency do
        Repo.rollback({:fair_queue_busy, Keyword.fetch!(config, :snooze_seconds)})
      end
    else
      _other -> :ok
    end
  end

  defp fair_queue_step_type({flow_run_id, step_id}) do
    StepRun
    |> where(
      [step_run],
      step_run.flow_run_id == ^flow_run_id and step_run.step_id == ^step_id
    )
    |> select([step_run], step_run.step_type)
    |> Repo.one()
  end

  defp fair_queue_step_type(_current_step), do: nil

  defp enforce_run_fair_queue!(flow_run_id, queue, config, exclude_step) do
    demanding_runs =
      if Keyword.get(config, :work_conserving, false) do
        demanding_fair_queue_runs(queue)
      else
        0
      end

    case FairQueue.run_concurrency(config, demanding_runs) do
      concurrency when is_integer(concurrency) and concurrency > 0 ->
        filters =
          queue
          |> fair_queue_filters()
          |> Keyword.put(:execution_queues, [Atom.to_string(queue)])

        if active_fair_queue_steps(nil, filters, exclude_step, flow_run_id) >= concurrency do
          Repo.rollback({:fair_queue_busy, Keyword.fetch!(config, :snooze_seconds)})
        end

      _other ->
        :ok
    end
  end

  defp effective_space_fair_queue_concurrency(queue, config) do
    demanding_spaces =
      if Keyword.get(config, :work_conserving, false) do
        demanding_fair_queue_spaces(queue)
      else
        0
      end

    FairQueue.space_concurrency(config, demanding_spaces)
  end

  defp demanding_fair_queue_spaces(queue) do
    queue_name = Atom.to_string(queue)

    Job
    |> where([job], job.worker == ^worker_name(FlowStepWorker))
    |> where([job], job.state in ^@demanding_oban_step_job_states)
    |> where([job], job.queue == ^queue_name)
    |> where([job], fragment("COALESCE(?->>'space_hash', '') <> ''", job.args))
    |> select([job], count(fragment("?->>'space_hash'", job.args), :distinct))
    |> Repo.one()
  end

  defp demanding_fair_queue_runs(queue) do
    queue_name = Atom.to_string(queue)

    Job
    |> where([job], job.worker == ^worker_name(FlowStepWorker))
    |> where([job], job.state in ^@demanding_oban_step_job_states)
    |> where([job], job.queue == ^queue_name)
    |> where([job], fragment("COALESCE(?->>'flow_run_id', '') <> ''", job.args))
    |> select([job], count(fragment("?->>'flow_run_id'", job.args), :distinct))
    |> Repo.one()
  end

  defp fair_queue_config(fair_queue) do
    with {:ok, queue} <- normalize_fair_queue(fair_queue),
         config when is_list(config) <- configured_fair_queue(queue),
         concurrency when is_integer(concurrency) and concurrency > 0 <-
           Keyword.get(config, :space_concurrency),
         snooze_seconds when is_integer(snooze_seconds) and snooze_seconds > 0 <-
           Keyword.get(config, :snooze_seconds) do
      {:ok, queue, config}
    else
      _ -> :skip
    end
  end

  defp fair_queue_exclude_step(current_step, true), do: current_step
  defp fair_queue_exclude_step(_current_step, false), do: nil

  defp normalize_fair_queue(queue) when queue in [:flow_imports, "flow_imports"],
    do: {:ok, :flow_imports}

  defp normalize_fair_queue(queue) when queue in [:flow_steps, "flow_steps"],
    do: {:ok, :flow_steps}

  defp normalize_fair_queue(queue) when queue in [:flow_media, "flow_media"],
    do: {:ok, :flow_media}

  defp normalize_fair_queue(queue) when queue in [:flow_booster, "flow_booster"],
    do: {:ok, :flow_booster}

  defp normalize_fair_queue(queue)
       when queue in [:flow_booster_background, "flow_booster_background"],
       do: {:ok, :flow_booster_background}

  defp normalize_fair_queue(queue) when queue in [:flow_low, "flow_low"], do: {:ok, :flow_low}
  defp normalize_fair_queue(_queue), do: :skip

  defp configured_fair_queue(queue) do
    :mave_core
    |> Application.get_env(:flow_fair_queues, [])
    |> Keyword.get(queue, [])
  end

  defp fair_queue_filters(:flow_imports), do: [priorities: ["import"]]
  defp fair_queue_filters(:flow_steps), do: [execution_queues: ["flow_steps"]]
  defp fair_queue_filters(:flow_media), do: [step_types: @media_step_types]

  defp fair_queue_filters(queue) when queue in [:flow_booster, :flow_booster_background],
    do: [
      step_types: [
        "asset.upload_original",
        "media.extract_frame",
        "media.generate_segments",
        "media.generate_audio_peaks",
        "media.generate_storyboard",
        "media.package_hls_audio",
        "media.transcode_h264_ladder",
        "media.transcode_audio",
        "media.transcode_video",
        "media.package_hls_variant"
      ]
    ]

  defp fair_queue_filters(:flow_low), do: [priorities: ["low", "background"]]
  defp fair_queue_filters(_queue), do: []

  defp maybe_lock_fair_queue_global!(queue, config) do
    if Keyword.has_key?(config, :global_concurrency) or
         Keyword.has_key?(config, :background_concurrency) or
         Keyword.has_key?(config, :step_type_concurrency) do
      {:ok, _result} =
        Repo.query("SELECT pg_advisory_xact_lock(hashtext($1))", [
          "flow_fair_queue:#{fair_queue_family(queue)}:global"
        ])
    end
  end

  defp lock_fair_queue_space!(queue, space_hash) do
    {:ok, _result} =
      Repo.query("SELECT pg_advisory_xact_lock(hashtext($1))", [
        "flow_fair_queue:#{fair_queue_family(queue)}:#{space_hash}"
      ])
  end

  defp maybe_lock_fair_queue_run!(queue, config, flow_run_id) do
    if Keyword.has_key?(config, :run_concurrency) do
      {:ok, _result} =
        Repo.query("SELECT pg_advisory_xact_lock(hashtext($1))", [
          "flow_fair_queue:#{fair_queue_family(queue)}:run:#{flow_run_id}"
        ])
    end
  end

  defp fair_queue_family(:flow_booster_background), do: :flow_booster
  defp fair_queue_family(queue), do: queue

  defp active_fair_queue_steps(space_hash, filters, exclude_step, flow_run_id \\ nil) do
    StepRun
    |> join(:inner, [step_run], run in Run, on: run.id == step_run.flow_run_id)
    |> where([step_run, _run], step_run.status == "executing")
    |> where([_step_run, run], run.status in ["queued", "running"])
    |> maybe_filter_fair_queue_run(flow_run_id)
    |> maybe_filter_fair_queue_space(space_hash)
    |> maybe_filter_fair_queue_priorities(Keyword.get(filters, :priorities))
    |> maybe_filter_fair_queue_step_types(Keyword.get(filters, :step_types))
    |> maybe_filter_fair_queue_execution_queues(Keyword.get(filters, :execution_queues))
    |> maybe_exclude_fair_queue_step(exclude_step)
    |> Repo.aggregate(:count)
  end

  defp maybe_filter_fair_queue_run(query, flow_run_id) when is_binary(flow_run_id) do
    where(query, [step_run, _run], step_run.flow_run_id == ^flow_run_id)
  end

  defp maybe_filter_fair_queue_run(query, _flow_run_id), do: query

  defp maybe_filter_fair_queue_space(query, space_hash)
       when is_binary(space_hash) and space_hash != "" do
    where(query, [_step_run, run], fragment("?->>'space_hash'", run.input) == ^space_hash)
  end

  defp maybe_filter_fair_queue_space(query, _space_hash), do: query

  defp maybe_filter_fair_queue_priorities(query, priorities)
       when is_list(priorities) and priorities != [] do
    where(query, [_step_run, run], fragment("?->>'priority'", run.input) in ^priorities)
  end

  defp maybe_filter_fair_queue_priorities(query, _priorities), do: query

  defp maybe_filter_fair_queue_step_types(query, step_types)
       when is_list(step_types) and step_types != [] do
    where(query, [step_run, _run], step_run.step_type in ^step_types)
  end

  defp maybe_filter_fair_queue_step_types(query, _step_types), do: query

  defp maybe_filter_fair_queue_execution_queues(query, queues)
       when is_list(queues) and queues != [] do
    where(
      query,
      [step_run, _run],
      fragment("?->>'queue'", step_run.execution_metadata) in ^queues
    )
  end

  defp maybe_filter_fair_queue_execution_queues(query, _queues), do: query

  defp maybe_exclude_fair_queue_step(query, {flow_run_id, step_id})
       when is_binary(flow_run_id) and is_binary(step_id) do
    where(
      query,
      [step_run, _run],
      not (step_run.flow_run_id == ^flow_run_id and step_run.step_id == ^step_id)
    )
  end

  defp maybe_exclude_fair_queue_step(query, _exclude_step), do: query

  defp load_run_for_retry(flow_run_id) do
    case Run |> Repo.get(flow_run_id) do
      nil -> Repo.rollback(:run_not_found)
      run -> Repo.preload(run, [:flow_version, :step_runs, :artifact_refs])
    end
  end

  defp ensure_retryable_run!(%Run{status: "cancelled"}) do
    Repo.rollback(:run_cancelled)
  end

  defp ensure_retryable_run!(%Run{}), do: :ok

  defp load_step_run_for_claim(flow_run_id, step_id) do
    StepRun
    |> where([sr], sr.flow_run_id == ^flow_run_id and sr.step_id == ^step_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> case do
      nil -> Repo.rollback(:step_not_found)
      step_run -> step_run
    end
  end

  defp claim_step_run(%StepRun{status: "succeeded"}, _run, _flow_run_id, _step_id, _opts) do
    :already_succeeded
  end

  defp claim_step_run(%StepRun{status: "failed"}, _run, _flow_run_id, _step_id, _opts) do
    Repo.rollback(:step_failed)
  end

  defp claim_step_run(%StepRun{status: "skipped"}, _run, _flow_run_id, _step_id, _opts) do
    Repo.rollback(:step_skipped)
  end

  defp claim_step_run(%StepRun{status: "cancelled"}, _run, _flow_run_id, _step_id, _opts) do
    Repo.rollback(:step_cancelled)
  end

  defp claim_step_run(%StepRun{status: "executing"} = step_run, run, flow_run_id, step_id, opts) do
    if oban_retry_attempt?(opts) do
      claim_step_run(
        %{step_run | status: "scheduled", started_at: nil},
        run,
        flow_run_id,
        step_id,
        opts
      )
    else
      Repo.rollback(:already_executing)
    end
  end

  defp claim_step_run(%StepRun{} = step_run, %Run{} = run, flow_run_id, step_id, opts) do
    if execution_attempts_exhausted?(step_run) do
      {:automatic_attempts_exhausted, mark_execution_attempts_exhausted!(step_run)}
    else
      claimed_at = now_utc()
      step_definition = fetch_step_definition!(run.flow_version.definition, step_id)
      dependency_ids = Definition.dependencies(step_definition)
      ensure_dependencies_satisfied!(run.flow_version.definition, flow_run_id, dependency_ids)

      build_step_execution(
        run,
        step_run,
        step_definition,
        flow_run_id,
        dependency_ids,
        claimed_at,
        opts
      )
    end
  end

  defp fetch_step_definition!(definition, step_id) do
    case Definition.step_by_id(definition, step_id) do
      nil -> Repo.rollback(:invalid_step_definition)
      step_definition -> step_definition
    end
  end

  defp ensure_dependencies_satisfied!(definition, flow_run_id, dependency_ids) do
    if dependencies_satisfied?(definition, flow_run_id, dependency_ids) do
      :ok
    else
      Repo.rollback(:dependencies_not_ready)
    end
  end

  defp build_step_execution(
         %Run{} = run,
         %StepRun{} = step_run,
         step_definition,
         flow_run_id,
         dependency_ids,
         claimed_at,
         opts
       ) do
    updated_step_run =
      step_run
      |> StepRun.changeset(%{
        status: "executing",
        attempt: step_run.attempt + 1,
        started_at: step_run.started_at || claimed_at,
        completed_at: nil,
        error: nil,
        execution_metadata:
          step_run
          |> record_execution_attempt()
          |> put_execution_queue(opts)
      })
      |> Repo.update!()

    Events.broadcast_updated(flow_run_id, %{
      "step_status" => "executing",
      "step_type" => updated_step_run.step_type
    })

    %{
      run: run,
      step_run: updated_step_run,
      step_definition: step_definition,
      dependency_outputs: load_dependency_outputs(flow_run_id, dependency_ids),
      dependency_artifacts: load_dependency_artifacts(flow_run_id, dependency_ids),
      previous_status: step_run.status,
      queue_wait_ms: queue_wait_ms(step_run, claimed_at)
    }
  end

  defp execution_attempts_exhausted?(%StepRun{} = step_run) do
    execution_cycle_attempts(step_run) >= execution_attempt_limit(step_run)
  end

  defp mark_execution_attempts_exhausted!(%StepRun{} = step_run) do
    attempts = execution_cycle_attempts(step_run)
    max_attempts = execution_attempt_limit(step_run)

    step_run
    |> StepRun.changeset(%{
      status: "failed",
      completed_at: now_utc(),
      error:
        "automatic execution attempts exhausted (#{attempts}/#{max_attempts}); retry manually to continue",
      execution_metadata:
        put_retry_policy_metadata(step_run.execution_metadata, %{
          "cycle_attempts" => attempts,
          "max_execution_attempts" => max_attempts,
          "exhausted" => true
        })
    })
    |> Repo.update!()
  end

  defp record_execution_attempt(%StepRun{} = step_run) do
    max_attempts = execution_attempt_limit(step_run)

    step_run.execution_metadata
    |> then(&if(is_map(&1), do: &1, else: %{}))
    |> remember_previous_retry(step_run.error)
    |> Map.delete("retry")
    |> put_retry_policy_metadata(%{
      "cycle_attempts" => execution_cycle_attempts(step_run) + 1,
      "max_execution_attempts" => max_attempts,
      "orphan_recoveries" => orphan_recovery_count(step_run),
      "max_orphan_recoveries" => max_orphan_recoveries(),
      "exhausted" => false
    })
  end

  defp remember_previous_retry(metadata, error) do
    case Map.get(metadata, "retry") do
      %{} = retry ->
        retry =
          if is_binary(error) and error != "", do: Map.put(retry, "error", error), else: retry

        Map.put(metadata, "last_retry", retry)

      _other ->
        metadata
    end
  end

  defp mark_progress_queued(metadata) do
    case Map.get(metadata, "progress") do
      %{} = progress -> Map.put(metadata, "progress", Map.put(progress, "status", "queued"))
      _other -> metadata
    end
  end

  defp put_execution_queue(metadata, opts) when is_map(metadata) and is_list(opts) do
    case Keyword.get(opts, :fair_queue) do
      queue when is_atom(queue) -> Map.put(metadata, "queue", Atom.to_string(queue))
      queue when is_binary(queue) and queue != "" -> Map.put(metadata, "queue", queue)
      _other -> metadata
    end
  end

  defp execution_cycle_attempts(%StepRun{} = step_run) do
    case get_in(step_run.execution_metadata || %{}, ["retry_policy", "cycle_attempts"]) do
      attempts when is_integer(attempts) and attempts >= 0 -> attempts
      _other -> step_run.attempt || 0
    end
  end

  defp execution_attempt_limit(%StepRun{} = step_run) do
    metadata = step_run.execution_metadata || %{}

    case get_in(metadata, ["retry", "max_attempts"]) ||
           get_in(metadata, ["retry_policy", "max_execution_attempts"]) do
      attempts when is_integer(attempts) and attempts > 0 -> attempts
      _other -> max_execution_attempts()
    end
  end

  defp orphan_recovery_count(%StepRun{} = step_run) do
    metadata = step_run.execution_metadata || %{}

    case get_in(metadata, ["retry_policy", "orphan_recoveries"]) do
      recoveries when is_integer(recoveries) and recoveries >= 0 ->
        recoveries

      _other ->
        case get_in(metadata, ["recovery", "reason"]) do
          "orphaned_executing_step" -> 1
          _other -> 0
        end
    end
  end

  defp put_retry_policy_metadata(metadata, attrs) when is_map(attrs) do
    metadata = if is_map(metadata), do: metadata, else: %{}

    policy =
      case Map.get(metadata, "retry_policy") do
        %{} = existing -> Map.merge(existing, attrs)
        _other -> attrs
      end

    Map.put(metadata, "retry_policy", policy)
  end

  defp max_execution_attempts do
    :mave_core
    |> Application.get_env(:flow_step_retry_policy, [])
    |> Keyword.get(:max_execution_attempts, @default_max_execution_attempts)
    |> positive_integer(@default_max_execution_attempts)
  end

  defp max_orphan_recoveries do
    :mave_core
    |> Application.get_env(:flow_step_retry_policy, [])
    |> Keyword.get(:max_orphan_recoveries, @default_max_orphan_recoveries)
    |> non_negative_integer(@default_max_orphan_recoveries)
  end

  defp oban_retry_attempt?(opts) do
    case Keyword.get(opts, :oban_attempt) do
      attempt when is_integer(attempt) -> attempt > 1
      _ -> false
    end
  end

  defp retry_subtree_step_runs(step_runs, subtree_step_ids) do
    Enum.filter(step_runs, fn step_run -> step_run.step_id in subtree_step_ids end)
  end

  defp ensure_retryable_subtree!([]) do
    Repo.rollback(:step_not_found)
  end

  defp ensure_retryable_subtree!(subtree_step_runs) do
    if Enum.any?(subtree_step_runs, &(&1.status == "executing")) do
      Repo.rollback(:subtree_in_progress)
    end
  end

  defp reset_subtree_step_runs(flow_run_id, subtree_step_ids) do
    retry_policy = %{
      "retry_policy" => %{
        "cycle_attempts" => 0,
        "orphan_recoveries" => 0,
        "max_execution_attempts" => max_execution_attempts(),
        "max_orphan_recoveries" => max_orphan_recoveries(),
        "reset" => "manual"
      }
    }

    StepRun
    |> where(
      [step_run],
      step_run.flow_run_id == ^flow_run_id and step_run.step_id in ^subtree_step_ids
    )
    |> Repo.update_all(
      set: [
        status: "queued",
        output: nil,
        error: nil,
        completed_at: nil,
        scheduled_at: nil,
        started_at: nil,
        execution_metadata: retry_policy
      ]
    )
  end

  defp delete_subtree_artifacts(flow_run_id, subtree_step_ids) do
    ArtifactRef
    |> where(
      [artifact],
      artifact.flow_run_id == ^flow_run_id and artifact.producer_step_id in ^subtree_step_ids
    )
    |> Repo.delete_all()
  end

  defp restart_run(%Run{} = run) do
    run
    |> Run.changeset(%{
      status: "running",
      completed_at: nil,
      error: nil,
      started_at: run.started_at || now_utc()
    })
    |> Repo.update!()
  end

  defp replace_step_artifacts(flow_run_id, producer_step_id, artifacts) do
    ArtifactRef
    |> where(
      [artifact],
      artifact.flow_run_id == ^flow_run_id and artifact.producer_step_id == ^producer_step_id
    )
    |> Repo.delete_all()

    Enum.each(artifacts, &insert_artifact_ref(flow_run_id, producer_step_id, &1))
  end

  defp insert_artifact_ref(flow_run_id, producer_step_id, artifact) do
    %ArtifactRef{}
    |> ArtifactRef.changeset(%{
      flow_run_id: flow_run_id,
      producer_step_id: producer_step_id,
      name: Map.get(artifact, :name) || Map.get(artifact, "name"),
      uri: Map.get(artifact, :uri) || Map.get(artifact, "uri"),
      media_type: Map.get(artifact, :media_type) || Map.get(artifact, "media_type"),
      size_bytes: Map.get(artifact, :size_bytes) || Map.get(artifact, "size_bytes"),
      metadata: Map.get(artifact, :metadata) || Map.get(artifact, "metadata") || %{}
    })
    |> Repo.insert!()
  end

  defp normalize_step_error(reason) do
    reason
    |> inspect(limit: 100, printable_limit: 500)
    |> String.slice(0, 255)
  end

  defp mark_blocked_steps(%Run{} = run) do
    step_runs_by_id = Map.new(run.step_runs, fn step_run -> {step_run.step_id, step_run} end)

    run.flow_version.definition
    |> Definition.blocked_steps(step_runs_by_id)
    |> Enum.each(fn step_definition ->
      step_run = Map.fetch!(step_runs_by_id, step_definition["id"])
      skip? = not Definition.required?(step_definition)

      blocked_by =
        blocked_dependency_id(run.flow_version.definition, step_runs_by_id, step_definition)

      attrs =
        if skip? do
          %{
            status: "skipped",
            output: skipped_step_output(step_run.step_id, blocked_by),
            error: blocked_step_error(blocked_by),
            completed_at: now_utc()
          }
        else
          %{
            status: "failed",
            error: blocked_step_error(blocked_by),
            completed_at: now_utc()
          }
        end

      step_run
      |> StepRun.changeset(attrs)
      |> Repo.update!()
    end)

    run
  end

  defp required_step_failed?(%Run{} = run) do
    step_runs_by_id = Map.new(run.step_runs, fn step_run -> {step_run.step_id, step_run} end)

    Enum.any?(Definition.steps(run.flow_version.definition), fn step_definition ->
      Definition.required?(step_definition) and
        match?(%{status: "failed"}, Map.get(step_runs_by_id, step_definition["id"]))
    end)
  end

  defp run_complete?(%Run{} = run) do
    run.step_runs != [] and Enum.all?(run.step_runs, &Definition.terminal_step_status?(&1.status))
  end

  defp blocked_dependency_id(definition, step_runs_by_id, step_definition) do
    Enum.find(Definition.dependencies(step_definition), fn dependency_id ->
      case Map.get(step_runs_by_id, dependency_id) do
        %{status: status} ->
          Definition.terminal_step_status?(status) and
            not dependency_satisfied?(definition, step_runs_by_id, dependency_id)

        _ ->
          false
      end
    end)
  end

  defp dependency_satisfied?(definition, step_runs_by_id, dependency_id) do
    case Map.get(step_runs_by_id, dependency_id) do
      "succeeded" ->
        true

      status when is_binary(status) ->
        definition
        |> Definition.step_by_id(dependency_id)
        |> Definition.required?()
        |> Kernel.not() and Definition.terminal_step_status?(status)

      %{status: "succeeded"} ->
        true

      %{status: status} ->
        definition
        |> Definition.step_by_id(dependency_id)
        |> Definition.required?()
        |> Kernel.not() and Definition.terminal_step_status?(status)

      _ ->
        false
    end
  end

  defp blocked_step_error(blocked_by) when is_binary(blocked_by),
    do: "blocked by dependency #{blocked_by}"

  defp blocked_step_error(_), do: "blocked by failed dependency"

  defp skipped_step_output(step_id, blocked_by) do
    %{
      "status" => "skipped",
      "step_id" => step_id,
      "reason" => blocked_step_error(blocked_by)
    }
  end

  defp dependencies_satisfied?(_definition, _flow_run_id, []), do: true

  defp dependencies_satisfied?(definition, flow_run_id, dependency_ids) do
    statuses =
      StepRun
      |> where([sr], sr.flow_run_id == ^flow_run_id and sr.step_id in ^dependency_ids)
      |> select([sr], {sr.step_id, sr.status})
      |> Repo.all()
      |> Map.new()

    Enum.all?(dependency_ids, fn dependency_id ->
      dependency_satisfied?(definition, statuses, dependency_id)
    end)
  end

  defp load_dependency_outputs(flow_run_id, dependency_ids) do
    direct_dependency_ids = Enum.uniq(dependency_ids)

    ambient_dependency_ids =
      @ambient_dependency_output_step_ids -- direct_dependency_ids

    StepRun
    |> where([sr], sr.flow_run_id == ^flow_run_id)
    |> where(
      [sr],
      sr.step_id in ^direct_dependency_ids or
        (sr.step_id in ^ambient_dependency_ids and sr.status == "succeeded" and
           not is_nil(sr.output))
    )
    |> select([sr], {sr.step_id, sr.output})
    |> Repo.all()
    |> Map.new(fn {step_id, output} -> {step_id, output || %{}} end)
  end

  defp load_dependency_artifacts(_flow_run_id, []), do: %{}

  defp load_dependency_artifacts(flow_run_id, dependency_ids) do
    ArtifactRef
    |> where(
      [artifact],
      artifact.flow_run_id == ^flow_run_id and artifact.producer_step_id in ^dependency_ids
    )
    |> Repo.all()
    |> Enum.group_by(& &1.producer_step_id, fn artifact ->
      %{
        "name" => artifact.name,
        "uri" => artifact.uri,
        "media_type" => artifact.media_type,
        "size_bytes" => artifact.size_bytes,
        "metadata" => artifact.metadata
      }
    end)
  end

  defp ensure_running(run) do
    if run.status == "running" do
      run
    else
      run
      |> Run.changeset(%{status: "running", started_at: run.started_at || now_utc()})
      |> Repo.update!()
    end
  end

  defp maybe_enqueue_ready_webhooks_for_step(flow_run_id, output)
       when is_binary(flow_run_id) and is_map(output) do
    completed_renditions = completed_step_renditions(output)
    ready_renditions = Enum.filter(completed_renditions, &ready_webhook_rendition?/1)

    with true <- completed_renditions != [] or hls_master_output?(output),
         %Run{input: %{"space_hash" => space_hash, "embed_hash" => embed_hash}} = run <-
           Repo.get(Run, flow_run_id),
         step_runs when is_list(step_runs) <- list_step_runs(flow_run_id),
         %Embed{} = embed <- Embeds.get_embed_by_hashes(space_hash, embed_hash),
         %Video{} = video <- run_video(run, embed) do
      before_sizes = ready_video_size_set(video.id)
      durable_original = uploaded_original_output(step_runs) || %{}

      upsert_rendition_rows(video.id, completed_renditions)

      if current_run_video?(embed, video) do
        maybe_publish_upload_rendition_manifest(
          embed,
          output,
          completed_renditions,
          durable_original
        )
      end

      output
      |> upload_rendition_payloads(video.id, ready_renditions)
      |> broadcast_upload_renditions(run)

      new_sizes =
        ready_renditions
        |> Enum.map(& &1["size"])
        |> Enum.uniq()
        |> Enum.reject(&MapSet.member?(before_sizes, &1))

      if new_sizes != [] and current_run_video?(embed, video) do
        maybe_publish_ready_manifest(embed, durable_original)
        enqueue_ready_webhook_events(embed, new_sizes)
      end
    else
      _ -> :ok
    end
  end

  defp maybe_enqueue_ready_webhooks_for_step(_flow_run_id, _output), do: :ok

  defp hls_master_output?(%{"status" => "ok", "step_type" => "media.build_hls_master"}), do: true
  defp hls_master_output?(_output), do: false

  defp maybe_publish_upload_rendition_manifest(
         %Embed{} = embed,
         output,
         renditions,
         durable_original
       )
       when is_map(output) and is_list(renditions) and is_map(durable_original) do
    cond do
      hls_master_output?(output) ->
        maybe_publish_ready_manifest(embed, Map.put(durable_original, "hls_ready", true))

      Enum.any?(renditions, &non_hls_video_rendition?/1) ->
        maybe_publish_ready_manifest(embed, durable_original)

      renditions != [] ->
        maybe_publish_completed_manifest(embed, durable_original)

      true ->
        :ok
    end
  end

  defp upload_rendition_payloads(output, video_id, _ready_renditions)
       when is_binary(video_id) do
    if hls_master_output?(output) do
      hls_upload_rendition_payloads(video_id)
    else
      output
      |> ready_webhook_renditions()
      |> Enum.reject(&hls_video_rendition?/1)
      |> rendition_payloads(video_id)
    end
  end

  defp hls_video_rendition?(%{"type" => "video", "container" => "hls"}), do: true
  defp hls_video_rendition?(_rendition), do: false

  defp non_hls_video_rendition?(%{"type" => "video"} = rendition),
    do: not hls_video_rendition?(rendition)

  defp non_hls_video_rendition?(_rendition), do: false

  defp hls_upload_rendition_payloads(video_id) do
    from(r in "renditions",
      where: r.video_id == type(^video_id, MaveCore.Ecto.LegacyShortUUID),
      where: r.type == "video" and r.container == "hls" and r.progress >= 100,
      where: r.size in ^@db_rendition_sizes,
      select: %{
        id: type(r.id, MaveCore.Ecto.LegacyShortUUID),
        type: r.type,
        codec: r.codec,
        container: r.container,
        size: r.size,
        file_size: r.file_size
      }
    )
    |> Repo.all()
  end

  defp rendition_payloads(renditions, video_id)
       when is_binary(video_id) and is_list(renditions) do
    rendition_keys =
      renditions
      |> Enum.map(& &1["rendition_key"])
      |> Enum.filter(&is_binary/1)

    from(r in "renditions",
      where:
        r.video_id == type(^video_id, MaveCore.Ecto.LegacyShortUUID) and
          r.rendition_key in ^rendition_keys,
      select: %{
        id: type(r.id, MaveCore.Ecto.LegacyShortUUID),
        type: r.type,
        codec: r.codec,
        container: r.container,
        size: r.size,
        file_size: r.file_size
      }
    )
    |> Repo.all()
  end

  defp broadcast_upload_renditions(payloads, %Run{input: %{"upload_id" => upload_id}})
       when is_binary(upload_id) and is_list(payloads) do
    Enum.each(payloads, &UploadEvents.broadcast(:rendition, &1, upload_id))
  end

  defp broadcast_upload_renditions(_payloads, _run), do: :ok

  defp ready_webhook_renditions(%{"status" => "ok", "renditions" => renditions})
       when is_list(renditions) do
    Enum.filter(renditions, &ready_webhook_rendition?/1)
  end

  defp ready_webhook_renditions(_output), do: []

  defp ready_webhook_rendition?(%{"type" => "video", "size" => size} = rendition)
       when size in @db_rendition_sizes do
    progress = float_value(rendition["progress"]) || 0.0
    progress >= 100.0
  end

  defp ready_webhook_rendition?(_rendition), do: false

  defp completed_step_renditions(%{"status" => "ok", "renditions" => renditions})
       when is_list(renditions) do
    Enum.filter(renditions, &completed_step_rendition?/1)
  end

  defp completed_step_renditions(_output), do: []

  defp completed_step_rendition?(%{"rendition_key" => key} = rendition)
       when is_binary(key) and key != "" do
    progress = float_value(rendition["progress"]) || 0.0
    progress >= 100.0 and not is_nil(db_rendition_type(rendition))
  end

  defp completed_step_rendition?(_rendition), do: false

  defp ready_video_size_set(video_id) when is_binary(video_id) do
    from(r in "renditions",
      where: r.video_id == type(^video_id, MaveCore.Ecto.LegacyShortUUID),
      where: r.type == "video" and r.progress >= 100,
      where: r.size in ^@db_rendition_sizes,
      select: r.size
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp upsert_rendition_rows(video_id, renditions) when is_binary(video_id) do
    video_id_db = MaveCore.LegacyShortUUID.dump!(video_id)
    now = now_utc()

    custom_thumbnail_keys =
      from(r in "renditions",
        where: r.video_id == type(^video_id, MaveCore.Ecto.LegacyShortUUID),
        where: r.type == "custom_thumbnail",
        select: r.rendition_key
      )
      |> Repo.all()
      |> MapSet.new()

    rows =
      renditions
      |> Enum.map(&build_rendition_row(video_id_db, &1, now))
      |> Enum.reject(fn row ->
        is_nil(row) or
          (row.type != "custom_thumbnail" and
             MapSet.member?(custom_thumbnail_keys, row.rendition_key))
      end)
      |> Enum.uniq_by(& &1.rendition_key)
      |> reject_conflicting_rendition_owners(video_id)

    if rows != [] do
      Repo.insert_all("renditions", rows,
        on_conflict:
          {:replace, [:type, :codec, :container, :size, :progress, :file_size, :updated_at]},
        conflict_target: [:rendition_key]
      )
    end

    :ok
  end

  defp reject_conflicting_rendition_owners(rows, video_id) do
    rendition_keys = Enum.map(rows, & &1.rendition_key)

    existing_owners =
      Rendition
      |> where([rendition], rendition.rendition_key in ^rendition_keys)
      |> select([rendition], {rendition.rendition_key, rendition.video_id})
      |> Repo.all()
      |> Map.new()

    Enum.reject(rows, fn row ->
      case Map.get(existing_owners, row.rendition_key) do
        nil ->
          false

        ^video_id ->
          false

        conflicting_video_id ->
          Logger.warning(
            "Skipped rendition #{row.rendition_key} for video #{video_id}; " <>
              "it belongs to video #{conflicting_video_id}"
          )

          true
      end
    end)
  end

  defp maybe_publish_ready_manifest(%Embed{} = embed, updates) do
    updates = Map.put(updates, "status", "playable")

    case ManifestPublisher.publish(embed, updates) do
      {:ok, _manifest} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to publish ready-rendition manifest for embed #{embed.id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp maybe_publish_completed_manifest(%Embed{} = embed, updates) do
    case ManifestPublisher.publish(embed, updates) do
      {:ok, _manifest} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to publish completed-rendition manifest for embed #{embed.id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp enqueue_ready_webhook_events(%Embed{space: %Space{} = space} = embed, sizes) do
    Enum.each(sizes, fn _size ->
      case Spaces.enqueue_webhook_event_for_embed(
             space,
             embed,
             :video_ready,
             %{enqueue: true}
           ) do
        {:ok, _deliveries} ->
          :ok

        {:error, :not_found} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Failed to enqueue video_ready webhooks for #{space.hash}/#{embed.hash}: #{inspect(reason)}"
          )

          :ok
      end
    end)
  end

  defp insert_step_runs(flow_run_id, definition) do
    Definition.steps(definition)
    |> Enum.reduce_while(:ok, fn step, :ok ->
      attrs = %{
        flow_run_id: flow_run_id,
        step_id: step["id"],
        step_type: step["type"],
        status: "queued",
        attempt: 0,
        input: %{
          "inputs" => Map.get(step, "inputs", %{}),
          "params" => Map.get(step, "params", %{})
        }
      }

      case %StepRun{} |> StepRun.changeset(attrs) |> Repo.insert() do
        {:ok, _step_run} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp fetch_template(%Template{} = template), do: {:ok, template}

  defp fetch_template(selector) when is_binary(selector) do
    by_id =
      case LegacyShortUUID.cast(selector) do
        {:ok, id} -> Repo.get(Template, id)
        :error -> nil
      end

    case by_id || Repo.get_by(Template, slug: selector) do
      nil -> {:error, :template_not_found}
      template -> {:ok, template}
    end
  end

  defp fetch_template(_), do: {:error, :template_not_found}

  defp maybe_sync_builtin_preset(selector) when is_binary(selector) do
    case Presets.fetch(selector) do
      {:ok, _preset} ->
        with {:ok, _install} <- install_preset(selector), do: :ok

      {:error, :preset_not_found} ->
        :ok
    end
  end

  defp maybe_sync_builtin_preset(_selector), do: :ok

  defp fetch_version(template_id, opts) do
    case requested_version(opts) do
      :latest_active ->
        fetch_latest_active_version(template_id)

      {:ok, version_number} ->
        fetch_version_by_number(template_id, version_number)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp next_version_number(template_id) do
    current_max =
      Version
      |> where([v], v.flow_template_id == ^template_id)
      |> select([v], max(v.version))
      |> Repo.one()

    (current_max || 0) + 1
  end

  defp maybe_enqueue_coordinator(_flow_run_id, false), do: :ok

  defp maybe_enqueue_coordinator(flow_run_id, true) do
    case enqueue_coordinator(flow_run_id) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, {:enqueue_failed, reason}}
    end
  end

  defp enqueue_coordinator(flow_run_id) do
    %{flow_run_id: flow_run_id}
    |> FlowCoordinatorWorker.new()
    |> Oban.insert()
  end

  defp enqueue_step_job(%Run{} = run, step) do
    step_id = step["id"]

    %{flow_run_id: run.id, step_id: step_id}
    |> maybe_put_step_job_space_hash(run.input)
    |> FlowStepWorker.new(
      priority: flow_step_job_priority(run.input, step),
      queue: flow_step_job_queue(run.input, step)
    )
    |> Oban.insert()
  end

  defp maybe_put_step_job_space_hash(args, %{"space_hash" => space_hash})
       when is_binary(space_hash) and space_hash != "" do
    Map.put(args, :space_hash, space_hash)
  end

  defp maybe_put_step_job_space_hash(args, _input), do: args

  defp flow_step_job_queue(_input, %{"type" => step_type})
       when step_type in @source_preparation_step_types,
       do: :flow_steps

  defp flow_step_job_queue(
         input,
         %{
           "type" => "media.transcode_h264_ladder"
         } = step
       ) do
    cond do
      GpuEncodingBooster.eligible_step?(step) and
          GpuEncodingBooster.enabled?() ->
        booster_step_queue(step)

      EncodingBooster.enabled?() ->
        booster_step_queue(step)

      true ->
        default_media_step_queue(input, step)
    end
  end

  defp flow_step_job_queue(
         input,
         %{"type" => "media.package_hls_variant"} = step
       ) do
    if EncodingBooster.enabled?(),
      do: booster_step_queue(step),
      else: default_media_step_queue(input, step)
  end

  defp flow_step_job_queue(
         input,
         %{"type" => step_type} = step
       )
       when step_type in [
              "media.transcode_audio",
              "media.generate_audio_peaks",
              "media.extract_frame",
              "media.package_hls_audio",
              "media.generate_segments",
              "media.generate_storyboard"
            ] do
    if EncodingBooster.enabled?(),
      do: booster_step_queue(step),
      else: default_media_step_queue(input, step)
  end

  defp flow_step_job_queue(
         input,
         %{
           "type" => "media.transcode_video"
         } = step
       ) do
    cond do
      GpuEncodingBooster.eligible_step?(step) and
          GpuEncodingBooster.enabled?() ->
        booster_step_queue(step)

      EncodingBooster.enabled?() ->
        booster_step_queue(step)

      true ->
        default_media_step_queue(input, step)
    end
  end

  defp flow_step_job_queue(%{"priority" => priority}, %{"type" => step_type})
       when priority in ["low", :low] and step_type in @media_step_types,
       do: :flow_low

  defp flow_step_job_queue(%{"priority" => priority}, _step)
       when priority in ["background", :background],
       do: :flow_low

  defp flow_step_job_queue(%{"priority" => priority}, %{"type" => step_type})
       when priority in ["import", :import] and step_type in @import_finalizer_step_types,
       do: :flow_steps

  defp flow_step_job_queue(%{"priority" => priority}, _step)
       when priority in ["import", :import],
       do: :flow_imports

  defp flow_step_job_queue(_input, %{"type" => step_type, "lane" => "background"})
       when step_type in @media_step_types,
       do: :flow_low

  defp flow_step_job_queue(_input, %{"type" => step_type}) when step_type in @media_step_types,
    do: :flow_media

  defp flow_step_job_queue(_input, _step), do: :flow_steps

  defp booster_step_queue(%{"lane" => "background"}), do: :flow_booster_background
  defp booster_step_queue(_step), do: :flow_booster

  defp default_media_step_queue(%{"priority" => priority}, _step)
       when priority in ["import", :import],
       do: :flow_imports

  defp default_media_step_queue(%{"priority" => priority}, _step)
       when priority in ["low", :low, "background", :background],
       do: :flow_low

  defp default_media_step_queue(_input, %{"lane" => "background"}), do: :flow_low
  defp default_media_step_queue(_input, _step), do: :flow_media

  defp flow_step_job_priority(
         %{"durable_source_required" => true},
         %{"type" => step_type}
       )
       when step_type in @source_preparation_step_types,
       do: 0

  defp flow_step_job_priority(%{"priority" => priority}, %{"type" => step_type})
       when step_type in @source_preparation_step_types do
    case priority do
      value when value in ["high", :high, "urgent", :urgent] -> 0
      value when is_integer(value) -> min(max(value, 0), 9)
      _ -> 3
    end
  end

  defp flow_step_job_priority(_input, %{"lane" => "fast"}), do: 0

  defp flow_step_job_priority(%{"priority" => priority}, _step) do
    case priority do
      value when value in ["high", :high, "urgent", :urgent] -> 0
      value when value in ["normal", :normal, "default", :default] -> 3
      value when value in ["import", :import] -> 6
      value when value in ["low", :low, "background", :background] -> 9
      value when is_integer(value) -> min(max(value, 0), 9)
      _ -> 3
    end
  end

  defp flow_step_job_priority(_input, %{"type" => step_type, "lane" => "background"})
       when step_type in @media_step_types,
       do: 9

  defp flow_step_job_priority(_input, _step), do: 3

  defp maybe_finalize_video_run(
         %Run{
           input: %{"space_hash" => space_hash, "embed_hash" => embed_hash},
           step_runs: step_runs
         } = run
       )
       when is_binary(space_hash) and is_binary(embed_hash) do
    case Embeds.get_embed_by_hashes(space_hash, embed_hash) do
      %Embed{} = embed ->
        case run_video(run, embed) do
          %Video{} = video ->
            lock_video_asset!(video.asset_id)
            finalize_video_assets(video, step_runs)
            maybe_finalize_ready_embed(run, video, space_hash, embed_hash, step_runs)

          nil ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp maybe_finalize_video_run(_run), do: :ok

  defp lock_video_asset!(asset_id) when is_binary(asset_id) do
    Asset
    |> where([asset], asset.id == ^asset_id)
    |> lock("FOR UPDATE")
    |> Repo.one()

    :ok
  end

  defp persist_run_video_id(%{"space_hash" => space_hash, "embed_hash" => embed_hash} = input)
       when is_binary(space_hash) and is_binary(embed_hash) do
    case Embeds.get_embed_by_hashes(space_hash, embed_hash) do
      %Embed{} = embed ->
        case video_for_input(input, embed) do
          %Video{id: video_id} -> Map.put(input, "video_id", video_id)
          nil -> input
        end

      nil ->
        input
    end
  end

  defp persist_run_video_id(input), do: input

  defp run_video(%Run{input: input}, %Embed{} = embed) when is_map(input) do
    video_for_input(input, embed)
  end

  defp run_video(_run, _embed), do: nil

  defp video_for_input(input, %Embed{} = embed) when is_map(input) do
    video_by_input_id(input, embed.asset_id) ||
      fallback_video_for_input(input, embed)
  end

  defp fallback_video_for_input(%{"version" => _version} = input, %Embed{} = embed) do
    video_by_input_version(input, embed.asset_id)
  end

  defp fallback_video_for_input(_input, %Embed{} = embed), do: current_embed_video(embed)

  defp video_by_input_id(%{"video_id" => video_id}, asset_id)
       when is_binary(video_id) and is_binary(asset_id) do
    case Repo.get(Video, video_id) do
      %Video{asset_id: ^asset_id} = video -> video
      _other -> nil
    end
  end

  defp video_by_input_id(_input, _asset_id), do: nil

  defp video_by_input_version(%{"version" => version}, asset_id) when is_binary(asset_id) do
    case parse_video_version(version) do
      version when is_integer(version) ->
        Video
        |> where([video], video.asset_id == ^asset_id)
        |> order_by([video], asc: video.inserted_at, asc: video.id)
        |> offset(^version)
        |> limit(1)
        |> Repo.one()

      nil ->
        nil
    end
  end

  defp video_by_input_version(_input, _asset_id), do: nil

  defp parse_video_version(version) when is_integer(version) and version >= 0, do: version

  defp parse_video_version(version) when is_binary(version) do
    case Integer.parse(version) do
      {parsed, ""} when parsed >= 0 -> parsed
      _other -> nil
    end
  end

  defp parse_video_version(_version), do: nil

  defp current_embed_video(%Embed{asset: %{current_video: %Video{} = video}}), do: video
  defp current_embed_video(_embed), do: nil

  defp current_run_video?(%Embed{asset: %{current_video_id: video_id}}, %Video{id: video_id}),
    do: true

  defp current_run_video?(_embed, _video), do: false

  defp maybe_broadcast_reconciled_run({:ok, %Run{status: "succeeded"} = run} = result) do
    maybe_broadcast_ready_embed_update(run)
    result
  end

  defp maybe_broadcast_reconciled_run(result), do: result

  defp maybe_cancel_terminal_step_jobs({:ok, %Run{status: status} = run} = result)
       when status in ["succeeded", "failed", "cancelled"] do
    cancel_step_jobs(run.id, Enum.map(run.step_runs, & &1.step_id))
    result
  end

  defp maybe_cancel_terminal_step_jobs(result), do: result

  defp maybe_broadcast_flow_run({:ok, %Run{} = run} = result) do
    Events.broadcast_updated(run.id, %{"status" => run.status})
    result
  end

  defp maybe_broadcast_flow_run(result), do: result

  defp maybe_broadcast_ready_embed_update(%Run{
         input: %{"space_hash" => space_hash, "embed_hash" => embed_hash}
       })
       when is_binary(space_hash) and is_binary(embed_hash) do
    case Embeds.get_embed_by_hashes(space_hash, embed_hash) do
      %Embed{} = embed ->
        EmbedEvents.broadcast_updated(embed.space_id, embed.id, %{"status" => "ready"})

      _ ->
        :ok
    end
  end

  defp maybe_broadcast_ready_embed_update(_run), do: :ok

  defp reset_step_subtree(flow_run_id, step_id) do
    Repo.transaction(fn ->
      run = load_run_for_retry(flow_run_id)
      run = promote_recovery_source!(run)
      ensure_retryable_run!(run)
      definition = run.flow_version.definition || %{}
      _ = fetch_step_definition!(definition, step_id)

      subtree_step_ids = retry_subtree_step_ids(definition, step_id)
      subtree_step_runs = retry_subtree_step_runs(run.step_runs, subtree_step_ids)

      ensure_retryable_subtree!(subtree_step_runs)
      reset_subtree_step_runs(flow_run_id, subtree_step_ids)
      delete_subtree_artifacts(flow_run_id, subtree_step_ids)
      restart_run(run)
      cancel_step_jobs(flow_run_id, subtree_step_ids)

      reload_run(run)
    end)
    |> unwrap_transaction()
  end

  defp reset_recoverable_subtrees(flow_run_id) do
    Repo.transaction(fn ->
      run = load_run_for_retry(flow_run_id)
      run = promote_recovery_source!(run)
      ensure_retryable_run!(run)
      definition = run.flow_version.definition || %{}

      recovery_root_step_ids =
        definition
        |> recoverable_root_step_ids(run.step_runs)
        |> Kernel.++(interrupted_recovery_root_step_ids(run))
        |> Enum.uniq()
        |> prune_redundant_recovery_roots(definition)

      if recovery_root_step_ids == [] do
        Repo.rollback(:nothing_to_recover)
      end

      subtree_step_ids =
        recovery_root_step_ids
        |> Enum.flat_map(&retry_subtree_step_ids(definition, &1))
        |> Enum.uniq()

      subtree_step_runs = retry_subtree_step_runs(run.step_runs, subtree_step_ids)

      ensure_recoverable_subtree!(run, subtree_step_runs)
      reset_subtree_step_runs(flow_run_id, subtree_step_ids)
      delete_subtree_artifacts(flow_run_id, subtree_step_ids)
      restart_run(run)
      cancel_step_jobs(flow_run_id, subtree_step_ids)

      reload_run(run)
    end)
    |> unwrap_transaction()
  end

  defp cancel_run(%Run{} = run) do
    now = now_utc()

    StepRun
    |> where([step_run], step_run.flow_run_id == ^run.id)
    |> where([step_run], step_run.status in ["queued", "scheduled", "executing"])
    |> Repo.update_all(
      set: [
        status: "cancelled",
        completed_at: now,
        error: "embed deleted"
      ]
    )

    run
    |> Run.changeset(%{
      status: "cancelled",
      completed_at: now,
      error: "embed deleted"
    })
    |> Repo.update!()

    cancel_run_jobs(run.id)
  end

  defp cancel_run_jobs(flow_run_id) when is_binary(flow_run_id) do
    Job
    |> where(
      [job],
      job.worker in [^worker_name(FlowCoordinatorWorker), ^worker_name(FlowStepWorker)]
    )
    |> where([job], job.state in ["available", "scheduled", "retryable", "executing"])
    |> where([job], fragment("?->>'flow_run_id' = ?", job.args, ^flow_run_id))
    |> Repo.all()
    |> Enum.each(fn job ->
      _ = Oban.cancel_job(job)
    end)

    :ok
  end

  defp cancel_step_jobs(flow_run_id, step_ids)
       when is_binary(flow_run_id) and is_list(step_ids) do
    Job
    |> where([job], job.worker == ^worker_name(FlowStepWorker))
    |> where([job], job.state in ["available", "scheduled", "retryable", "executing"])
    |> where([job], fragment("?->>'flow_run_id' = ?", job.args, ^flow_run_id))
    |> where(
      [job],
      fragment("?->>'step_id' = ANY(?)", job.args, type(^step_ids, {:array, :string}))
    )
    |> Repo.all()
    |> Enum.each(fn job ->
      _ = Oban.cancel_job(job)
    end)

    :ok
  end

  defp cancel_step_jobs(_flow_run_id, _step_ids), do: :ok

  defp stale_step_cutoff(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    older_than_ms = Keyword.get(opts, :older_than_ms, configured_stale_step_older_than_ms())
    DateTime.add(now, -older_than_ms, :millisecond)
  end

  defp configured_stale_step_older_than_ms do
    :mave_core
    |> Application.get_env(:flow_stale_step_recovery, [])
    |> Keyword.get(:older_than_ms, 5 * 60 * 1000)
    |> positive_integer(5 * 60 * 1000)
  end

  defp stale_step_recovery_limit(opts) do
    opts
    |> Keyword.get(:limit, configured_stale_step_recovery_limit())
    |> positive_integer(25)
  end

  defp configured_stale_step_recovery_limit do
    :mave_core
    |> Application.get_env(:flow_stale_step_recovery, [])
    |> Keyword.get(:limit, 25)
    |> positive_integer(25)
  end

  defp stale_executing_step_candidates(cutoff, limit) do
    StepRun
    |> join(:inner, [step_run], run in Run, on: run.id == step_run.flow_run_id)
    |> where(
      [step_run, run],
      step_run.status == "executing" and run.status in ["queued", "running"]
    )
    |> where(
      [step_run, _run],
      step_run.started_at < ^cutoff or
        (is_nil(step_run.started_at) and step_run.updated_at < ^cutoff)
    )
    |> order_by([step_run, _run], asc: step_run.started_at, asc: step_run.updated_at)
    |> limit(^limit)
    |> select([step_run, _run], %{
      flow_run_id: step_run.flow_run_id,
      step_id: step_run.step_id,
      step_run_id: step_run.id
    })
    |> Repo.all()
  end

  defp stale_nonexecuting_run_candidates(cutoff, limit) do
    scan_limit = max(limit * 10, limit)

    StepRun
    |> join(:inner, [step_run], run in Run, on: run.id == step_run.flow_run_id)
    |> where(
      [step_run, run],
      step_run.status in ["queued", "scheduled"] and run.status in ["queued", "running"]
    )
    |> where([step_run, _run], step_run.updated_at < ^cutoff)
    |> group_by([step_run, _run], step_run.flow_run_id)
    |> order_by([step_run, _run], asc: min(step_run.updated_at))
    |> limit(^scan_limit)
    |> select([step_run, _run], step_run.flow_run_id)
    |> Repo.all()
  end

  defp reconcile_stale_nonexecuting_run(flow_run_id, counts) do
    if stale_nonexecuting_run?(flow_run_id) do
      case reconcile_run(flow_run_id) do
        {:ok, _run} ->
          Map.update!(counts, :reconciled, &(&1 + 1))

        {:error, reason} ->
          Logger.warning(
            "Failed to reconcile stale non-executing flow run #{flow_run_id}: #{inspect(reason)}"
          )

          Map.update!(counts, :errors, &(&1 + 1))
      end
    else
      Map.update!(counts, :skipped, &(&1 + 1))
    end
  end

  defp stale_nonexecuting_run?(flow_run_id) do
    if executing_step?(flow_run_id) do
      false
    else
      case scheduled_steps(flow_run_id) do
        [] -> queued_step?(flow_run_id)
        step_runs -> Enum.any?(step_runs, &(not active_step_job?(flow_run_id, &1.step_id)))
      end
    end
  end

  defp executing_step?(flow_run_id) do
    Repo.exists?(
      from step_run in StepRun,
        where: step_run.flow_run_id == ^flow_run_id and step_run.status == "executing"
    )
  end

  defp queued_step?(flow_run_id) do
    Repo.exists?(
      from step_run in StepRun,
        where: step_run.flow_run_id == ^flow_run_id and step_run.status == "queued"
    )
  end

  defp scheduled_steps(flow_run_id) do
    Repo.all(
      from step_run in StepRun,
        where: step_run.flow_run_id == ^flow_run_id and step_run.status == "scheduled",
        select: %{step_id: step_run.step_id}
    )
  end

  defp recover_stale_executing_step(candidate, opts) do
    result =
      Repo.transaction(fn ->
        step_run = lock_recovery_step_run!(candidate.step_run_id)

        cond do
          step_run.status != "executing" ->
            :skipped

          active_step_job?(step_run.flow_run_id, step_run.step_id) ->
            :skipped

          stale_recovery_exhausted?(step_run) ->
            updated_step_run = mark_stale_recovery_exhausted!(step_run)
            {:exhausted, updated_step_run}

          true ->
            updated_step_run = mark_stale_executing_step_queued!(step_run, opts)
            {:recovered, updated_step_run}
        end
      end)
      |> unwrap_transaction()

    case result do
      {:ok, {:recovered, step_run}} ->
        cancel_step_jobs(step_run.flow_run_id, [step_run.step_id])
        _ = reconcile_run(step_run.flow_run_id)
        :recovered

      {:ok, {:exhausted, step_run}} ->
        cancel_step_jobs(step_run.flow_run_id, [step_run.step_id])

        Events.broadcast_updated(step_run.flow_run_id, %{
          "step_status" => "failed",
          "step_type" => step_run.step_type
        })

        maybe_broadcast_processing_progress(step_run.flow_run_id, step_run.step_type)
        _ = reconcile_run(step_run.flow_run_id)
        :exhausted

      _ ->
        :skipped
    end
  end

  defp stale_recovery_exhausted?(%StepRun{} = step_run) do
    execution_attempts_exhausted?(step_run) or
      orphan_recovery_count(step_run) >= max_orphan_recoveries()
  end

  defp lock_recovery_step_run!(step_run_id) do
    StepRun
    |> where([step_run], step_run.id == ^step_run_id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  defp active_step_job?(flow_run_id, step_id) do
    Job
    |> where([job], job.worker == ^worker_name(FlowStepWorker))
    |> where([job], job.state in ^@active_oban_step_job_states)
    |> where([job], fragment("?->>'flow_run_id' = ?", job.args, ^flow_run_id))
    |> where([job], fragment("?->>'step_id' = ?", job.args, ^step_id))
    |> Repo.all()
    |> Enum.any?(&active_oban_job?/1)
  end

  defp active_oban_job?(%Job{state: state}) when state in ["available", "scheduled", "retryable"],
    do: true

  defp active_oban_job?(%Job{
         state: "executing",
         queue: queue,
         id: job_id,
         attempted_by: attempted_by
       }) do
    current_node = node_name()

    case {attempted_by, Oban.check_queue(queue: queue)} do
      {[node_name, producer_uuid], %{node: node_name, uuid: producer_uuid, running: running}} ->
        job_id in running

      {[node_name, _producer_uuid], _queue} when node_name == current_node ->
        false

      {[node_name, _producer_uuid], _queue} ->
        oban_node_active?(node_name)

      {_attempted_by, _queue} ->
        false
    end
  end

  defp active_oban_job?(_job), do: false

  defp oban_node_active?(node_name) when is_binary(node_name) do
    case SQL.query(
           Repo,
           "select 1 from oban_peers where name = $1 and node = $2 and expires_at > now() limit 1",
           [inspect(Oban), node_name]
         ) do
      {:ok, %{num_rows: count}} -> count > 0
      {:error, _reason} -> true
    end
  rescue
    _error -> true
  end

  defp node_name do
    Node.self()
    |> Atom.to_string()
  end

  defp worker_name(worker) when is_atom(worker) do
    worker
    |> Atom.to_string()
    |> String.trim_leading("Elixir.")
  end

  defp mark_stale_executing_step_queued!(step_run, opts) do
    step_run
    |> StepRun.changeset(%{
      status: "queued",
      scheduled_at: nil,
      started_at: nil,
      completed_at: nil,
      error: nil,
      execution_metadata: stale_step_recovery_metadata(step_run, opts)
    })
    |> Repo.update!()
  end

  defp mark_stale_recovery_exhausted!(%StepRun{} = step_run) do
    attempts = execution_cycle_attempts(step_run)
    max_attempts = execution_attempt_limit(step_run)
    recoveries = orphan_recovery_count(step_run)

    step_run
    |> StepRun.changeset(%{
      status: "failed",
      completed_at: now_utc(),
      error:
        "automatic orphan recovery exhausted after #{recoveries} recoveries and #{attempts} execution attempts; retry manually to continue",
      execution_metadata:
        step_run.execution_metadata
        |> put_retry_policy_metadata(%{
          "cycle_attempts" => attempts,
          "orphan_recoveries" => recoveries,
          "max_execution_attempts" => max_attempts,
          "max_orphan_recoveries" => max_orphan_recoveries(),
          "exhausted" => true
        })
        |> Map.put("recovery", %{
          "reason" => "automatic_recovery_exhausted",
          "previous_reason" => get_in(step_run.execution_metadata || %{}, ["recovery", "reason"]),
          "previous_started_at" => datetime_iso8601(step_run.started_at),
          "previous_attempt" => step_run.attempt
        })
    })
    |> Repo.update!()
  end

  defp stale_step_recovery_metadata(step_run, opts) do
    recovered_at =
      opts
      |> Keyword.get(:now, DateTime.utc_now())
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    recoveries = orphan_recovery_count(step_run) + 1
    max_attempts = execution_attempt_limit(step_run)

    recovery = %{
      "reason" => "orphaned_executing_step",
      "recovered_at" => recovered_at,
      "previous_started_at" => datetime_iso8601(step_run.started_at),
      "previous_attempt" => step_run.attempt,
      "count" => recoveries,
      "max_recoveries" => max_orphan_recoveries()
    }

    (step_run.execution_metadata || %{})
    |> put_retry_policy_metadata(%{
      "cycle_attempts" => execution_cycle_attempts(step_run),
      "orphan_recoveries" => recoveries,
      "max_execution_attempts" => max_attempts,
      "max_orphan_recoveries" => max_orphan_recoveries(),
      "exhausted" => false
    })
    |> Map.put("recovery", recovery)
  end

  defp datetime_iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp datetime_iso8601(_datetime), do: nil

  defp retry_subtree_step_ids(definition, step_id) do
    dependents_by_id =
      definition
      |> Definition.steps()
      |> Enum.reduce(%{}, fn step_definition, acc ->
        Enum.reduce(Definition.dependencies(step_definition), acc, fn dependency_id, inner_acc ->
          Map.update(
            inner_acc,
            dependency_id,
            [step_definition["id"]],
            &[step_definition["id"] | &1]
          )
        end)
      end)

    do_retry_subtree_step_ids([step_id], dependents_by_id, MapSet.new())
    |> MapSet.to_list()
  end

  defp do_retry_subtree_step_ids([], _dependents_by_id, seen), do: seen

  defp do_retry_subtree_step_ids([step_id | rest], dependents_by_id, seen) do
    if MapSet.member?(seen, step_id) do
      do_retry_subtree_step_ids(rest, dependents_by_id, seen)
    else
      next =
        dependents_by_id
        |> Map.get(step_id, [])
        |> Enum.reject(&MapSet.member?(seen, &1))

      do_retry_subtree_step_ids(rest ++ next, dependents_by_id, MapSet.put(seen, step_id))
    end
  end

  defp recoverable_root_step_ids(definition, step_runs) do
    step_runs_by_id = Map.new(step_runs, fn step_run -> {step_run.step_id, step_run} end)

    definition
    |> Definition.steps()
    |> Enum.filter(&required_failed_step_definition?(&1, step_runs_by_id))
    |> Enum.map(&recoverable_root_step_id(definition, step_runs_by_id, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> prune_redundant_recovery_roots(definition)
  end

  defp interrupted_recovery_root_step_ids(%Run{status: "failed", step_runs: step_runs}) do
    step_runs
    |> Enum.filter(fn step_run ->
      step_run.status == "executing" or
        (step_run.status == "cancelled" and
           step_run.error in [
             @failed_run_executing_step_error,
             @failed_run_pending_step_error
           ])
    end)
    |> Enum.map(& &1.step_id)
  end

  defp interrupted_recovery_root_step_ids(%Run{}), do: []

  defp ensure_recoverable_subtree!(%Run{status: "failed"}, _subtree_step_runs), do: :ok

  defp ensure_recoverable_subtree!(%Run{}, subtree_step_runs) do
    ensure_retryable_subtree!(subtree_step_runs)
  end

  defp required_failed_step_definition?(step_definition, step_runs_by_id) do
    Definition.required?(step_definition) and
      match?(%{status: "failed"}, Map.get(step_runs_by_id, step_definition["id"]))
  end

  defp recoverable_root_step_id(definition, step_runs_by_id, step_definition) do
    case failed_required_dependency_id(definition, step_runs_by_id, step_definition) do
      nil ->
        media_failed_upstream_producer_id(definition, step_runs_by_id, step_definition) ||
          step_definition["id"]

      dependency_id ->
        case Definition.step_by_id(definition, dependency_id) do
          nil ->
            dependency_id

          dependency_definition ->
            recoverable_root_step_id(definition, step_runs_by_id, dependency_definition)
        end
    end
  end

  defp failed_required_dependency_id(definition, step_runs_by_id, step_definition) do
    Enum.find(Definition.dependencies(step_definition), fn dependency_id ->
      dependency_definition = Definition.step_by_id(definition, dependency_id)

      Definition.required?(dependency_definition) and
        match?(%{status: "failed"}, Map.get(step_runs_by_id, dependency_id))
    end)
  end

  defp media_failed_upstream_producer_id(definition, step_runs_by_id, step_definition) do
    step_run = Map.get(step_runs_by_id, step_definition["id"])

    if media_packaging_step?(step_definition) and
         media_dependency_error?(maybe_step_error(step_run)) do
      step_definition
      |> package_source_step_ids()
      |> Enum.find(&succeeded_required_dependency?(definition, step_runs_by_id, &1))
    end
  end

  defp media_packaging_step?(%{"type" => type})
       when type in ["media.package_hls_audio", "media.package_hls_variant"],
       do: true

  defp media_packaging_step?(_step_definition), do: false

  defp package_source_step_ids(step_definition) do
    params = Map.get(step_definition, "params", %{})
    dependencies = Definition.dependencies(step_definition)

    case Map.get(params, "source_step_id") do
      source_step_id when is_binary(source_step_id) and source_step_id != "" ->
        Enum.uniq([source_step_id | dependencies])

      _ ->
        dependencies
    end
  end

  defp succeeded_required_dependency?(definition, step_runs_by_id, dependency_id) do
    dependency_definition = Definition.step_by_id(definition, dependency_id)

    Definition.required?(dependency_definition) and
      match?(%{status: "succeeded"}, Map.get(step_runs_by_id, dependency_id))
  end

  defp maybe_step_error(%StepRun{error: error}), do: error
  defp maybe_step_error(_step_run), do: nil

  defp media_dependency_error?(error) when is_binary(error) do
    normalized = String.downcase(error)

    StepSupport.ffmpeg_storage_read_error?(error) or
      String.contains?(normalized, "moov atom not found") or
      String.contains?(normalized, "could not find codec parameters") or
      String.contains?(normalized, "invalid media output") or
      String.contains?(normalized, "could not package hls")
  end

  defp media_dependency_error?(_error), do: false

  defp prune_redundant_recovery_roots(root_step_ids, definition) do
    Enum.reject(root_step_ids, fn root_step_id ->
      Enum.any?(root_step_ids, fn other_step_id ->
        other_step_id != root_step_id and
          root_step_id in retry_subtree_step_ids(definition, other_step_id)
      end)
    end)
  end

  defp maybe_publish_processing_manifest(
         step_run_id,
         flow_run_id,
         "asset.upload_original",
         output
       )
       when is_binary(step_run_id) and is_binary(flow_run_id) and is_map(output) do
    run = Repo.get(Run, flow_run_id)

    with %Run{input: %{"space_hash" => space_hash, "embed_hash" => embed_hash}} <- run,
         step_runs when is_list(step_runs) <- list_step_runs(flow_run_id),
         %Embed{} = embed <- Embeds.get_embed_by_hashes(space_hash, embed_hash),
         %Video{} = video <- run_video(run, embed),
         true <- current_run_video?(embed, video),
         playback_output <- processing_playback_output(run, step_runs) || output,
         {:ok, _player} <- publish_processing_player(embed, step_runs),
         {:ok, _manifest} <-
           ManifestPublisher.publish(
             embed,
             playback_output
             |> Map.put("has_audio", inspect_has_audio(step_runs))
             |> Map.put("status", "playable")
           ),
         :ok <- mark_processing_player_ready(step_run_id) do
      unless public_upload_playback?(playback_output), do: broadcast_upload_completed(run, embed)
      mark_video_playable(embed)
      EmbedEvents.broadcast_updated(embed.space_id, embed.id, %{"phase" => "processing"})
      :ok
    else
      nil ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to publish intermediate playback assets for flow #{flow_run_id}: " <>
            inspect(reason)
        )

        :ok

      _ ->
        :ok
    end
  end

  defp maybe_publish_processing_manifest(step_run_id, flow_run_id, "media.inspect", output)
       when is_binary(step_run_id) and is_binary(flow_run_id) and is_map(output) do
    run = Repo.get(Run, flow_run_id)

    with %{"status" => "ok"} <- output,
         %Run{input: %{"space_hash" => space_hash, "embed_hash" => embed_hash}} <- run,
         step_runs when is_list(step_runs) <- list_step_runs(flow_run_id),
         %{} = playback_output <- processing_playback_output(run, step_runs),
         %Embed{} = embed <- Embeds.get_embed_by_hashes(space_hash, embed_hash),
         %Video{} = video <- run_video(run, embed),
         true <- current_run_video?(embed, video),
         embed <- project_processing_video_metadata(embed, video, step_runs),
         {:ok, _player} <- publish_processing_player(embed, step_runs),
         {:ok, _manifest} <-
           ManifestPublisher.publish(
             embed,
             playback_output
             |> Map.put("has_audio", Map.get(output, "has_audio", Map.get(output, :has_audio)))
             |> Map.put("status", "playable")
           ),
         :ok <- mark_processing_player_ready(step_run_id) do
      broadcast_upload_completed(run, embed)
      maybe_enqueue_processing_webhooks(space_hash, embed_hash)
      mark_video_playable(embed)
      EmbedEvents.broadcast_updated(embed.space_id, embed.id, %{"phase" => "processing"})
      :ok
    else
      nil ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to publish inspect-updated playback assets for flow #{flow_run_id}: " <>
            inspect(reason)
        )

        :ok

      _ ->
        :ok
    end
  end

  defp maybe_publish_processing_manifest(_step_run_id, _flow_run_id, _step_type, _output),
    do: :ok

  defp mark_processing_player_ready(step_run_id) when is_binary(step_run_id) do
    case Repo.get(StepRun, step_run_id) do
      %StepRun{} = step_run ->
        processing_player = %{
          "ready" => true,
          "published_at" => DateTime.to_iso8601(now_utc())
        }

        execution_metadata =
          step_run.execution_metadata
          |> Kernel.||(%{})
          |> Map.put("processing_player", processing_player)

        step_run
        |> StepRun.changeset(%{execution_metadata: execution_metadata})
        |> Repo.update()
        |> case do
          {:ok, _step_run} -> :ok
          {:error, reason} -> {:error, reason}
        end

      nil ->
        {:error, :step_run_not_found}
    end
  end

  defp processing_playback_output(%Run{input: input}, step_runs) when is_map(input) do
    uploaded_original_output(step_runs) || public_upload_playback_output(input)
  end

  defp processing_playback_output(_run, step_runs), do: uploaded_original_output(step_runs)

  defp public_upload_playback_output(input) do
    case public_upload_source_url(input) do
      url when is_binary(url) -> %{"original_url" => url}
      _other -> nil
    end
  end

  defp public_upload_source_url(input) when is_map(input) do
    public_url =
      Map.get(input, "upload_public_url") ||
        Storage.upload_public_object_url(Map.get(input, "source_key"))

    case public_url do
      url when is_binary(url) ->
        if Storage.upload_public_url?(url), do: url, else: direct_upload_source_url(input)

      _other ->
        direct_upload_source_url(input)
    end
  end

  defp public_upload_source_url(_input), do: nil

  defp direct_upload_source_url(input) do
    [Map.get(input, "source_url"), Map.get(input, "upload_ffmpeg_input_url")]
    |> Enum.find(fn
      url when is_binary(url) -> Storage.upload_storage_url?(url)
      _other -> false
    end)
  end

  defp public_upload_playback?(%{"original_url" => url}) when is_binary(url),
    do: Storage.upload_storage_url?(url) or Storage.upload_public_url?(url)

  defp public_upload_playback?(_output), do: false

  defp publish_processing_player(
         %Embed{space: %Space{} = space, hash: embed_hash} = embed,
         step_runs
       ) do
    storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter, Storage)
    bucket = Storage.bucket_for_space(space.hash, space.region)

    PlayerPublisher.publish(
      storage_adapter,
      bucket,
      space.hash,
      embed_hash,
      Embeds.current_video_version(embed),
      space.region,
      audio_only: match?(%{"has_audio" => true, "has_video" => false}, inspect_output(step_runs))
    )
  end

  defp broadcast_upload_completed(
         %Run{input: %{"upload_id" => upload_id}},
         %Embed{space: %Space{hash: space_hash}, hash: embed_hash}
       )
       when is_binary(upload_id) and is_binary(space_hash) and is_binary(embed_hash) do
    UploadEvents.broadcast(:completed, %{embed: "#{space_hash}#{embed_hash}"}, upload_id)
  end

  defp broadcast_upload_completed(_run, _embed), do: :ok

  defp project_processing_video_metadata(
         %Embed{asset: %{current_video: %Video{}} = asset} = embed,
         %Video{} = video,
         step_runs
       ) do
    %{embed | asset: %{asset | current_video: project_video_metadata(video, step_runs)}}
  end

  defp project_processing_video_metadata(embed, _video, _step_runs), do: embed

  defp maybe_enqueue_processing_webhooks(space_hash, embed_hash)
       when is_binary(space_hash) and is_binary(embed_hash) do
    case Embeds.get_embed_by_hashes(space_hash, embed_hash) do
      %Embed{space: %Space{} = space, asset: %{current_video: %Video{} = video}} = embed ->
        if video.status not in @ready_video_statuses, do: maybe_mark_video_preparing(video)

        case Spaces.enqueue_webhook_event_for_embed(
               space,
               embed,
               :video_processing,
               %{enqueue: true}
             ) do
          {:ok, _deliveries} ->
            :ok

          {:error, :not_found} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Failed to enqueue video_processing webhooks for #{space.hash}/#{embed.hash}: " <>
                inspect(reason)
            )

            :ok
        end

      _ ->
        :ok
    end
  end

  defp maybe_enqueue_processing_webhooks(_space_hash, _embed_hash), do: :ok

  defp maybe_mark_video_preparing(
         %{
           "space_hash" => space_hash,
           "embed_hash" => embed_hash
         } = input
       )
       when is_binary(space_hash) and is_binary(embed_hash) do
    case Embeds.get_embed_by_hashes(space_hash, embed_hash) do
      %Embed{} = embed ->
        input
        |> video_for_input(embed)
        |> maybe_mark_video_preparing()

      _ ->
        :ok
    end
  end

  defp maybe_mark_video_preparing(%Video{status: "uploading"} = video) do
    video
    |> Video.changeset(%{status: "preparing"})
    |> Repo.update!()

    :ok
  end

  defp maybe_mark_video_preparing(%Video{}), do: :ok
  defp maybe_mark_video_preparing(_input), do: :ok

  defp mark_video_playable(%Embed{asset: %{current_video: %Video{} = video}}) do
    mark_video_playable(video)
  end

  defp mark_video_playable(%Video{status: status}) when status in @ready_video_statuses, do: :ok

  defp mark_video_playable(%Video{} = video) do
    video
    |> Video.changeset(%{status: "playable"})
    |> Repo.update!()

    :ok
  end

  defp mark_video_playable(_video), do: :ok

  defp list_step_runs(flow_run_id) when is_binary(flow_run_id) do
    StepRun
    |> where([step_run], step_run.flow_run_id == ^flow_run_id)
    |> Repo.all()
  end

  defp list_step_runs(_flow_run_id), do: []

  defp maybe_sync_completed_media_metadata(
         flow_run_id,
         step_type,
         %{"status" => "ok"}
       )
       when is_binary(flow_run_id) and
              step_type in [
                "media.transcode_audio",
                "media.generate_audio_peaks",
                "ai.transcribe_audio",
                "ai.translate_subtitles",
                "manifest.build"
              ] do
    with %Run{input: %{"space_hash" => space_hash, "embed_hash" => embed_hash}} = run <-
           Repo.get(Run, flow_run_id),
         step_runs when is_list(step_runs) <- list_step_runs(flow_run_id),
         %Embed{} = embed <- Embeds.get_embed_by_hashes(space_hash, embed_hash),
         %Video{} = video <- run_video(run, embed) do
      case step_type do
        "media.transcode_audio" ->
          sync_audio_tracks(video.id, step_runs)

        subtitle_step when subtitle_step in ["ai.transcribe_audio", "ai.translate_subtitles"] ->
          sync_subtitles(video.id, step_runs)

        type when type in ["manifest.build", "media.generate_audio_peaks"] ->
          :ok
      end

      video = maybe_apply_detected_video_language(video, step_runs)
      maybe_apply_detected_audio_track_language(video.id, step_runs)
      maybe_publish_completed_media_metadata(step_type, video, space_hash, embed_hash, step_runs)
    else
      _other -> :ok
    end
  rescue
    exception ->
      Logger.warning(
        "Failed to publish completed media metadata for flow #{flow_run_id}: " <>
          Exception.message(exception)
      )

      :ok
  end

  defp maybe_sync_completed_media_metadata(_flow_run_id, _step_type, _output), do: :ok

  defp maybe_publish_completed_media_metadata(
         step_type,
         video,
         space_hash,
         embed_hash,
         step_runs
       ) do
    space_hash
    |> Embeds.get_embed_by_hashes(embed_hash)
    |> maybe_publish_current_completed_media(step_type, video, step_runs)
  end

  defp maybe_publish_current_completed_media(
         %Embed{} = embed,
         step_type,
         %Video{} = video,
         step_runs
       ) do
    if current_run_video?(embed, video) do
      _ = maybe_refresh_completed_hls_master(step_type, embed)
      updates = uploaded_original_output(step_runs) || %{}

      updates =
        case completed_audio_waveform(step_runs) do
          nil -> updates
          waveform -> Map.put(updates, "waveform", waveform)
        end

      maybe_publish_completed_manifest(embed, updates)
    else
      :ok
    end
  end

  defp maybe_publish_current_completed_media(_embed, _step_type, _video, _step_runs), do: :ok

  defp completed_audio_waveform(step_runs) do
    Enum.find_value(step_runs, fn
      %StepRun{
        step_type: "media.generate_audio_peaks",
        status: "succeeded",
        output: %{"waveform" => waveform}
      } ->
        waveform

      _ ->
        nil
    end)
  end

  defp maybe_refresh_completed_hls_master(step_type, %Embed{} = embed)
       when step_type in ["ai.transcribe_audio", "ai.translate_subtitles", "manifest.build"] do
    Assets.refresh_hls_master_playlist(embed)
  end

  defp maybe_refresh_completed_hls_master(_step_type, _embed), do: :ok

  defp inspect_has_audio(step_runs) when is_list(step_runs) do
    step_runs
    |> inspect_output()
    |> case do
      %{} = output -> Map.get(output, "has_audio", Map.get(output, :has_audio))
      _ -> nil
    end
  end

  defp inspect_has_audio(_step_runs), do: nil

  defp uploaded_original_output(step_runs) when is_list(step_runs) do
    Enum.find_value(step_runs, fn
      %StepRun{
        step_type: "asset.upload_original",
        status: "succeeded",
        output: %{"bucket" => bucket, "original_key" => original_key} = output
      }
      when is_binary(bucket) and is_binary(original_key) ->
        output

      _ ->
        nil
    end)
  end

  defp uploaded_original_output(_step_runs), do: nil

  defp maybe_broadcast_processing_progress(flow_run_id, step_type)
       when is_binary(flow_run_id) and is_binary(step_type) do
    run = Repo.get(Run, flow_run_id)

    with %Run{input: %{"space_hash" => space_hash, "embed_hash" => embed_hash}} <- run,
         %Embed{} = embed <- Embeds.get_embed_by_hashes(space_hash, embed_hash),
         %Video{} = video <- run_video(run, embed) do
      maybe_mark_video_preparing(video)

      EmbedEvents.broadcast_updated(embed.space_id, embed.id, %{
        "phase" => "processing",
        "step_type" => step_type
      })
    else
      _ -> :ok
    end
  end

  defp maybe_broadcast_processing_progress(_flow_run_id, _step_type), do: :ok

  defp maybe_broadcast_processing_started(%{
         "space_hash" => space_hash,
         "embed_hash" => embed_hash
       })
       when is_binary(space_hash) and is_binary(embed_hash) do
    case Embeds.get_embed_by_hashes(space_hash, embed_hash) do
      %Embed{} = embed ->
        EmbedEvents.broadcast_updated(embed.space_id, embed.id, %{"phase" => "processing"})

      _ ->
        :ok
    end
  end

  defp maybe_broadcast_processing_started(_input), do: :ok

  defp project_video_metadata(%Video{} = video, step_runs) do
    attrs =
      step_runs
      |> inspect_output()
      |> video_projection_attrs()

    if attrs == %{} do
      video
    else
      video
      |> Video.changeset(attrs)
      |> Repo.update!()
    end
  end

  defp mark_video_ready(%Video{status: "ready"} = video), do: video

  defp mark_video_ready(%Video{} = video) do
    video
    |> Video.changeset(%{status: "ready"})
    |> Repo.update!()
  end

  defp sync_video_renditions(video_id, step_runs) when is_binary(video_id) do
    custom_thumbnail_keys =
      from(r in "renditions",
        where: r.video_id == type(^video_id, MaveCore.Ecto.LegacyShortUUID),
        where: r.type == "custom_thumbnail",
        select: r.rendition_key
      )
      |> Repo.all()
      |> MapSet.new()

    from(r in "renditions",
      where: r.video_id == type(^video_id, MaveCore.Ecto.LegacyShortUUID),
      where: r.type != "custom_thumbnail"
    )
    |> Repo.delete_all()

    video_id_db = MaveCore.LegacyShortUUID.dump!(video_id)
    now = now_utc()

    rows =
      step_runs
      |> Enum.flat_map(&successful_renditions/1)
      |> Enum.map(&build_rendition_row(video_id_db, &1, now))
      |> Enum.reject(fn row ->
        is_nil(row) or MapSet.member?(custom_thumbnail_keys, row.rendition_key)
      end)
      |> Enum.uniq_by(& &1.rendition_key)

    if rows != [] do
      Repo.insert_all("renditions", rows)
    end
  end

  defp sync_audio_tracks(video_id, step_runs) when is_binary(video_id) do
    from(track in AudioTrack, where: track.video_id == ^video_id)
    |> Repo.delete_all()

    step_runs
    |> Enum.flat_map(&successful_audio_tracks/1)
    |> Enum.uniq_by(&Map.get(&1, "filename"))
    |> Enum.each(fn track ->
      %AudioTrack{}
      |> AudioTrack.changeset(build_audio_track_attrs(video_id, track))
      |> Repo.insert!()
    end)
  end

  defp sync_subtitles(video_id, step_runs) when is_binary(video_id) do
    from(subtitle in Subtitle, where: subtitle.video_id == ^video_id)
    |> Repo.delete_all()

    step_runs
    |> Enum.flat_map(&successful_subtitles/1)
    |> Enum.uniq_by(&(Map.get(&1, "language") || Map.get(&1, "path") || Map.get(&1, "src")))
    |> Enum.with_index()
    |> Enum.each(fn {subtitle, index} ->
      %Subtitle{}
      |> Subtitle.changeset(build_subtitle_attrs(video_id, subtitle, index))
      |> Repo.insert!()
    end)
  end

  defp maybe_apply_detected_video_language(%Video{} = video, step_runs) do
    if is_binary(video.language) and String.trim(video.language) != "" do
      video
    else
      case detected_subtitle_language(step_runs) do
        nil ->
          video

        language ->
          video
          |> Video.changeset(%{language: language})
          |> Repo.update!()
      end
    end
  end

  defp maybe_apply_detected_audio_track_language(video_id, step_runs) when is_binary(video_id) do
    case detected_subtitle_language(step_runs) do
      nil ->
        :ok

      language ->
        AudioTrack
        |> where([track], track.video_id == ^video_id and track.default == true)
        |> Repo.all()
        |> Enum.each(&maybe_update_audio_track_language(&1, language))
    end
  end

  defp detected_subtitle_language(step_runs) do
    step_runs
    |> Enum.find_value(fn
      %StepRun{
        step_type: "ai.transcribe_audio",
        status: "succeeded",
        output: %{"status" => "ok"} = output
      } ->
        normalized_track_language(output["language"]) ||
          (output["subtitles"] || [])
          |> Enum.filter(&is_map/1)
          |> Enum.find_value(&normalized_track_language(&1["language"]))

      _ ->
        nil
    end)
  end

  defp inspect_output(step_runs) do
    Enum.find_value(step_runs, fn step_run ->
      output = step_run.output || %{}

      if step_run.status == "succeeded" and step_run.step_type == "media.inspect" and
           is_map(output) do
        output
      end
    end)
  end

  defp video_projection_attrs(nil), do: %{}

  defp video_projection_attrs(output) when is_map(output) do
    video_stream =
      output
      |> map_value("streams", [])
      |> StepSupport.video_stream()

    %{
      max_width: integer_value(map_value(output, "width")),
      max_height: integer_value(map_value(output, "height")),
      max_frame_rate:
        frame_rate_value(stream_value(video_stream, "avg_frame_rate")) ||
          frame_rate_value(stream_value(video_stream, "r_frame_rate")),
      max_bitrate:
        integer_value(stream_value(video_stream, "bit_rate")) ||
          integer_value(map_value(output, "bit_rate")),
      duration: float_value(map_value(output, "duration")),
      aspect_ratio: normalized_aspect_ratio(map_value(output, "aspect_ratio")),
      original_file_size: integer_value(map_value(output, "size_bytes"))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp successful_renditions(
         %StepRun{status: "succeeded", output: %{"status" => "ok"}} = step_run
       ) do
    case step_run.output["renditions"] do
      renditions when is_list(renditions) -> Enum.filter(renditions, &is_map/1)
      _ -> []
    end
  end

  defp successful_renditions(_step_run), do: []

  defp successful_audio_tracks(%StepRun{
         step_type: "media.transcode_audio",
         status: "succeeded",
         output: %{"status" => "ok"} = output
       }) do
    case output["audio_tracks"] do
      tracks when is_list(tracks) -> Enum.filter(tracks, &is_map/1)
      _ -> []
    end
  end

  defp successful_audio_tracks(_step_run), do: []

  defp successful_subtitles(%StepRun{
         step_type: step_type,
         status: "succeeded",
         output: %{"status" => "ok"} = output
       })
       when step_type in ["ai.transcribe_audio", "ai.translate_subtitles"] do
    case output["subtitles"] do
      subtitles when is_list(subtitles) -> Enum.filter(subtitles, &is_map/1)
      _ -> []
    end
  end

  defp successful_subtitles(_step_run), do: []

  defp build_rendition_row(video_id, rendition, now) do
    with key when is_binary(key) and key != "" <- rendition["rendition_key"],
         type when is_binary(type) <- db_rendition_type(rendition) do
      %{
        id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
        video_id: video_id,
        rendition_key: key,
        type: type,
        codec: enum_value(rendition["codec"], @db_rendition_codecs),
        container: enum_value(rendition["container"], @db_rendition_containers),
        size: enum_value(rendition["size"], @db_rendition_sizes),
        progress: float_value(rendition["progress"]),
        file_size: integer_value(rendition["file_size"]),
        inserted_at: now,
        updated_at: now
      }
    else
      _ -> nil
    end
  end

  defp build_audio_track_attrs(video_id, track) do
    %{
      video_id: video_id,
      label: string_value(track["label"]),
      language: normalized_track_language(track["language"]),
      default: boolean_value(track["default"], false),
      codec: string_value(track["codec"]),
      file_size: integer_value(track["file_size"]),
      filename: string_value(track["filename"])
    }
  end

  defp build_subtitle_attrs(video_id, subtitle, _index) do
    %{
      video_id: video_id,
      language: normalized_track_language(subtitle["language"]),
      path: normalized_subtitle_path(subtitle["path"] || subtitle["src"])
    }
  end

  defp normalized_subtitle_path("s3://" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [_bucket, key] when is_binary(key) and key != "" -> key
      _ -> nil
    end
  end

  defp normalized_subtitle_path(path) when is_binary(path) and path != "", do: path
  defp normalized_subtitle_path(_path), do: nil

  defp normalized_track_language(value) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      |> String.downcase()
      |> String.replace("-", "_")

    cond do
      normalized in ["", "un", "und"] -> nil
      byte_size(normalized) >= 2 -> String.slice(normalized, 0, 2)
      true -> nil
    end
  end

  defp normalized_track_language(_value), do: nil

  defp db_rendition_type(%{"type" => "image", "role" => role}) do
    case role do
      "poster" -> "poster"
      "thumbnail" -> "thumbnail"
      "placeholder" -> "placeholder"
      "custom_thumbnail" -> "custom_thumbnail"
      _ -> nil
    end
  end

  defp db_rendition_type(%{"type" => "video", "role" => "waveform"}), do: nil
  defp db_rendition_type(%{"type" => type}) when type in @db_rendition_types, do: type
  defp db_rendition_type(_rendition), do: nil

  defp enum_value(value, allowed) when is_binary(value) do
    normalized = String.downcase(value)
    if normalized in allowed, do: normalized, else: nil
  end

  defp enum_value(_value, _allowed), do: nil

  defp string_value(value) when is_binary(value) and value != "", do: value
  defp string_value(_value), do: nil

  defp normalize_media_param(nil, default), do: default

  defp normalize_media_param(value, _default) when is_binary(value) and value != "" do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_media_param(value, default) when is_atom(value) do
    value
    |> Atom.to_string()
    |> normalize_media_param(default)
  end

  defp normalize_media_param(_value, default), do: default

  defp normalize_media_sizes(values) when is_list(values) do
    values
    |> Enum.map(&normalize_media_param(&1, nil))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_media_sizes(_values), do: []

  defp list_value(value) when is_list(value), do: value
  defp list_value(_value), do: []

  defp boolean_value(value, _default) when value in [true, "true", 1, "1"], do: true
  defp boolean_value(value, _default) when value in [false, "false", 0, "0"], do: false
  defp boolean_value(_value, default), do: default

  defp integer_value(value) when is_integer(value), do: value
  defp integer_value(value) when is_float(value), do: trunc(value)

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp integer_value(_value), do: nil

  defp float_value(value) when is_float(value), do: value
  defp float_value(value) when is_integer(value), do: value * 1.0

  defp float_value(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp float_value(_value), do: nil

  defp map_value(map, key, default \\ nil)
  defp map_value(nil, _key, default), do: default

  defp map_value(map, key, default) when is_map(map) do
    Map.get(map, key) ||
      Enum.find_value(map, default, fn
        {map_key, value} when is_atom(map_key) ->
          if Atom.to_string(map_key) == key, do: value

        _ ->
          nil
      end)
  end

  defp map_value(_value, _key, default), do: default

  defp stream_value(nil, _key), do: nil

  defp stream_value(map, key) when is_map(map) do
    map_value(map, key)
  end

  defp stream_value(_value, _key), do: nil

  defp frame_rate_value(value) when is_float(value), do: value
  defp frame_rate_value(value) when is_integer(value), do: value * 1.0

  defp frame_rate_value(value) when is_binary(value) do
    case String.split(value, "/", parts: 2) do
      [numerator, denominator] ->
        with {num, ""} <- Float.parse(numerator),
             {den, ""} <- Float.parse(denominator),
             true <- den > 0 do
          Float.round(num / den, 3)
        else
          _ -> float_value(value)
        end

      _ ->
        float_value(value)
    end
  end

  defp frame_rate_value(_value), do: nil

  defp normalized_aspect_ratio(value) when is_binary(value) and value != "" do
    value
    |> String.replace(":", "/")
    |> String.replace(~r/\s+/, "")
  end

  defp normalized_aspect_ratio(_value), do: nil

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, {:changeset, changeset}}), do: {:error, changeset}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp reload_run(run) do
    Repo.preload(run, [:flow_template, :flow_version, :step_runs, :artifact_refs], force: true)
  end

  defp run_inline_loop(_run_id, remaining_cycles) when remaining_cycles <= 0,
    do: {:error, :inline_limit_exceeded}

  defp run_inline_loop(run_id, remaining_cycles) do
    with {:ok, run} <- reconcile_run(run_id, enqueue_jobs: false) do
      if run.status in @terminal_statuses do
        {:ok, get_run!(run_id)}
      else
        continue_inline_run(run_id, run.step_runs, remaining_cycles)
      end
    end
  end

  defp requested_version(opts) do
    case Keyword.get(opts, :version) do
      version when is_integer(version) ->
        {:ok, version}

      version when is_binary(version) ->
        parse_version_number(version)

      nil ->
        :latest_active

      _ ->
        {:error, :invalid_version}
    end
  end

  defp parse_version_number(version) do
    case Integer.parse(version) do
      {parsed, ""} -> {:ok, parsed}
      _ -> {:error, :invalid_version}
    end
  end

  defp fetch_latest_active_version(template_id) do
    version =
      Version
      |> where([v], v.flow_template_id == ^template_id and v.status == "active")
      |> order_by([v], desc: v.version)
      |> limit(1)
      |> Repo.one()

    if version, do: {:ok, version}, else: {:error, :no_active_version}
  end

  defp fetch_version_by_number(template_id, version_number) do
    version = Repo.get_by(Version, flow_template_id: template_id, version: version_number)
    if version, do: {:ok, version}, else: {:error, :version_not_found}
  end

  defp finalize_video_assets(%Video{} = video, step_runs) do
    video
    |> project_video_metadata(step_runs)
    |> mark_video_ready()
    |> maybe_apply_detected_video_language(step_runs)

    sync_video_renditions(video.id, step_runs)
    sync_audio_tracks(video.id, step_runs)
    sync_subtitles(video.id, step_runs)
    maybe_apply_detected_audio_track_language(video.id, step_runs)
  end

  defp maybe_finalize_ready_embed(run, video, space_hash, embed_hash, step_runs) do
    case Embeds.get_embed_by_hashes(space_hash, embed_hash) do
      %Embed{} = embed ->
        durable_original = uploaded_original_output(step_runs) || %{}

        durable_original =
          Map.put(durable_original, "waveform", completed_audio_waveform(step_runs))

        with :ok <-
               maybe_publish_current_video_assets(
                 embed,
                 video,
                 space_hash,
                 embed_hash,
                 durable_original
               ),
             {:ok, promoted_run} <- promote_durable_source(run, durable_original) do
          maybe_make_upload_private(promoted_run, durable_original, space_hash, embed_hash)
        else
          {:error, reason} ->
            Logger.warning(
              "Failed to finalize completed upload for #{space_hash}/#{embed_hash}: #{inspect(reason)}"
            )

            {:error, reason}
        end

      _ ->
        :ok
    end
  end

  defp maybe_publish_current_video_assets(
         %Embed{} = embed,
         %Video{} = video,
         space_hash,
         embed_hash,
         durable_original
       ) do
    if current_run_video?(embed, video) do
      maybe_sync_public_thumbnail(embed, space_hash, embed_hash)
      maybe_publish_finalized_manifest(embed, space_hash, embed_hash, durable_original)
    else
      :ok
    end
  end

  defp maybe_sync_public_thumbnail(%Embed{} = embed, space_hash, embed_hash) do
    case MaveCore.Assets.sync_public_thumbnail(embed) do
      :ok ->
        :ok

      {:error, :missing_generated_thumbnail} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to sync public thumbnail for #{space_hash}/#{embed_hash}: #{inspect(reason)}"
        )
    end
  end

  defp maybe_publish_finalized_manifest(%Embed{} = embed, space_hash, embed_hash, opts) do
    case ManifestPublisher.publish(embed, opts) do
      {:ok, _manifest} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to publish finalized manifest for #{space_hash}/#{embed_hash}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp maybe_make_upload_private(
         run,
         durable_original,
         space_hash,
         embed_hash
       ) do
    case completed_upload_reference(run, durable_original) do
      {:ok, upload_bucket, upload_key, source_region} ->
        set_completed_upload_private(
          upload_bucket,
          upload_key,
          source_region,
          space_hash,
          embed_hash
        )

      :skip ->
        :ok
    end
  end

  defp completed_upload_reference(
         %Run{
           input:
             %{
               "upload_bucket" => upload_bucket,
               "upload_key" => upload_key
             } = input
         },
         %{"bucket" => durable_bucket, "original_key" => durable_key}
       ) do
    with true <- valid_object_reference?(upload_bucket, upload_key),
         true <- valid_object_reference?(durable_bucket, durable_key),
         false <- upload_bucket == durable_bucket and upload_key == durable_key do
      upload_region = Map.get(input, "upload_region") || Map.get(input, "source_region")
      {:ok, upload_bucket, upload_key, upload_region}
    else
      _other -> :skip
    end
  end

  defp completed_upload_reference(_run, _durable_original), do: :skip

  defp promote_durable_source(
         %Run{input: input} = run,
         %{"bucket" => bucket, "original_key" => key} = durable_original
       )
       when is_map(input) and is_binary(bucket) and bucket != "" and is_binary(key) and
              key != "" do
    region = Map.get(durable_original, "region") || Map.get(input, "region")

    content_type =
      Map.get(durable_original, "content_type") || Map.get(input, "source_content_type")

    upload_region = Map.get(input, "upload_region") || Map.get(input, "source_region")
    storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter, Storage)

    with true <- function_exported?(storage_adapter, :ffmpeg_input_url, 3),
         {:ok, source_url} <- storage_adapter.ffmpeg_input_url(bucket, key, region) do
      promoted_input =
        input
        |> Map.merge(%{
          "source_bucket" => bucket,
          "source_key" => key,
          "source_region" => region,
          "source_content_type" => content_type,
          "source_url" => source_url,
          "input_url" => source_url,
          "upload_ffmpeg_input_url" => source_url,
          "upload_region" => upload_region,
          "durable_source_promoted" => true
        })

      run
      |> Run.changeset(%{input: promoted_input})
      |> Repo.update()
    else
      false -> {:error, :durable_source_url_unsupported}
      {:error, reason} -> {:error, {:durable_source_url_failed, reason}}
    end
  end

  defp promote_durable_source(%Run{} = run, _durable_original), do: {:ok, run}

  defp promote_recovery_source!(%Run{step_runs: step_runs} = run) do
    case promote_durable_source(run, uploaded_original_output(step_runs)) do
      {:ok, promoted_run} -> promoted_run
      {:error, reason} -> Repo.rollback({:durable_source_promotion_failed, reason})
    end
  end

  defp valid_object_reference?(bucket, key) do
    is_binary(bucket) and bucket != "" and is_binary(key) and key != ""
  end

  defp set_completed_upload_private(
         upload_bucket,
         upload_key,
         source_region,
         space_hash,
         embed_hash
       ) do
    storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter, Storage)

    result =
      if function_exported?(storage_adapter, :set_object_visibility, 4) do
        storage_adapter.set_object_visibility(
          upload_bucket,
          upload_key,
          "private",
          source_region
        )
      else
        {:error, :upload_object_acl_not_supported}
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to make completed upload private for #{space_hash}/#{embed_hash}: " <>
            inspect(reason)
        )

        {:error, reason}
    end
  end

  defp maybe_update_audio_track_language(track, language) do
    if is_binary(track.language) and String.trim(track.language) != "" do
      :ok
    else
      track
      |> AudioTrack.changeset(%{language: language})
      |> Repo.update!()
    end
  end

  defp continue_inline_run(run_id, step_runs, remaining_cycles) do
    scheduled_steps = Enum.filter(step_runs, &(&1.status == "scheduled"))

    if scheduled_steps == [] do
      {:error, :inline_stalled}
    else
      case execute_scheduled_steps(run_id, scheduled_steps) do
        :ok -> run_inline_loop(run_id, remaining_cycles - 1)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp execute_scheduled_steps(run_id, scheduled_steps) do
    Enum.reduce_while(scheduled_steps, :ok, fn step, :ok ->
      case execute_step(run_id, step.step_id, enqueue_coordinator: false) do
        {:ok, _output} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp now_utc do
    DateTime.utc_now() |> DateTime.truncate(:microsecond)
  end
end
