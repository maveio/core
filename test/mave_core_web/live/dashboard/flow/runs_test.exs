defmodule MaveCoreWeb.Live.Dashboard.Flow.RunsTest do
  use MaveCoreWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MaveCore.Accounts
  alias MaveCore.Embeds
  alias MaveCore.Flow
  alias MaveCore.Flow.Run
  alias MaveCore.Flow.StepRun
  alias MaveCore.Repo

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
    old_inspection_actions = Application.get_env(:mave_core, :flow_runs_inspection_actions)

    Application.put_env(:mave_core, :flow_admin, emails: [], email_domains: ["mave.io"])

    on_exit(fn ->
      restore_env(:flow_admin, old_flow_admin_config)
      restore_env(:flow_runs_inspection_actions, old_inspection_actions)
    end)
  end

  test "/flow/runs is only available to flow admins", %{conn: conn} do
    {_user, conn} = authenticated_conn(conn, "runs-customer@example.com")

    assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/flow/runs")
    assert String.ends_with?(to, "/videos")
  end

  test "/flow/runs renders durable dependency, queue, execution, and total timing data", %{
    conn: conn
  } do
    {admin, conn} = authenticated_conn(conn, "runs-admin@mave.io")
    space = admin.current_space_membership.space

    Application.put_env(
      :mave_core,
      :flow_runs_inspection_actions,
      {__MODULE__, :flow_runs_inspection_actions}
    )

    run = create_failed_run!(space.hash, "FailedRuntime")

    {:ok, view, html} = live(conn, "/flow/runs")

    assert html =~ "Runs"
    assert html =~ "Timing"
    assert html =~ "Performance"
    assert html =~ "Throughput"
    assert html =~ "Slowest steps"
    assert html =~ "Flow p95"
    assert html =~ "Queue p95"
    assert html =~ "Exec p95"
    assert html =~ "Last 24h"
    assert html =~ "P95 queue"
    assert html =~ "inspect-step-manifest-build"
    assert html =~ "flame / compute-node-1"
    assert html =~ "FailedRuntime"
    assert html =~ "2 steps"
    assert html =~ "total 10m"
    assert html =~ "step total 9m"
    assert html =~ "deps 2m / queue 3m / exec 4m"
    assert html =~ "Metrics run"
    assert html =~ "https://grafana.example/runs/#{run.id}"
    assert has_element?(view, "#flow-runs-scroll[phx-hook='preserve_scroll']")
    assert has_element?(view, "#flow-runs-table[role='table']")
    assert has_element?(view, "#toggle-run-#{run.id}")

    html =
      view
      |> element("#inspect-step-manifest-build")
      |> render_click()

    assert html =~ "Inspecting"
    assert html =~ "manifest.build"
    assert html =~ "in the runs below"
    assert html =~ "Clear"
    assert html =~ "FailedRuntime"

    html = render_click(view, "toggle_steps", %{"run-id" => run.id})

    assert html =~ "source.resolve"
    assert html =~ "manifest.build"
    assert html =~ "Executor"
    assert html =~ "inline / api-node-1"
    assert html =~ "flame-runner-a"
    assert html =~ "flame call 4m"
    assert html =~ "Metrics manifest"
    assert html =~ "https://grafana.example/steps/manifest"
    assert html =~ "attempt 1"
    assert html =~ "2 steps"
  end

  test "/flow/runs renders timing data for succeeded runs", %{conn: conn} do
    {admin, conn} = authenticated_conn(conn, "runs-succeeded-admin@mave.io")
    space = admin.current_space_membership.space

    run = create_succeeded_run!(space.hash, "SucceededRuntime")

    {:ok, view, html} = live(conn, "/flow/runs?status=succeeded")

    assert html =~ "SucceededRuntime"
    assert html =~ "manifest.build"
    assert html =~ "2 steps"
    assert html =~ "total 10m"
    assert html =~ "step total 9m"
    assert html =~ "deps 2m / queue 3m / exec 4m"

    html = render_click(view, "toggle_steps", %{"run-id" => run.id})

    assert html =~ "source.resolve"
    assert html =~ "manifest.build"
    assert html =~ "succeeded"
    assert html =~ "retry-step-#{run.id}-manifest"
    assert html =~ "2 steps"

    html =
      view
      |> element("#retry-step-#{run.id}-manifest")
      |> render_click()

    assert html =~ "Flow step retried"
  end

  test "/flow/runs labels published runs that continue background work", %{conn: conn} do
    {admin, conn} = authenticated_conn(conn, "runs-playable-admin@mave.io")
    space = admin.current_space_membership.space

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

    {:ok, _view, html} = live(conn, "/flow/runs?status=running")

    assert html =~ "awaiting work"
    assert html =~ "playable/background"
    assert html =~ "playable · background work"
  end

  test "/flow/runs displays the public embed id for current embeds", %{conn: conn} do
    {admin, conn} = authenticated_conn(conn, "runs-public-id-admin@mave.io")
    space = admin.current_space_membership.space
    assert {:ok, embed} = Embeds.create_video_embed(space, %{"name" => "Public ID"})

    _run = create_failed_run!(space.hash, embed.hash)

    {:ok, _view, html} = live(conn, "/flow/runs?status=failed")

    assert html =~ "#{space.hash}#{embed.hash}"
  end

  test "/flow/runs renders ffmpeg performance by step and hardware", %{conn: conn} do
    {admin, conn} = authenticated_conn(conn, "runs-ffmpeg-admin@mave.io")
    space = admin.current_space_membership.space

    run = create_succeeded_run!(space.hash, "FfmpegRuntime")
    put_ffmpeg_performance!(run.id)

    {:ok, view, html} = live(conn, "/flow/runs?status=succeeded")

    assert html =~ "FFmpeg by hardware"
    assert html =~ "scaleway-gp1-s"
    assert html =~ "Median speed"
    assert html =~ "P10 speed"
    assert html =~ "2.4× realtime"
    assert html =~ "72.5 fps"
    assert html =~ "24s FFmpeg"
    assert html =~ "sd, hd"
    assert html =~ "preset veryfast"

    html = render_click(view, "toggle_steps", %{"run-id" => run.id})

    assert html =~ "scaleway-gp1-s / flame-runner-b"
    assert html =~ "2.4× realtime / 72.5 fps / 24s FFmpeg"
  end

  test "/flow/runs shows whether ladder steps used the encoding booster", %{conn: conn} do
    {admin, conn} = authenticated_conn(conn, "runs-booster-admin@mave.io")
    space = admin.current_space_membership.space

    used_run = create_succeeded_run!(space.hash, "BoosterUsedRuntime")

    put_booster_execution!(used_run.id, %{
      "executor" => "encoding_booster",
      "encoding_booster_attempted" => true,
      "encoding_booster_used" => true,
      "progress" => %{
        "source" => "encoding_booster",
        "status" => "executing",
        "stage" => "transcode",
        "percent" => 42.0,
        "speed_x" => 2.4,
        "ffmpeg_elapsed_ms" => 24_800
      }
    })

    fallback_run = create_succeeded_run!(space.hash, "BoosterFallbackRuntime")

    put_booster_execution!(fallback_run.id, %{
      "executor" => "flame",
      "encoding_booster_attempted" => true,
      "encoding_booster_used" => false,
      "encoding_booster_fallback" => "busy"
    })

    unused_run = create_succeeded_run!(space.hash, "BoosterUnusedRuntime")

    put_booster_execution!(unused_run.id, %{
      "executor" => "flame",
      "encoding_booster_attempted" => false,
      "encoding_booster_used" => false
    })

    {:ok, view, html} = live(conn, "/flow/runs?status=succeeded")

    assert html =~ "Booster used"
    assert html =~ "Booster → FLAME (busy)"
    assert html =~ "Booster not used"
    assert html =~ "~2.4× realtime / 24s FFmpeg"
    refute html =~ "~42% encoding (estimated)"

    html = render_click(view, "toggle_steps", %{"run-id" => used_run.id})
    assert html =~ "Booster used"
  end

  test "/flow/runs identifies GPU booster use and CPU fallback", %{conn: conn} do
    {admin, conn} = authenticated_conn(conn, "runs-gpu-booster-admin@mave.io")
    space = admin.current_space_membership.space

    used_run = create_succeeded_run!(space.hash, "GpuBoosterUsedRuntime")

    put_booster_execution!(used_run.id, %{
      "executor" => "gpu_encoding_booster",
      "gpu_encoding_booster_attempted" => true,
      "gpu_encoding_booster_used" => true
    })

    fallback_run = create_succeeded_run!(space.hash, "GpuBoosterFallbackRuntime")

    put_booster_execution!(fallback_run.id, %{
      "executor" => "encoding_booster",
      "gpu_encoding_booster_attempted" => true,
      "gpu_encoding_booster_used" => false,
      "gpu_encoding_booster_fallback" => "busy",
      "encoding_booster_attempted" => true,
      "encoding_booster_used" => true
    })

    {:ok, _view, html} = live(conn, "/flow/runs?status=succeeded")

    assert html =~ "GPU Booster used"
    assert html =~ "GPU Booster → CPU Booster (busy)"
  end

  test "/flow/runs can recover a failed run", %{conn: conn} do
    {admin, conn} = authenticated_conn(conn, "runs-recover-admin@mave.io")
    space = admin.current_space_membership.space

    run = create_failed_run!(space.hash, "RecoverRuntime")

    {:ok, view, html} = live(conn, "/flow/runs")

    assert html =~ "RecoverRuntime"
    assert html =~ "recover-run-#{run.id}"

    html =
      view
      |> element("#recover-run-#{run.id}")
      |> render_click()

    assert html =~ "Flow recovery started"
  end

  test "/flow/runs applies live updates to the matching run without resorting rows", %{conn: conn} do
    {admin, conn} = authenticated_conn(conn, "runs-live-update-admin@mave.io")
    space = admin.current_space_membership.space

    older_run = create_succeeded_run!(space.hash, "OlderLiveRuntime")
    newer_run = create_succeeded_run!(space.hash, "NewerLiveRuntime")

    {:ok, view, html} = live(conn, "/flow/runs")

    assert_row_before(html, newer_run.id, older_run.id)

    fail_run!(older_run, "live update failed")
    Flow.Events.broadcast_updated(older_run.id, %{"status" => "failed"})

    html = render(view)

    assert_row_before(html, newer_run.id, older_run.id)
    assert has_element?(view, "#run-row-#{older_run.id}", "live update failed")
    assert has_element?(view, "#run-row-#{older_run.id}", "failed")
    assert has_element?(view, "#run-row-#{newer_run.id}", "NewerLiveRuntime")
    refute has_element?(view, "#run-row-#{newer_run.id}", "live update failed")
  end

  test "/flow/runs ignores realtime updates for runs outside the current page", %{conn: conn} do
    {admin, conn} = authenticated_conn(conn, "runs-offscreen-update-admin@mave.io")
    space = admin.current_space_membership.space

    visible_run = create_succeeded_run!(space.hash, "VisibleLiveRuntime")
    {:ok, view, html} = live(conn, "/flow/runs")

    assert html =~ visible_run.id

    offscreen_run = create_succeeded_run!(space.hash, "OffscreenLiveRuntime")
    Flow.Events.broadcast_updated(offscreen_run.id, %{"status" => "succeeded"})

    html = render(view)

    assert html =~ visible_run.id
    refute html =~ offscreen_run.id
  end

  test "/flow/runs can focus the run list on a selected step type", %{conn: conn} do
    {admin, conn} = authenticated_conn(conn, "runs-step-drilldown-admin@mave.io")
    space = admin.current_space_membership.space

    _run = create_succeeded_run!(space.hash, "SourceRuntime")

    {:ok, _view, html} = live(conn, "/flow/runs?status=succeeded&step_type=source.resolve")

    assert html =~ "Inspecting"
    assert html =~ "source.resolve"
    assert html =~ "SourceRuntime"
    assert html =~ "step total 30s"
    assert html =~ "deps 10s / queue 10s / exec 10s"
  end

  test "/flow/runs renders multi-part durations for cold starts", %{conn: conn} do
    {admin, conn} = authenticated_conn(conn, "runs-cold-start-admin@mave.io")
    space = admin.current_space_membership.space

    _run =
      create_succeeded_run!(space.hash, "ColdStartRuntime",
        seconds: [run: 615, manifest: 163, dependency: 46, queue: 62]
      )

    {:ok, _view, html} = live(conn, "/flow/runs?status=succeeded")

    assert html =~ "ColdStartRuntime"
    assert html =~ "total 10m 15s"
    assert html =~ "step total 2m 43s"
    assert html =~ "deps 46s / queue 1m 2s / exec 55s"
  end

  test "/flow/runs can focus the run list from a throughput bucket", %{conn: conn} do
    {admin, conn} = authenticated_conn(conn, "runs-throughput-admin@mave.io")
    space = admin.current_space_membership.space

    selected_run = create_succeeded_run!(space.hash, "BucketRuntime")

    space.hash
    |> create_succeeded_run!("OldBucketRuntime")
    |> move_run_inserted_at!(DateTime.add(selected_run.inserted_at, -2 * 60 * 60, :second))

    bucket = hour_bucket(selected_run.inserted_at)
    bucket_id = "throughput-bucket-#{DateTime.to_unix(bucket)}"

    {:ok, view, html} = live(conn, "/flow/runs?status=succeeded")

    assert html =~ "BucketRuntime"
    assert html =~ "OldBucketRuntime"
    assert html =~ bucket_id

    html =
      view
      |> element("##{bucket_id}")
      |> render_click()

    assert html =~ "Inspecting"
    assert html =~ "UTC"
    assert html =~ "Clear time"
    assert html =~ "BucketRuntime"
    refute html =~ "OldBucketRuntime"
  end

  defp authenticated_conn(conn, email) do
    assert {:ok, user} = Accounts.create_user(email)
    login_token = Accounts.generate_user_login_token(user)
    assert {:ok, {logged_in_user, persisted_login_token}} = Accounts.login_user(login_token)
    session_token = Accounts.generate_user_session_token(persisted_login_token, logged_in_user)

    conn =
      conn
      |> with_manage_host()
      |> init_test_session(user_token: session_token)

    {logged_in_user, conn}
  end

  defp create_failed_run!(space_hash, embed_hash) do
    create_terminal_run!(space_hash, embed_hash, "failed")
  end

  defp unique_hash(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp create_succeeded_run!(space_hash, embed_hash) do
    create_terminal_run!(space_hash, embed_hash, "succeeded")
  end

  defp create_succeeded_run!(space_hash, embed_hash, opts) do
    create_terminal_run!(space_hash, embed_hash, "succeeded", opts)
  end

  defp create_terminal_run!(space_hash, embed_hash, status, opts \\ []) do
    slug = "runs_#{System.unique_integer([:positive])}"
    {:ok, template} = Flow.create_template(%{"slug" => slug, "name" => "Runs Publish"})
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
    seconds = Keyword.get(opts, :seconds, [])
    run_seconds = Keyword.get(seconds, :run, 600)
    manifest_seconds = Keyword.get(seconds, :manifest, 540)
    dependency_seconds = Keyword.get(seconds, :dependency, 120)
    queue_seconds = Keyword.get(seconds, :queue, 180)
    execution_seconds = max(manifest_seconds - dependency_seconds - queue_seconds, 0)

    source_inserted_at = DateTime.add(now, -580, :second)
    source_scheduled_at = DateTime.add(now, -570, :second)
    source_started_at = DateTime.add(now, -560, :second)
    source_completed_at = DateTime.add(now, -550, :second)
    step_inserted_at = DateTime.add(now, -manifest_seconds, :second)
    step_scheduled_at = DateTime.add(now, -(manifest_seconds - dependency_seconds), :second)
    step_started_at = DateTime.add(now, -execution_seconds, :second)

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
          "flame_call_ms" => execution_seconds * 1000,
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
      started_at: DateTime.add(now, -run_seconds, :second),
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

  defp put_ffmpeg_performance!(run_id) do
    StepRun
    |> Repo.get_by!(flow_run_id: run_id, step_id: "manifest")
    |> StepRun.changeset(%{
      execution_metadata: %{
        "executor" => "flame",
        "runtime" => %{
          "hardware_profile" => "scaleway-gp1-s",
          "pod_name" => "flame-runner-b",
          "node_name" => "media-node-1"
        },
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
  end

  defp put_booster_execution!(run_id, execution_metadata) do
    StepRun
    |> Repo.get_by!(flow_run_id: run_id, step_id: "manifest")
    |> StepRun.changeset(%{
      step_type: "media.transcode_h264_ladder",
      execution_metadata: execution_metadata
    })
    |> Repo.update!()
  end

  defp move_run_inserted_at!(run, inserted_at) do
    run
    |> Ecto.Changeset.change(inserted_at: inserted_at)
    |> Repo.update!()
  end

  defp fail_run!(run, error) do
    run
    |> Run.changeset(%{
      status: "failed",
      error: error,
      completed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
    |> Repo.update!()
  end

  defp assert_row_before(html, first_run_id, second_run_id) do
    assert {first_index, _} = :binary.match(html, "run-row-#{first_run_id}")
    assert {second_index, _} = :binary.match(html, "run-row-#{second_run_id}")
    assert first_index < second_index
  end

  defp hour_bucket(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> Map.put(:minute, 0)
    |> Map.put(:second, 0)
  end

  defp with_manage_host(conn) do
    case System.get_env("MAVE_MANAGE_HOST") do
      host when is_binary(host) and host != "" -> %{conn | host: host}
      _ -> conn
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)

  def flow_runs_inspection_actions(%{run: run, step: nil}) do
    [%{label: "Metrics run", to: "https://grafana.example/runs/#{run.id}"}]
  end

  def flow_runs_inspection_actions(%{step: step}) do
    [%{label: "Metrics #{step.step_id}", to: "https://grafana.example/steps/#{step.step_id}"}]
  end
end
