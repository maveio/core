defmodule MaveCore.Flow.DiagnosticsTest do
  use MaveCore.DataCase, async: false

  alias MaveCore.Accounts
  alias MaveCore.Embeds
  alias MaveCore.Flow
  alias MaveCore.Flow.Admin
  alias MaveCore.Flow.Diagnostics
  alias MaveCore.Flow.Run
  alias MaveCore.Flow.StepRun
  alias MaveCore.Repo
  alias MaveCore.Spaces.Space

  @definition %{
    "steps" => [
      %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"},
      %{
        "id" => "manifest",
        "type" => "manifest.build",
        "name" => "Build Manifest",
        "depends_on" => ["source"]
      }
    ]
  }

  setup do
    old_flow_admin_config = Application.get_env(:mave_core, :flow_admin)
    Application.put_env(:mave_core, :flow_admin, emails: [], email_domains: ["mave.io"])

    on_exit(fn -> restore_env(:flow_admin, old_flow_admin_config) end)
  end

  test "dashboard access follows configured flow admin domains" do
    assert Admin.dashboard_enabled_for?(%{email: "ops@mave.io"}, %{})
    refute Admin.dashboard_enabled_for?(%{email: "customer@example.com"}, %{})
  end

  test "global diagnostics include dependency, queue, execution, and total timings" do
    space = create_user_space!("ops-failed")
    failed_run = create_failed_run!(space.hash, "LeDE9v86ye")

    diagnostics = Diagnostics.global_diagnostics(limit: 10)

    assert diagnostics.status_counts.failed >= 1
    assert diagnostics.performance.since_hours == 24
    assert diagnostics.performance.runs.total >= 1
    assert diagnostics.performance.runs.failed >= 1
    assert diagnostics.performance.runs.avg_duration_ms == 600_000
    assert diagnostics.performance.runs.p95_duration_ms == 600_000
    assert Enum.sum(Enum.map(diagnostics.performance.throughput, & &1.total)) >= 1

    assert run = Enum.find(diagnostics.attention_runs, &(&1.id == failed_run.id))
    assert run.reason == :failed
    assert run.run_duration_ms == 600_000
    assert run.step_dependency_wait_ms == 120_000
    assert run.step_queue_wait_ms == 180_000
    assert run.step_execution_ms == 240_000
    assert run.step_ready_total_ms == 540_000
    assert run.execution_metadata["executor"] == "flame"
    assert get_in(run.execution_metadata, ["runtime", "node_name"]) == "compute-node-1"
    assert run.flow_version_number == 1
    assert Enum.map(run.steps, & &1.step_id) == ["source", "manifest"]

    assert manifest_step = Enum.find(run.steps, &(&1.step_id == "manifest"))
    assert manifest_step.step_dependency_wait_ms == 120_000
    assert manifest_step.step_queue_wait_ms == 180_000
    assert manifest_step.step_execution_ms == 240_000
    assert manifest_step.step_ready_total_ms == 540_000
    assert manifest_step.execution_metadata["executor"] == "flame"

    assert manifest_metric =
             Enum.find(diagnostics.performance.step_metrics, &(&1.step_type == "manifest.build"))

    assert manifest_metric.count == 1
    assert manifest_metric.avg_dependency_wait_ms == 120_000
    assert manifest_metric.avg_queue_wait_ms == 180_000
    assert manifest_metric.p95_queue_wait_ms == 180_000
    assert manifest_metric.avg_execution_ms == 240_000
    assert manifest_metric.p95_execution_ms == 240_000
    assert manifest_metric.avg_ready_total_ms == 540_000
    assert manifest_metric.p95_ready_total_ms == 540_000
  end

  test "global diagnostics resolves embeds from the owning shared trial space" do
    other_space = create_trial_space!("ops-trial-other")
    space = create_trial_space!("ops-trial-target")

    assert {:ok, _other_embed} = Embeds.create_video_embed(other_space, %{"name" => "Other"})
    assert {:ok, embed} = Embeds.create_video_embed(space, %{"name" => "Target"})

    succeeded_run = create_succeeded_run!(space.hash, embed.hash)

    diagnostics = Diagnostics.global_diagnostics(limit: 10, status: "succeeded")

    assert run = Enum.find(diagnostics.attention_runs, &(&1.id == succeeded_run.id))
    assert run.space_hash == Space.shared_trial_hash()
    assert run.space_id == space.id
    assert run.embed_hash == embed.hash
    assert run.embed.id == embed.id
    assert run.dashboard_embed_id == Embeds.dashboard_embed_id(embed)
    assert run.public_embed_id == "#{space.hash}#{embed.hash}"
  end

  test "global diagnostics focus the latest completed step for succeeded runs" do
    space = create_user_space!("ops-succeeded")
    succeeded_run = create_succeeded_run!(space.hash, "SucceededTiming")

    diagnostics = Diagnostics.global_diagnostics(limit: 10, status: "succeeded")

    assert run = Enum.find(diagnostics.attention_runs, &(&1.id == succeeded_run.id))
    assert run.reason == :succeeded
    assert run.step_id == "manifest"
    assert run.step_status == "succeeded"
    assert run.step_dependency_wait_ms == 120_000
    assert run.step_queue_wait_ms == 180_000
    assert run.step_execution_ms == 240_000
    assert run.step_ready_total_ms == 540_000
    assert Enum.map(run.steps, & &1.step_id) == ["source", "manifest"]

    assert manifest_step = Enum.find(run.steps, &(&1.step_id == "manifest"))
    assert manifest_step.step_status == "succeeded"
    assert manifest_step.step_dependency_wait_ms == 120_000
    assert manifest_step.step_queue_wait_ms == 180_000
    assert manifest_step.step_execution_ms == 240_000
    assert manifest_step.step_ready_total_ms == 540_000
  end

  test "global diagnostics aggregate ffmpeg performance by hardware and workload" do
    space = create_user_space!("ops-ffmpeg-performance")
    succeeded_run = create_succeeded_run!(space.hash, "FfmpegPerformance")

    StepRun
    |> Repo.get_by!(flow_run_id: succeeded_run.id, step_id: "manifest")
    |> StepRun.changeset(%{
      execution_metadata: %{
        "executor" => "flame",
        "runtime" => %{"hardware_profile" => "scaleway-gp1-s"},
        "progress" => %{
          "source" => "ffmpeg",
          "status" => "completed",
          "codec" => "h264",
          "size" => "ladder",
          "variants" => ["sd", "hd"],
          "preset" => "veryfast",
          "fps" => 72.5,
          "speed_x" => 2.4,
          "ffmpeg_elapsed_ms" => 24_800
        }
      }
    })
    |> Repo.update!()

    diagnostics = Diagnostics.global_diagnostics(limit: 10, status: "succeeded")

    assert [metric] = diagnostics.performance.ffmpeg_metrics
    assert metric.hardware_profile == "scaleway-gp1-s"
    assert metric.step_type == "manifest.build"
    assert metric.codec == "h264"
    assert metric.size == "ladder"
    assert Jason.decode!(metric.variants) == ["sd", "hd"]
    assert metric.preset == "veryfast"
    assert metric.count == 1
    assert metric.p50_speed_x == 2.4
    assert metric.p10_speed_x == 2.4
    assert metric.avg_fps == 72.5
    assert metric.p95_ffmpeg_elapsed_ms == 24_800
  end

  test "global diagnostics can drill into runs by step type" do
    space = create_user_space!("ops-drilldown")
    succeeded_run = create_succeeded_run!(space.hash, "DrilldownTiming")

    diagnostics =
      Diagnostics.global_diagnostics(limit: 10, status: "succeeded", step_type: "source.resolve")

    assert diagnostics.step_type_filter == "source.resolve"
    assert run = Enum.find(diagnostics.attention_runs, &(&1.id == succeeded_run.id))
    assert run.reason == :succeeded
    assert run.selected_step_type == "source.resolve"
    assert run.step_id == "source"
    assert run.step_type == "source.resolve"
    assert run.step_status == "succeeded"
    assert run.step_dependency_wait_ms == 10_000
    assert run.step_queue_wait_ms == 10_000
    assert run.step_execution_ms == 10_000
    assert run.step_ready_total_ms == 30_000
  end

  test "run diagnostics returns one matching summarized run" do
    space = create_user_space!("ops-single-run")
    succeeded_run = create_succeeded_run!(space.hash, "SingleRunTiming")

    assert run =
             Diagnostics.run_diagnostics(succeeded_run.id,
               status: "succeeded",
               step_type: "manifest.build"
             )

    assert run.id == succeeded_run.id
    assert run.embed_hash == "SingleRunTiming"
    assert run.step_id == "manifest"
    assert run.step_type == "manifest.build"

    refute Diagnostics.run_diagnostics(succeeded_run.id, status: "failed")
    refute Diagnostics.run_diagnostics(succeeded_run.id, step_type: "missing.step")
  end

  test "global diagnostics can filter runs by run inserted time" do
    space = create_user_space!("ops-time-window")
    succeeded_run = create_succeeded_run!(space.hash, "WindowTiming")

    time_window =
      {DateTime.add(succeeded_run.inserted_at, -1, :second),
       DateTime.add(succeeded_run.inserted_at, 1, :second)}

    diagnostics =
      Diagnostics.global_diagnostics(limit: 10, status: "succeeded", time_window: time_window)

    assert diagnostics.time_window_filter
    assert Enum.any?(diagnostics.attention_runs, &(&1.id == succeeded_run.id))

    missed_window =
      {DateTime.add(succeeded_run.inserted_at, -2 * 60 * 60, :second),
       DateTime.add(succeeded_run.inserted_at, -60 * 60, :second)}

    diagnostics =
      Diagnostics.global_diagnostics(limit: 10, status: "succeeded", time_window: missed_window)

    refute Enum.any?(diagnostics.attention_runs, &(&1.id == succeeded_run.id))
  end

  test "dependency-blocked queued steps do not make an active run stale" do
    space = create_user_space!("ops-queued-not-stale")
    {:ok, template} = Flow.create_template(%{"slug" => unique_hash("queued"), "name" => "Queued"})
    {:ok, _version} = Flow.create_version(template.id, %{"definition" => @definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{"space_hash" => space.hash, "embed_hash" => "QueuedDependency"},
        enqueue: false
      )

    old = DateTime.add(DateTime.utc_now(), -30, :minute)

    from(step in StepRun, where: step.flow_run_id == ^run.id)
    |> Repo.update_all(set: [updated_at: old])

    diagnostics = Diagnostics.global_diagnostics(limit: 10, stale_minutes: 5)

    assert summary = Enum.find(diagnostics.attention_runs, &(&1.id == run.id))
    assert summary.reason == :waiting
    assert summary.step_status == "queued"
    assert diagnostics.status_counts.waiting >= 1
  end

  test "active diagnostics distinguish executing work from waiting work" do
    space = create_user_space!("ops-executing")

    {:ok, template} =
      Flow.create_template(%{"slug" => unique_hash("executing"), "name" => "Executing"})

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => @definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{"space_hash" => space.hash, "embed_hash" => "ExecutingWork"},
        enqueue: false
      )

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    StepRun
    |> Repo.get_by!(flow_run_id: run.id, step_id: "source")
    |> StepRun.changeset(%{status: "executing", started_at: now})
    |> Repo.update!()

    diagnostics = Diagnostics.global_diagnostics(limit: 10, stale_minutes: 5)

    assert summary = Enum.find(diagnostics.attention_runs, &(&1.id == run.id))
    assert summary.reason == :executing
    assert summary.step_id == "source"
    assert summary.step_status == "executing"
    assert diagnostics.status_counts.executing >= 1
  end

  test "active diagnostics distinguish playable runs with background work" do
    space = create_user_space!("ops-playable-background")

    definition = %{
      "steps" =>
        @definition["steps"] ++
          [
            %{
              "id" => "background",
              "type" => "event.notify_webhook",
              "name" => "Background work",
              "depends_on" => ["manifest"],
              "lane" => "background",
              "required" => false
            }
          ]
    }

    {:ok, template} =
      Flow.create_template(%{"slug" => unique_hash("playable"), "name" => "Playable"})

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{"space_hash" => space.hash, "embed_hash" => "PlayableBackground"},
        enqueue: false
      )

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for step_id <- ["source", "manifest"] do
      StepRun
      |> Repo.get_by!(flow_run_id: run.id, step_id: step_id)
      |> StepRun.changeset(%{status: "succeeded", started_at: now, completed_at: now})
      |> Repo.update!()
    end

    diagnostics = Diagnostics.global_diagnostics(limit: 10, stale_minutes: 5)

    assert summary = Enum.find(diagnostics.attention_runs, &(&1.id == run.id))
    assert summary.published?
    assert summary.reason == :waiting
    assert diagnostics.status_counts.published_background >= 1
    assert diagnostics.status_counts.awaiting_work >= 1
  end

  test "old scheduled work still makes an active run stale" do
    space = create_user_space!("ops-scheduled-stale")

    {:ok, template} =
      Flow.create_template(%{"slug" => unique_hash("scheduled"), "name" => "Scheduled"})

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => @definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{"space_hash" => space.hash, "embed_hash" => "ScheduledWork"},
        enqueue: false
      )

    assert {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)
    old = DateTime.add(DateTime.utc_now(), -30, :minute)

    from(step in StepRun,
      where: step.flow_run_id == ^run.id and step.status == "scheduled"
    )
    |> Repo.update_all(set: [updated_at: old])

    diagnostics = Diagnostics.global_diagnostics(limit: 10, stale_minutes: 5)

    assert summary = Enum.find(diagnostics.attention_runs, &(&1.id == run.id))
    assert summary.reason == :stale_step
    assert summary.step_status == "scheduled"
  end

  test "retry_step_for_space refuses runs from another space" do
    space = create_user_space!("ops-retry")
    other_space = create_user_space!("ops-retry-other")
    run = create_failed_run!(other_space.hash, "OtherRetry1")

    assert {:error, :not_found} =
             Diagnostics.retry_step_for_space(space, run.id, "manifest")
  end

  test "retry_step_for_embed permits the current embed" do
    space = create_user_space!("ops-embed-retry")
    assert {:ok, embed} = Embeds.create_video_embed(space, %{"name" => "Retry target"})
    run = create_failed_run!(space.hash, embed.hash)

    assert {:ok, %Run{id: run_id}} =
             Diagnostics.retry_step_for_embed(space, embed, run.id, "manifest")

    assert run_id == run.id
  end

  test "retry_step_for_embed refuses another embed when spaces share a hash" do
    space = create_trial_space!("ops-embed-retry-shared")
    other_space = create_trial_space!("ops-embed-retry-shared-other")
    assert space.hash == other_space.hash

    assert {:ok, embed} = Embeds.create_video_embed(space, %{"name" => "Retry target"})

    assert {:ok, other_embed} =
             Embeds.create_video_embed(other_space, %{"name" => "Foreign retry target"})

    run = create_failed_run!(other_space.hash, other_embed.hash)

    assert {:error, :not_found} =
             Diagnostics.retry_step_for_embed(space, embed, run.id, "manifest")

    assert Repo.get!(Run, run.id).status == "failed"
    assert Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "manifest").status == "failed"
  end

  defp create_user_space!(prefix) do
    {:ok, user} =
      Accounts.create_user("#{prefix}-#{System.unique_integer([:positive])}@example.com")

    user.current_space_membership.space
    |> Space.create_changeset(%{hash: unique_hash(prefix), region: "eu_3"})
    |> Repo.update!()
  end

  defp create_trial_space!(prefix) do
    prefix
    |> create_user_space!()
    |> Space.create_changeset(%{hash: Space.shared_trial_hash(), region: "eu_3"})
    |> Repo.update!()
  end

  defp unique_hash(prefix) do
    digest =
      :crypto.hash(:sha, "#{prefix}-#{System.unique_integer([:positive])}")
      |> Base.encode16(case: :lower)

    String.slice(digest, 0, 5)
  end

  defp create_failed_run!(space_hash, embed_hash) do
    create_terminal_run!(space_hash, embed_hash, "failed")
  end

  defp create_succeeded_run!(space_hash, embed_hash) do
    create_terminal_run!(space_hash, embed_hash, "succeeded")
  end

  defp create_terminal_run!(space_hash, embed_hash, status) do
    slug = "ops_#{System.unique_integer([:positive])}"
    {:ok, template} = Flow.create_template(%{"slug" => slug, "name" => "Ops Publish"})
    {:ok, _version} = Flow.create_version(template.id, %{"definition" => @definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => space_hash,
          "embed_hash" => embed_hash,
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    source_inserted_at = DateTime.add(now, -580, :second)
    source_scheduled_at = DateTime.add(now, -570, :second)
    source_started_at = DateTime.add(now, -560, :second)
    source_completed_at = DateTime.add(now, -550, :second)
    step_inserted_at = DateTime.add(now, -540, :second)
    step_scheduled_at = DateTime.add(now, -420, :second)
    step_started_at = DateTime.add(now, -240, :second)

    update_step_run!(
      run.id,
      "source",
      %{
        status: "succeeded",
        attempt: 1,
        scheduled_at: source_scheduled_at,
        started_at: source_started_at,
        completed_at: source_completed_at,
        execution_metadata: %{
          "executor" => "inline",
          "runtime" => %{
            "pod_name" => "mave-core-blue-1",
            "node_name" => "api-node-1",
            "pod_ip" => "10.0.0.10"
          }
        }
      },
      source_inserted_at
    )

    update_step_run!(
      run.id,
      "manifest",
      %{
        status: status,
        attempt: 1,
        error: if(status == "failed", do: "ffmpeg exited 1"),
        scheduled_at: step_scheduled_at,
        started_at: step_started_at,
        completed_at: now,
        execution_metadata: %{
          "executor" => "flame",
          "flame_call_ms" => 240_000,
          "runtime" => %{
            "pod_name" => "flame-runner-a",
            "node_name" => "compute-node-1",
            "pod_ip" => "10.0.1.20"
          }
        }
      },
      step_inserted_at
    )

    run
    |> Run.changeset(%{
      status: status,
      error: if(status == "failed", do: "required step failed"),
      started_at: DateTime.add(now, -600, :second),
      completed_at: now
    })
    |> Repo.update!()
  end

  defp update_step_run!(run_id, step_id, attrs, inserted_at) do
    StepRun
    |> Repo.get_by!(flow_run_id: run_id, step_id: step_id)
    |> Ecto.Changeset.change(inserted_at: inserted_at)
    |> Repo.update!()
    |> StepRun.changeset(attrs)
    |> Repo.update!()
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)
end
