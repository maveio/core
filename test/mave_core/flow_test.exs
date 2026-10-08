defmodule MaveCore.FlowTest do
  use MaveCore.DataCase, async: false

  alias MaveCore.Accounts
  alias MaveCore.Assets.{AudioTrack, Rendition, Subtitle, Video}
  alias MaveCore.Embeds
  alias MaveCore.Embeds.Embed
  alias MaveCore.Embeds.SettingsSerializer
  alias MaveCore.Flow
  alias MaveCore.Flow.{ArtifactRef, Presets, ProgressReporter, Run, StepRun, Template, Version}
  alias MaveCore.Flow.Events, as: FlowEvents
  alias MaveCore.Flow.Steps.Support, as: StepSupport
  alias MaveCore.Repo
  alias MaveCore.Spaces
  alias MaveCore.TestSupport.FlowStorageAdapterStub
  alias MaveCore.Uploads.Events, as: UploadEvents
  alias MaveCore.Workers.{FlowRecoveryWorker, FlowStepWorker}
  alias Oban.Job
  import Ecto.Query

  @definition %{
    "steps" => [
      %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"},
      %{
        "id" => "manifest",
        "type" => "manifest.build",
        "name" => "Build Manifest",
        "depends_on" => ["source"]
      },
      %{
        "id" => "notify",
        "type" => "event.notify_webhook",
        "name" => "Notify Webhook",
        "depends_on" => ["manifest"]
      }
    ]
  }

  @priority_definition %{
    "steps" => [
      %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"},
      %{
        "id" => "fast_manifest",
        "type" => "manifest.build",
        "name" => "Fast Manifest",
        "depends_on" => ["source"],
        "lane" => "fast"
      },
      %{
        "id" => "background_notify",
        "type" => "event.notify_webhook",
        "name" => "Background Notify",
        "depends_on" => ["source"],
        "lane" => "background"
      }
    ]
  }

  @optional_failure_definition %{
    "steps" => [
      %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"},
      %{
        "id" => "optional_notify",
        "type" => "event.notify_webhook",
        "name" => "Optional Notify",
        "depends_on" => ["source"],
        "required" => false,
        "params" => %{"strict" => true}
      },
      %{
        "id" => "manifest",
        "type" => "manifest.build",
        "name" => "Build Manifest",
        "depends_on" => ["source", "optional_notify"]
      }
    ]
  }

  @flame_failure_definition %{
    "steps" => [
      %{"id" => "video", "type" => "media.transcode_video", "name" => "Transcode Video"}
    ]
  }

  @booster_definition %{
    "steps" => [
      %{
        "id" => "video_h264_ladder",
        "type" => "media.transcode_h264_ladder",
        "name" => "Transcode H264 Ladder",
        "params" => %{"sizes" => ["sd"], "strict" => true}
      }
    ]
  }

  @gpu_booster_definition %{
    "steps" => [
      %{
        "id" => "video_h264_hd",
        "type" => "media.transcode_h264_ladder",
        "name" => "Transcode H264 HD",
        "params" => %{"sizes" => ["hd"], "strict" => true}
      }
    ]
  }

  @cpu_video_booster_definition %{
    "steps" => [
      %{
        "id" => "clip_h264_sd_keyframes",
        "type" => "media.transcode_video",
        "name" => "Transcode H264 SD Keyframes",
        "params" => %{
          "codec" => "h264",
          "size" => "sd",
          "container" => "mp4",
          "strict" => true
        }
      }
    ]
  }

  @hls_booster_definition %{
    "steps" => [
      %{
        "id" => "hls_h264_sd",
        "type" => "media.package_hls_variant",
        "name" => "Package HLS SD",
        "params" => %{"codec" => "h264", "size" => "sd", "strict" => true}
      }
    ]
  }

  defmodule AudioPeaksBoosterStub do
    def encode_to_file(_url, path, options) do
      if options[:operation] != "audio_peaks", do: raise("unexpected operation")
      File.write!(path, "lavfi.astats.Overall.Peak_level=-20.000000\n")
      {:ok, %{elapsed_ms: 1}}
    end
  end

  defmodule BusyEncodingBoosterAdapterStub do
    @moduledoc false

    def encode_to_file(_input_url, _output_path, _options),
      do: {:error, :encoding_booster_busy}

    def encode_to_storage(_input_url, _output_upload, _options),
      do: {:error, :encoding_booster_busy}
  end

  defmodule FailedEncodingBoosterAdapterStub do
    @moduledoc false

    def encode_to_file(_input_url, _output_path, _options),
      do: {:error, :synthetic_booster_failure}

    def encode_to_storage(_input_url, _output_upload, _options),
      do: {:error, :synthetic_booster_failure}
  end

  defmodule ChunkFailedEncodingBoosterAdapterStub do
    @moduledoc false

    def encode_to_storage(_input_url, _output_upload, _options),
      do: {:error, :encoding_booster_request_failed}
  end

  defmodule GatewayEncodingBoosterAdapterStub do
    @moduledoc false

    def encode_to_file(_input_url, _output_path, _options),
      do: {:error, {:encoding_booster_http_status, 502}}

    def encode_to_storage(_input_url, _output_upload, _options),
      do: {:error, {:encoding_booster_http_status, 502}}
  end

  @audio_hls_recovery_definition %{
    "steps" => [
      %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"},
      %{
        "id" => "transcode_audio",
        "type" => "media.transcode_audio",
        "name" => "Transcode Audio",
        "depends_on" => ["source"]
      },
      %{
        "id" => "hls_audio_default",
        "type" => "media.package_hls_audio",
        "name" => "Package HLS Audio",
        "depends_on" => ["transcode_audio"],
        "params" => %{"source_step_id" => "transcode_audio"}
      },
      %{
        "id" => "hls_master",
        "type" => "media.build_hls_master",
        "name" => "Build HLS Master",
        "depends_on" => ["hls_audio_default"]
      },
      %{
        "id" => "manifest",
        "type" => "manifest.build",
        "name" => "Build Manifest",
        "depends_on" => ["hls_master"]
      }
    ]
  }

  @parallel_hls_recovery_definition %{
    "steps" => [
      %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"},
      %{
        "id" => "video_h264_sd",
        "type" => "media.transcode_h264_ladder",
        "name" => "Transcode H264 SD",
        "depends_on" => ["source"]
      },
      %{
        "id" => "video_h264_hd",
        "type" => "media.transcode_h264_ladder",
        "name" => "Transcode H264 HD",
        "depends_on" => ["source"]
      },
      %{
        "id" => "video_h264_fhd",
        "type" => "media.transcode_h264_ladder",
        "name" => "Transcode H264 FHD",
        "depends_on" => ["source"]
      },
      %{
        "id" => "hls_h264_sd",
        "type" => "media.package_hls_variant",
        "name" => "Package HLS SD",
        "depends_on" => ["video_h264_sd"],
        "params" => %{"source_step_id" => "video_h264_sd"}
      },
      %{
        "id" => "hls_master_sd",
        "type" => "media.build_hls_master",
        "name" => "Build HLS Master",
        "depends_on" => ["hls_h264_sd"]
      },
      %{
        "id" => "manifest",
        "type" => "manifest.build",
        "name" => "Build Manifest",
        "depends_on" => ["hls_master_sd", "video_h264_hd", "video_h264_fhd"]
      }
    ]
  }

  setup do
    old_storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter)
    old_preset_overrides = Application.get_env(:mave_core, :flow_preset_overrides)
    old_retry_policy = Application.get_env(:mave_core, :flow_step_retry_policy)
    old_booster_config = Application.get_env(:mave_core, :encoding_booster)
    old_booster_adapter = Application.get_env(:mave_core, :encoding_booster_adapter)
    old_gpu_booster_config = Application.get_env(:mave_core, :gpu_encoding_booster)
    old_gpu_booster_adapter = Application.get_env(:mave_core, :gpu_encoding_booster_adapter)

    old_flame_caller = Application.get_env(:mave_core, :flow_flame_caller)

    Application.put_env(
      :mave_core,
      :flow_storage_adapter,
      MaveCore.TestSupport.FlowStorageAdapterStub
    )

    on_exit(fn ->
      restore_env(:flow_storage_adapter, old_storage_adapter)
      restore_env(:flow_preset_overrides, old_preset_overrides)
      restore_env(:flow_step_retry_policy, old_retry_policy)
      restore_env(:encoding_booster, old_booster_config)
      restore_env(:encoding_booster_adapter, old_booster_adapter)
      restore_env(:gpu_encoding_booster, old_gpu_booster_config)
      restore_env(:gpu_encoding_booster_adapter, old_gpu_booster_adapter)
      restore_env(:flow_flame_caller, old_flame_caller)
    end)

    :ok
  end

  test "starting a video flow persists and broadcasts the processing state" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "processing-state-#{System.unique_integer([:positive])}",
        "name" => "Processing State"
      })

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => @definition})

    space = space_fixture()
    {:ok, embed} = Embeds.create_video_embed(space, %{name: "Processing State"})

    {:ok, _embed} =
      Embeds.begin_video_upload(space.hash, embed.hash, %{
        "title" => "processing-state.mp4",
        "upload_size" => 12_345
      })

    MaveCore.Embeds.Events.subscribe(space.id, embed.id)

    assert {:ok, _run} =
             Flow.start_run(
               template.slug,
               %{"space_hash" => space.hash, "embed_hash" => embed.hash},
               enqueue: false
             )

    assert_receive {:embed_updated, %{"phase" => "processing"}}

    refreshed_embed = Repo.get!(Embed, embed.id) |> Repo.preload(asset: [:current_video])
    assert refreshed_embed.asset.current_video.status == "preparing"
  end

  test "reconcile only schedules dependency-ready steps" do
    {:ok, template} =
      Flow.create_template(%{"slug" => "dependency_publish", "name" => "Dependency Publish"})

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => @definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    source = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "source")
    manifest = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "manifest")
    notify = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "notify")

    assert source.status == "scheduled"
    assert %DateTime{} = source.scheduled_at
    assert manifest.status == "queued"
    assert is_nil(manifest.scheduled_at)
    assert notify.status == "queued"
    assert is_nil(notify.scheduled_at)
  end

  test "failed runs terminalize unfinished steps and recovery restarts them" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "terminalize-failed-#{System.unique_integer([:positive])}",
        "name" => "Terminalize Failed Run"
      })

    definition = %{
      "steps" => [
        %{"id" => "failed", "type" => "source.resolve", "name" => "Failed"},
        %{"id" => "executing", "type" => "source.resolve", "name" => "Executing"},
        %{"id" => "scheduled", "type" => "source.resolve", "name" => "Scheduled"},
        %{"id" => "queued", "type" => "source.resolve", "name" => "Queued"}
      ]
    }

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{"space_hash" => "ubg50", "embed_hash" => "Terminalize1"},
        enqueue: false
      )

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    mark_step!(run.id, "failed", %{
      status: "failed",
      error: "synthetic failure",
      completed_at: now
    })

    mark_step!(run.id, "executing", %{status: "executing", started_at: now})
    mark_step!(run.id, "scheduled", %{status: "scheduled", scheduled_at: now})

    assert {:ok, failed_run} = Flow.reconcile_run(run.id, enqueue_jobs: false)
    assert failed_run.status == "failed"

    step_runs = Map.new(failed_run.step_runs, &{&1.step_id, &1})
    assert step_runs["failed"].status == "failed"
    assert step_runs["executing"].status == "cancelled"
    assert step_runs["executing"].error == "interrupted because flow run failed"
    assert step_runs["scheduled"].status == "cancelled"
    assert step_runs["scheduled"].error == "not executed because flow run failed"
    assert step_runs["queued"].status == "cancelled"
    assert Enum.all?(Map.values(step_runs), &match?(%DateTime{}, &1.completed_at))

    assert {:ok, recovered_run} = Flow.recover_run(run.id, enqueue_jobs: false)
    assert recovered_run.status == "running"
    assert Enum.all?(recovered_run.step_runs, &(&1.status == "scheduled"))
  end

  test "manual step execution reaches succeeded run and records manifest artifact" do
    {:ok, template} =
      Flow.create_template(%{"slug" => "publish_audio", "name" => "Publish Audio"})

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => @definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    with_runtime_env(
      %{
        "POD_NAME" => "mave-core-blue-abc",
        "POD_NAMESPACE" => "mave-core",
        "POD_IP" => "10.42.0.10",
        "NODE_NAME" => "api-pool-node-1",
        "MAVE_RUNTIME_ROLE" => "worker",
        "MAVE_HARDWARE_PROFILE" => "scaleway-gp1-s"
      },
      fn ->
        assert {:ok, _source_output} =
                 Flow.execute_step(run.id, "source", enqueue_coordinator: false)
      end
    )

    source_step = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "source")
    assert source_step.execution_metadata["executor"] == "inline"
    assert get_in(source_step.execution_metadata, ["runtime", "pod_name"]) == "mave-core-blue-abc"
    assert get_in(source_step.execution_metadata, ["runtime", "node_name"]) == "api-pool-node-1"

    assert get_in(source_step.execution_metadata, ["runtime", "hardware_profile"]) ==
             "scaleway-gp1-s"

    assert is_binary(get_in(source_step.execution_metadata, ["runtime", "architecture"]))
    assert is_integer(get_in(source_step.execution_metadata, ["runtime", "schedulers_online"]))

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    assert {:ok, _manifest_output} =
             Flow.execute_step(run.id, "manifest", enqueue_coordinator: false)

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)
    assert {:ok, _notify_output} = Flow.execute_step(run.id, "notify", enqueue_coordinator: false)

    {:ok, final_run} = Flow.reconcile_run(run.id, enqueue_jobs: false)
    assert final_run.status == "succeeded"

    manifest_artifact =
      Repo.get_by!(ArtifactRef,
        flow_run_id: run.id,
        producer_step_id: "manifest",
        name: "manifest"
      )

    assert manifest_artifact.uri == "s3://space-ubg50/LeDE9v86ye/manifest.json"
  end

  test "unknown stored step type fails the step instead of leaving it executing" do
    {:ok, template} =
      Flow.create_template(%{"slug" => "unknown_step_publish", "name" => "Unknown Step Publish"})

    {:ok, version} = Flow.create_version(template.id, %{"definition" => @definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    unknown_definition =
      update_in(version.definition, ["steps"], fn [source | rest] ->
        [Map.put(source, "type", "custom.missing") | rest]
      end)

    version
    |> Ecto.Changeset.change(definition: unknown_definition)
    |> Repo.update!()

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    assert {:error, {:unknown_step_type, "custom.missing"}} =
             Flow.execute_step(run.id, "source", enqueue_coordinator: false)

    source = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "source")
    assert source.status == "failed"
    assert source.error =~ "unknown_step_type"
    assert %DateTime{} = source.completed_at

    {:ok, failed_run} = Flow.reconcile_run(run.id, enqueue_jobs: false)
    assert failed_run.status == "failed"
  end

  test "step execution includes durable media outputs beyond direct dependencies" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "ambient-source-#{System.unique_integer([:positive])}",
        "name" => "Ambient Source"
      })

    {:ok, _version} =
      Flow.create_version(template.id, %{
        "definition" => %{
          "steps" => [
            %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"},
            %{
              "id" => "upload_original",
              "type" => "asset.upload_original",
              "name" => "Upload Original",
              "depends_on" => ["source"]
            },
            %{
              "id" => "inspect_media",
              "type" => "media.inspect",
              "name" => "Inspect Media",
              "depends_on" => ["upload_original"]
            },
            %{
              "id" => "after_inspect",
              "type" => "embed.set_visibility",
              "name" => "After Inspect",
              "depends_on" => ["inspect_media"]
            },
            %{
              "id" => "consumer",
              "type" => "embed.set_visibility",
              "name" => "Consumer",
              "depends_on" => ["after_inspect"]
            }
          ]
        }
      })

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/ambient.mp4",
          "source_url" => "https://example.com/ambient.mp4",
          "source_body" => "stub-media-body",
          "source_content_type" => "video/mp4",
          "media_probe" => %{
            "duration" => 8.0,
            "size_bytes" => 15,
            "filetype" => "mp4",
            "aspect_ratio" => "16 / 9",
            "streams" => []
          }
        },
        enqueue: false
      )

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)
    assert {:ok, _source_output} = Flow.execute_step(run.id, "source", enqueue_coordinator: false)

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    assert {:ok, _upload_output} =
             Flow.execute_step(run.id, "upload_original", enqueue_coordinator: false)

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    assert {:ok, _inspect_output} =
             Flow.execute_step(run.id, "inspect_media", enqueue_coordinator: false)

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    assert {:ok, _after_inspect_output} =
             Flow.execute_step(run.id, "after_inspect", enqueue_coordinator: false)

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    assert {:ok, consumer_output} =
             Flow.execute_step(run.id, "consumer", enqueue_coordinator: false)

    dependency_outputs = get_in(consumer_output, ["input", "dependency_outputs"])

    assert dependency_outputs["inspect_media"]["step_type"] == "media.inspect"
    assert dependency_outputs["source"]["source_url"] == "https://example.com/ambient.mp4"
    assert dependency_outputs["upload_original"]["bucket"] == "space-ubg50"
    assert dependency_outputs["upload_original"]["original_key"] == "LeDE9v86ye/original"
  end

  test "reconcile prioritizes fast lane steps before background steps" do
    {:ok, template} =
      Flow.create_template(%{"slug" => "priority_publish", "name" => "Priority Publish"})

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => @priority_definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)
    assert {:ok, _source_output} = Flow.execute_step(run.id, "source", enqueue_coordinator: false)

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    fast_manifest = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "fast_manifest")
    background_notify = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "background_notify")

    assert fast_manifest.status == "scheduled"
    assert background_notify.status == "queued"
  end

  test "reconcile restores a scheduled step whose Oban job was cancelled" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "restore-stranded-step-#{System.unique_integer([:positive])}",
        "name" => "Restore Stranded Step"
      })

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => @definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, _run} = Flow.reconcile_run(run.id)

      original_job =
        Repo.one!(
          from job in Job,
            where: job.worker == "MaveCore.Workers.FlowStepWorker",
            where: fragment("?->>'flow_run_id' = ?", job.args, ^run.id),
            where: fragment("?->>'step_id' = ?", job.args, "source")
        )

      assert :ok = Oban.cancel_job(original_job)
      assert Repo.get!(Job, original_job.id).state == "cancelled"

      assert {:ok, _run} = Flow.reconcile_run(run.id)

      jobs =
        Repo.all(
          from job in Job,
            where: job.worker == "MaveCore.Workers.FlowStepWorker",
            where: fragment("?->>'flow_run_id' = ?", job.args, ^run.id),
            where: fragment("?->>'step_id' = ?", job.args, "source"),
            order_by: [asc: job.id]
        )

      assert Enum.map(jobs, & &1.state) == ["cancelled", "available"]
    end)
  end

  test "executing an already succeeded step restores its coordinator handoff" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "restore-succeeded-handoff-#{System.unique_integer([:positive])}",
        "name" => "Restore Succeeded Handoff"
      })

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => @definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)
    assert {:ok, _output} = Flow.execute_step(run.id, "source", enqueue_coordinator: false)

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, :already_succeeded} = Flow.execute_step(run.id, "source")

      assert Repo.exists?(
               from job in Job,
                 where: job.worker == "MaveCore.Workers.FlowCoordinatorWorker",
                 where: fragment("?->>'flow_run_id' = ?", job.args, ^run.id),
                 where: job.state == "available"
             )
    end)
  end

  test "publish flow inspects the completed tusd upload without waiting for the original copy" do
    assert {:ok, _installed} = Flow.install_preset("publish_local")

    assert {:ok, run} =
             Flow.start_run(
               "publish_local",
               %{
                 "space_hash" => "ubg50",
                 "embed_hash" => "LeDE9v86ye",
                 "input_url" => "https://example.com/video.mp4",
                 "media_probe" => %{
                   "duration" => 10.0,
                   "size_bytes" => 15,
                   "filetype" => "mp4",
                   "aspect_ratio" => "16 / 9",
                   "width" => 1920,
                   "height" => 1080,
                   "has_video" => true,
                   "has_audio" => true,
                   "streams" => [
                     %{"codec_type" => "video", "codec_name" => "h264"},
                     %{"codec_type" => "audio", "codec_name" => "aac"}
                   ]
                 }
               },
               enqueue: false
             )

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)
    assert {:ok, _source} = Flow.execute_step(run.id, "source", enqueue_coordinator: false)

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    assert {:ok, _bucket} =
             Flow.execute_step(run.id, "ensure_bucket", enqueue_coordinator: false)

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    inspect_media = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "inspect_media")
    upload_original = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "upload_original")

    assert inspect_media.status == "scheduled"
    assert upload_original.status == "scheduled"

    assert {:ok, _inspection} =
             Flow.execute_step(run.id, "inspect_media", enqueue_coordinator: false)

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    video_ladder = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "video_h264_ladder")
    upload_original = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "upload_original")

    assert video_ladder.status == "scheduled"
    assert upload_original.status == "scheduled"
  end

  test "publish_default schedules only baseline H264 renditions before the manifest" do
    enable_booster()
    assert {:ok, _installed} = Flow.install_preset("publish_default")

    assert {:ok, run} =
             Flow.start_run(
               "publish_default",
               %{
                 "space_hash" => "ubg50",
                 "embed_hash" => "LeDE9v86ye",
                 "input_url" => "https://example.com/video.mp4",
                 "media_probe" => %{
                   "duration" => 10.0,
                   "size_bytes" => 15,
                   "filetype" => "mp4",
                   "aspect_ratio" => "16 / 9",
                   "streams" => []
                 }
               },
               enqueue: false
             )

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)
    assert {:ok, _source} = Flow.execute_step(run.id, "source", enqueue_coordinator: false)
    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    assert {:ok, _bucket} =
             Flow.execute_step(run.id, "ensure_bucket", enqueue_coordinator: false)

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    assert {:ok, _inspection} =
             Flow.execute_step(run.id, "inspect_media", enqueue_coordinator: false)

    baseline_h264_step_ids = ~w(video_h264_sd video_h264_hd video_h264_fhd)
    deferred_h264_step_ids = ~w(video_h264_qhd video_h264_uhd)

    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, _run} = Flow.reconcile_run(run.id)

      for step_id <- baseline_h264_step_ids do
        step_run = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: step_id)

        step_job =
          Repo.one!(
            from job in Job,
              where: job.worker == "MaveCore.Workers.FlowStepWorker",
              where: fragment("?->>'flow_run_id' = ?", job.args, ^run.id),
              where: fragment("?->>'step_id' = ?", job.args, ^step_id)
          )

        assert step_run.status == "scheduled"
        assert %DateTime{} = step_run.scheduled_at
        assert step_job.queue == "flow_booster"
      end

      for step_id <- deferred_h264_step_ids do
        step_run = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: step_id)

        step_job =
          Repo.one(
            from job in Job,
              where: job.worker == "MaveCore.Workers.FlowStepWorker",
              where: fragment("?->>'flow_run_id' = ?", job.args, ^run.id),
              where: fragment("?->>'step_id' = ?", job.args, ^step_id)
          )

        assert step_run.status == "queued"
        assert is_nil(step_run.scheduled_at)
        assert is_nil(step_job)
      end
    end)

    hls_qhd = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "hls_h264_qhd")
    assert hls_qhd.status == "queued"
    assert is_nil(hls_qhd.scheduled_at)
  end

  test "routes manifest-critical audio and frame work through the foreground booster" do
    enable_booster()

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "direct-storage-manifest-inputs",
        "name" => "Direct-storage manifest inputs"
      })

    definition = %{
      "steps" => [
        %{"id" => "source", "type" => "source.resolve", "name" => "Resolve source"},
        %{
          "id" => "transcode_audio",
          "type" => "media.transcode_audio",
          "name" => "Transcode audio",
          "depends_on" => ["source"],
          "lane" => "fast"
        },
        %{
          "id" => "thumbnail_frame",
          "type" => "media.extract_frame",
          "name" => "Extract thumbnail",
          "depends_on" => ["source"],
          "lane" => "fast"
        },
        %{
          "id" => "hls_audio_default",
          "type" => "media.package_hls_audio",
          "name" => "Package audio HLS",
          "depends_on" => ["source"],
          "lane" => "fast"
        }
      ]
    }

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "qingb",
          "embed_hash" => "boost12345",
          "input_url" => "https://example.com/video.mp4",
          "priority" => "low"
        },
        enqueue: false
      )

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)
    assert {:ok, _source} = Flow.execute_step(run.id, "source", enqueue_coordinator: false)

    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, _run} = Flow.reconcile_run(run.id)

      for step_id <- ~w(transcode_audio thumbnail_frame hls_audio_default) do
        step_job =
          Repo.one!(
            from job in Job,
              where: job.worker == "MaveCore.Workers.FlowStepWorker",
              where: fragment("?->>'flow_run_id' = ?", job.args, ^run.id),
              where: fragment("?->>'step_id' = ?", job.args, ^step_id)
          )

        assert step_job.queue == "flow_booster"
        assert step_job.priority == 0
      end
    end)
  end

  test "publish_remote makes the original durable before inspection" do
    enable_booster()
    assert {:ok, _installed} = Flow.install_preset("publish_remote")

    assert {:ok, run} =
             Flow.start_run(
               "publish_remote",
               %{
                 "space_hash" => "qingb",
                 "embed_hash" => "remote1234",
                 "input_url" => "https://example.com/remote.mp4",
                 "priority" => "low",
                 "durable_source_required" => true
               },
               enqueue: false
             )

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)
    assert {:ok, _source} = Flow.execute_step(run.id, "source", enqueue_coordinator: false)
    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)
    assert {:ok, _bucket} = Flow.execute_step(run.id, "ensure_bucket", enqueue_coordinator: false)

    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, _run} = Flow.reconcile_run(run.id)

      upload_original = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "upload_original")
      inspect_media = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "inspect_media")

      step_job =
        Repo.one!(
          from job in Job,
            where: job.worker == "MaveCore.Workers.FlowStepWorker",
            where: fragment("?->>'flow_run_id' = ?", job.args, ^run.id),
            where: fragment("?->>'step_id' = ?", job.args, "upload_original")
        )

      assert upload_original.status == "scheduled"
      assert inspect_media.status == "queued"
      assert step_job.queue == "flow_steps"
      assert step_job.priority == 0
    end)
  end

  test "low priority prepares remote source on normal queue at normal priority" do
    {:ok, template} =
      Flow.create_template(%{"slug" => "low_priority_publish", "name" => "Low Priority Publish"})

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => @definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4",
          "priority" => "low"
        },
        enqueue: false
      )

    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, _run} = Flow.reconcile_run(run.id)

      step_job =
        Repo.one!(
          from job in Job,
            where: job.worker == "MaveCore.Workers.FlowStepWorker",
            where: fragment("?->>'flow_run_id' = ?", job.args, ^run.id),
            where: fragment("?->>'step_id' = ?", job.args, "source")
        )

      assert step_job.priority == 3
      assert step_job.queue == "flow_steps"
    end)
  end

  test "low priority routes media steps to the low queue without delaying source prep" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "low_priority_media_publish",
        "name" => "Low Priority Media Publish"
      })

    {:ok, _version} =
      Flow.create_version(template.id, %{"definition" => @flame_failure_definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4",
          "priority" => "low"
        },
        enqueue: false
      )

    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, _run} = Flow.reconcile_run(run.id)

      step_job =
        Repo.one!(
          from job in Job,
            where: job.worker == "MaveCore.Workers.FlowStepWorker",
            where: fragment("?->>'flow_run_id' = ?", job.args, ^run.id),
            where: fragment("?->>'step_id' = ?", job.args, "video")
        )

      assert step_job.priority == 9
      assert step_job.queue == "flow_low"
    end)
  end

  test "import priority prepares remote source on normal queue at normal priority" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "import_priority_source_publish",
        "name" => "Import Priority Source Publish"
      })

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => @definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4",
          "priority" => "import"
        },
        enqueue: false
      )

    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, _run} = Flow.reconcile_run(run.id)

      step_job =
        Repo.one!(
          from job in Job,
            where: job.worker == "MaveCore.Workers.FlowStepWorker",
            where: fragment("?->>'flow_run_id' = ?", job.args, ^run.id),
            where: fragment("?->>'step_id' = ?", job.args, "source")
        )

      assert step_job.priority == 3
      assert step_job.queue == "flow_steps"
    end)
  end

  test "import priority uses the remote import queue for media work" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "import_priority_media_publish",
        "name" => "Import Priority Media Publish"
      })

    {:ok, _version} =
      Flow.create_version(template.id, %{"definition" => @flame_failure_definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4",
          "priority" => "import"
        },
        enqueue: false
      )

    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, _run} = Flow.reconcile_run(run.id)

      step_job =
        Repo.one!(
          from job in Job,
            where: job.worker == "MaveCore.Workers.FlowStepWorker",
            where: fragment("?->>'flow_run_id' = ?", job.args, ^run.id),
            where: fragment("?->>'step_id' = ?", job.args, "video")
        )

      assert step_job.priority == 6
      assert step_job.queue == "flow_imports"
    end)
  end

  test "import finalizer steps use the default flow queue" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "import_finalizer_priority_publish",
        "name" => "Import Finalizer Priority Publish"
      })

    {:ok, _version} =
      Flow.create_version(template.id, %{
        "definition" => %{
          "steps" => [
            %{
              "id" => "hls_master",
              "type" => "media.build_hls_master",
              "name" => "Build HLS Master"
            }
          ]
        }
      })

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4",
          "priority" => "import"
        },
        enqueue: false
      )

    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, _run} = Flow.reconcile_run(run.id)

      step_job =
        Repo.one!(
          from job in Job,
            where: job.worker == "MaveCore.Workers.FlowStepWorker",
            where: fragment("?->>'flow_run_id' = ?", job.args, ^run.id),
            where: fragment("?->>'step_id' = ?", job.args, "hls_master")
        )

      assert step_job.priority == 6
      assert step_job.queue == "flow_steps"
    end)
  end

  test "default media steps use the media queue" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "media_queue_publish",
        "name" => "Media Queue Publish"
      })

    {:ok, _version} =
      Flow.create_version(template.id, %{"definition" => @flame_failure_definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, _run} = Flow.reconcile_run(run.id)

      step_job =
        Repo.one!(
          from job in Job,
            where: job.worker == "MaveCore.Workers.FlowStepWorker",
            where: fragment("?->>'flow_run_id' = ?", job.args, ^run.id),
            where: fragment("?->>'step_id' = ?", job.args, "video")
        )

      assert step_job.priority == 3
      assert step_job.queue == "flow_media"
    end)
  end

  for {mode, adapter} <- [
        success: AudioPeaksBoosterStub,
        failure: FailedEncodingBoosterAdapterStub,
        busy: BusyEncodingBoosterAdapterStub
      ] do
    @tag peaks_booster: true, peaks_mode: mode, peaks_adapter: adapter
    test "audio peaks booster routing: #{mode}", %{peaks_mode: mode, peaks_adapter: adapter} do
      enable_booster()
      Application.put_env(:mave_core, :encoding_booster_adapter, adapter)
      owner = self()

      Application.put_env(:mave_core, :flow_flame_caller, fn _pool, _fun, _opts ->
        send(owner, :peaks_flame_fallback)
        {:error, :synthetic_flame_failure, %{"executor" => "flame"}}
      end)

      {:ok, template} = Flow.create_template(%{slug: "peaks-#{mode}", name: "Audio peaks"})

      definition = %{
        "steps" => [
          %{"id" => "inspect_media", "type" => "media.inspect", "name" => "Inspect"},
          %{
            "id" => "audio_peaks",
            "type" => "media.generate_audio_peaks",
            "name" => "Peaks",
            "depends_on" => ["inspect_media"],
            "lane" => "background",
            "required" => false
          }
        ]
      }

      {:ok, _} = Flow.create_version(template.id, %{"definition" => definition})

      {:ok, run} =
        Flow.start_run(
          template.slug,
          %{
            "space_hash" => "ubg50",
            "embed_hash" => "LeDE9v86ye",
            "input_url" => "https://example.com/audio.mp3"
          },
          enqueue: false
        )

      mark_step!(run.id, "inspect_media", %{
        status: "succeeded",
        output: %{"has_audio" => true, "has_video" => false, "duration" => 2.0}
      })

      Oban.Testing.with_testing_mode(:manual, fn ->
        {:ok, _} = Flow.reconcile_run(run.id)

        job =
          Repo.one!(
            from j in Job,
              where: fragment("?->>'flow_run_id' = ?", j.args, ^run.id),
              where: fragment("?->>'step_id' = ?", j.args, "audio_peaks")
          )

        assert job.queue == "flow_booster_background"
      end)

      result = Flow.execute_step(run.id, "audio_peaks", enqueue_coordinator: false)

      case mode do
        :success ->
          assert {:ok, %{"mode" => "encoding_booster", "waveform" => %{"peaks" => [0.1]}}} =
                   result

          refute_received :peaks_flame_fallback

        :failure ->
          assert {:error, :synthetic_flame_failure} = result
          assert_received :peaks_flame_fallback

        :busy ->
          assert {:error, :encoding_booster_busy} = result
          refute_received :peaks_flame_fallback
      end
    end
  end

  test "eligible H264 ladder steps from any space use the dedicated booster queue" do
    enable_booster()

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "booster_queue_publish",
        "name" => "Booster Queue Publish"
      })

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => @booster_definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "corre",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, _run} = Flow.reconcile_run(run.id)

      step_job =
        Repo.one!(
          from job in Job,
            where: job.worker == "MaveCore.Workers.FlowStepWorker",
            where: fragment("?->>'flow_run_id' = ?", job.args, ^run.id),
            where: fragment("?->>'step_id' = ?", job.args, "video_h264_ladder")
        )

      assert step_job.queue == "flow_booster"
      assert step_job.args["space_hash"] == "corre"
    end)
  end

  test "eligible H264 ladder executes directly without reserving a FLAME runner" do
    enable_booster()
    owner = self()

    Application.put_env(:mave_core, :flow_flame_caller, fn _pool, _fun, _options ->
      send(owner, :unexpected_flame_call)
      {:error, :unexpected_flame_call, %{}}
    end)

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "direct_booster_publish",
        "name" => "Direct Booster Publish"
      })

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => @booster_definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4",
          "source_body" => "stub-media-body",
          "media_transcode_h264_ladder_mode" => "copy"
        },
        enqueue: false
      )

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)
    assert {:ok, _output} = Flow.execute_step(run.id, "video_h264_ladder")
    refute_received :unexpected_flame_call

    step_run = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "video_h264_ladder")
    assert step_run.execution_metadata["executor"] == "encoding_booster"
    assert step_run.execution_metadata["encoding_booster_attempted"] == false
    assert step_run.execution_metadata["encoding_booster_used"] == false
  end

  test "non-GPU video transcodes use the CPU booster queue" do
    enable_booster()

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "cpu_video_booster_queue_publish",
        "name" => "CPU Video Booster Queue Publish"
      })

    {:ok, _version} =
      Flow.create_version(template.id, %{"definition" => @cpu_video_booster_definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, _run} = Flow.reconcile_run(run.id)

      step_job =
        Repo.one!(
          from job in Job,
            where: job.worker == "MaveCore.Workers.FlowStepWorker",
            where: fragment("?->>'flow_run_id' = ?", job.args, ^run.id),
            where: fragment("?->>'step_id' = ?", job.args, "clip_h264_sd_keyframes")
        )

      assert step_job.queue == "flow_booster"
    end)
  end

  test "background video transcodes use the reserved-capacity booster queue" do
    enable_booster()

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "background-cpu-video-booster-queue-publish",
        "name" => "Background CPU Video Booster Queue Publish"
      })

    definition =
      put_in(
        @cpu_video_booster_definition,
        ["steps", Access.at(0), "lane"],
        "background"
      )

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, _run} = Flow.reconcile_run(run.id)

      step_job =
        Repo.one!(
          from job in Job,
            where: job.worker == "MaveCore.Workers.FlowStepWorker",
            where: fragment("?->>'flow_run_id' = ?", job.args, ^run.id),
            where: fragment("?->>'step_id' = ?", job.args, "clip_h264_sd_keyframes")
        )

      assert step_job.priority == 9
      assert step_job.queue == "flow_booster_background"
    end)
  end

  @tag :audio_pipeline
  test "retired waveform steps skip the queue while segments and storyboards use CPU capacity" do
    enable_booster()

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "background-derived-assets-booster-queue",
        "name" => "Background Derived Assets Booster Queue"
      })

    definition = %{
      "steps" => [
        %{
          "id" => "waveform",
          "name" => "Waveform",
          "type" => "media.transcode_waveform",
          "lane" => "background"
        },
        %{
          "id" => "segments",
          "name" => "Segments",
          "type" => "media.generate_segments",
          "lane" => "background"
        },
        %{
          "id" => "storyboard",
          "name" => "Storyboard",
          "type" => "media.generate_storyboard",
          "lane" => "background"
        }
      ]
    }

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, _run} = Flow.reconcile_run(run.id)

      jobs =
        Repo.all(
          from(job in Job,
            where: job.worker == "MaveCore.Workers.FlowStepWorker",
            where: fragment("?->>'flow_run_id' = ?", job.args, ^run.id)
          )
        )

      assert Enum.sort(Enum.map(jobs, & &1.args["step_id"])) ==
               ~w(segments storyboard)

      assert %{status: "succeeded", output: %{"status" => "skipped"}} =
               Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "waveform")

      assert Enum.all?(jobs, &(&1.queue == "flow_booster_background"))
      assert Enum.all?(jobs, &(&1.priority == 9))
    end)
  end

  test "HLS variant packaging uses the CPU booster queue" do
    enable_booster()

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "hls_booster_queue_publish",
        "name" => "HLS Booster Queue Publish"
      })

    {:ok, _version} =
      Flow.create_version(template.id, %{"definition" => @hls_booster_definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, _run} = Flow.reconcile_run(run.id)

      step_job =
        Repo.one!(
          from job in Job,
            where: job.worker == "MaveCore.Workers.FlowStepWorker",
            where: fragment("?->>'flow_run_id' = ?", job.args, ^run.id),
            where: fragment("?->>'step_id' = ?", job.args, "hls_h264_sd")
        )

      assert step_job.queue == "flow_booster"
    end)
  end

  test "busy CPU video transcodes stay on the booster retry path" do
    enable_booster()
    owner = self()

    Application.put_env(
      :mave_core,
      :encoding_booster_adapter,
      BusyEncodingBoosterAdapterStub
    )

    Application.put_env(:mave_core, :flow_flame_caller, fn pool, _fun, _options ->
      send(owner, {:cpu_video_flame_fallback, pool})
      {:error, :synthetic_flame_failure, %{"executor" => "flame"}}
    end)

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "cpu_video_booster_publish",
        "name" => "CPU Video Booster Publish"
      })

    {:ok, _version} =
      Flow.create_version(template.id, %{"definition" => @cpu_video_booster_definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4",
          "media_transcode_video_mode" => "ffmpeg"
        },
        enqueue: false
      )

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    assert {:error, {:media_transcode_video_failed, :encoding_booster_busy}} =
             Flow.execute_step(run.id, "clip_h264_sd_keyframes", enqueue_coordinator: false)

    refute_receive {:cpu_video_flame_fallback, MaveCore.Workers.FlameRunner}

    step_run =
      Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "clip_h264_sd_keyframes")

    assert step_run.execution_metadata["executor"] == "encoding_booster"
    refute Map.has_key?(step_run.execution_metadata, "encoding_booster_fallback")
    assert step_run.execution_metadata["encoding_booster_attempted"] == true
    assert step_run.execution_metadata["encoding_booster_used"] == false
  end

  test "booster failure delegates only the fallback execution to FLAME" do
    enable_booster()
    owner = self()

    Application.put_env(
      :mave_core,
      :encoding_booster_adapter,
      FailedEncodingBoosterAdapterStub
    )

    Application.put_env(:mave_core, :flow_flame_caller, fn pool, _fun, _options ->
      send(owner, {:flame_fallback, pool})
      {:error, :synthetic_flame_failure, %{"executor" => "flame"}}
    end)

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "booster_fallback_publish",
        "name" => "Booster Fallback Publish"
      })

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => @booster_definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4",
          "media_transcode_h264_ladder_mode" => "ffmpeg"
        },
        enqueue: false
      )

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    assert {:error, :synthetic_flame_failure} =
             Flow.execute_step(run.id, "video_h264_ladder", enqueue_coordinator: false)

    assert_receive {:flame_fallback, MaveCore.Workers.FlameRunner}

    step_run = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "video_h264_ladder")
    assert step_run.execution_metadata["executor"] == "flame"
    assert step_run.execution_metadata["encoding_booster_fallback"] == "request_failed"
    assert step_run.execution_metadata["encoding_booster_attempted"] == true
    assert step_run.execution_metadata["encoding_booster_used"] == false
    assert step_run.execution_metadata["requested_executor"] == "encoding_booster"
  end

  test "GPU booster failure falls through the CPU booster before FLAME" do
    enable_booster()
    owner = self()

    Application.put_env(:mave_core, :gpu_encoding_booster,
      enabled: true,
      fallback_enabled: true
    )

    Application.put_env(
      :mave_core,
      :gpu_encoding_booster_adapter,
      BusyEncodingBoosterAdapterStub
    )

    Application.put_env(
      :mave_core,
      :encoding_booster_adapter,
      FailedEncodingBoosterAdapterStub
    )

    Application.put_env(:mave_core, :flow_flame_caller, fn pool, _fun, _options ->
      send(owner, {:gpu_cpu_flame_fallback, pool})
      {:error, :synthetic_flame_failure, %{"executor" => "flame"}}
    end)

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "gpu_cpu_fallback_publish",
        "name" => "GPU CPU Fallback Publish"
      })

    {:ok, _version} =
      Flow.create_version(template.id, %{"definition" => @gpu_booster_definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4",
          "media_transcode_h264_ladder_mode" => "ffmpeg"
        },
        enqueue: false
      )

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    assert {:error, :synthetic_flame_failure} =
             Flow.execute_step(run.id, "video_h264_hd", enqueue_coordinator: false)

    assert_receive {:gpu_cpu_flame_fallback, MaveCore.Workers.FlameRunner}

    step_run = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "video_h264_hd")
    assert step_run.execution_metadata["executor"] == "flame"
    assert step_run.execution_metadata["gpu_encoding_booster_fallback"] == "busy"
    assert step_run.execution_metadata["encoding_booster_fallback"] == "request_failed"
    assert step_run.execution_metadata["requested_executor"] == "gpu_encoding_booster"
  end

  test "background media steps use the low queue" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "background_media_queue_publish",
        "name" => "Background Media Queue Publish"
      })

    definition = %{
      "steps" => [
        %{
          "id" => "clip_av1_hd",
          "type" => "media.transcode_video",
          "name" => "Transcode AV1 HD Clip",
          "lane" => "background"
        }
      ]
    }

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, _run} = Flow.reconcile_run(run.id)

      step_job =
        Repo.one!(
          from job in Job,
            where: job.worker == "MaveCore.Workers.FlowStepWorker",
            where: fragment("?->>'flow_run_id' = ?", job.args, ^run.id),
            where: fragment("?->>'step_id' = ?", job.args, "clip_av1_hd")
        )

      assert step_job.priority == 9
      assert step_job.queue == "flow_low"
    end)
  end

  test "media queue allows eight active steps per space by default" do
    fair_queues = Application.fetch_env!(:mave_core, :flow_fair_queues)

    assert fair_queues
           |> Keyword.fetch!(:flow_media)
           |> Keyword.fetch!(:space_concurrency) == 8
  end

  test "low priority queue lets one space borrow idle low-priority capacity" do
    fair_queues = Application.fetch_env!(:mave_core, :flow_fair_queues)
    low_queue = Keyword.fetch!(fair_queues, :flow_low)

    assert Keyword.fetch!(low_queue, :space_concurrency) == 1
    assert Keyword.fetch!(low_queue, :global_concurrency) == 5
    assert Keyword.fetch!(low_queue, :work_conserving)
  end

  test "preparation queue keeps arrival headroom while borrowing idle capacity" do
    fair_queues = Application.fetch_env!(:mave_core, :flow_fair_queues)
    preparation_queue = Keyword.fetch!(fair_queues, :flow_steps)

    assert Keyword.fetch!(preparation_queue, :space_concurrency) == 1
    assert Keyword.fetch!(preparation_queue, :global_concurrency) == 50
    assert Keyword.fetch!(preparation_queue, :new_space_headroom) == 5
    assert Keyword.fetch!(preparation_queue, :work_conserving)
  end

  test "work-conserving preparation admission gives a new space immediate capacity" do
    configure_work_conserving_flow_steps_test()

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "preparation-burst-reclaim-publish",
        "name" => "Preparation Burst Reclaim Publish"
      })

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => @definition})

    first_space_runs =
      for _index <- 1..4 do
        create_scheduled_source_run!(template, "first-preparation-space")
      end

    first_space_runs
    |> Enum.take(3)
    |> Enum.each(&mark_source_step_executing!/1)

    assert demanding_flow_step_spaces() == 1
    assert {:snooze, 7} = perform_source_step(List.last(first_space_runs))

    second_space_run = create_scheduled_source_run!(template, "second-preparation-space")

    assert demanding_flow_step_spaces() == 2
    assert :ok = perform_source_step(second_space_run)

    assert Repo.get_by!(StepRun,
             flow_run_id: second_space_run.id,
             step_id: "source"
           ).status == "succeeded"
  end

  test "future retry jobs do not dilute the share of currently runnable spaces" do
    configure_work_conserving_flow_steps_test()

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "preparation-future-retry-demand-publish",
        "name" => "Preparation Future Retry Demand Publish"
      })

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => @definition})

    active_runs =
      for _index <- 1..3 do
        create_scheduled_source_run!(template, "currently-active-space")
      end

    active_runs
    |> Enum.take(2)
    |> Enum.each(&mark_source_step_executing!/1)

    future_run = create_scheduled_source_run!(template, "future-retry-space")

    Job
    |> where(
      [job],
      fragment("?->>'flow_run_id'", job.args) == ^future_run.id and
        fragment("?->>'step_id'", job.args) == "source"
    )
    |> Repo.update_all(
      set: [state: "retryable", scheduled_at: DateTime.add(DateTime.utc_now(), 3_600, :second)]
    )

    assert :ok = perform_source_step(List.last(active_runs))

    assert Repo.get_by!(StepRun,
             flow_run_id: List.last(active_runs).id,
             step_id: "source"
           ).status == "succeeded"
  end

  test "booster queues reserve foreground capacity and limit background work per space" do
    fair_queues = Application.fetch_env!(:mave_core, :flow_fair_queues)

    assert fair_queues
           |> Keyword.fetch!(:flow_booster)
           |> Keyword.fetch!(:space_concurrency) == 6

    assert fair_queues
           |> Keyword.fetch!(:flow_booster)
           |> Keyword.fetch!(:global_concurrency) == 50

    assert fair_queues
           |> Keyword.fetch!(:flow_booster)
           |> Keyword.fetch!(:work_conserving)

    assert fair_queues
           |> Keyword.fetch!(:flow_booster_background)
           |> Keyword.fetch!(:space_concurrency) == 2

    assert fair_queues
           |> Keyword.fetch!(:flow_booster_background)
           |> Keyword.fetch!(:run_concurrency) == 6

    assert fair_queues
           |> Keyword.fetch!(:flow_booster_background)
           |> Keyword.fetch!(:background_concurrency) == 38

    assert fair_queues
           |> Keyword.fetch!(:flow_booster_background)
           |> Keyword.fetch!(:background_concurrency_when_foreground_waiting) == 0

    assert fair_queues
           |> Keyword.fetch!(:flow_booster_background)
           |> Keyword.fetch!(:work_conserving)
  end

  test "booster admission lets HLS packaging share aggregate capacity" do
    old_fair_queues = Application.get_env(:mave_core, :flow_fair_queues)

    Application.put_env(:mave_core, :flow_fair_queues,
      flow_booster: [
        space_concurrency: 10,
        global_concurrency: 50,
        snooze_seconds: 7
      ]
    )

    on_exit(fn -> restore_env(:flow_fair_queues, old_fair_queues) end)

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "shared-hls-packaging-publish",
        "name" => "Shared HLS Packaging"
      })

    {:ok, _version} =
      Flow.create_version(template.id, %{
        "definition" => %{
          "steps" => [
            %{
              "id" => "hls_sd",
              "type" => "media.package_hls_variant",
              "name" => "Package SD HLS",
              "params" => %{"codec" => "h264", "size" => "sd"}
            }
          ]
        }
      })

    runs =
      for index <- 1..5 do
        {:ok, run} =
          Flow.start_run(
            template.slug,
            %{
              "space_hash" => "hls-space-#{index}",
              "embed_hash" => "HlsPackaging#{index}"
            },
            enqueue: false
          )

        {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)
        run
      end

    runs
    |> Enum.take(4)
    |> Enum.each(fn run ->
      mark_step!(run.id, "hls_sd", %{
        status: "executing",
        execution_metadata: %{"queue" => "flow_booster"}
      })
    end)

    waiting_run = List.last(runs)

    result =
      FlowStepWorker.perform(%Job{
        queue: "flow_booster",
        args: %{"flow_run_id" => waiting_run.id, "step_id" => "hls_sd"}
      })

    refute result == {:snooze, 7}

    refute Repo.get_by!(StepRun,
             flow_run_id: waiting_run.id,
             step_id: "hls_sd"
           ).status == "scheduled"
  end

  test "work-conserving booster admission lets one space borrow idle capacity" do
    configure_work_conserving_booster_test()

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "booster-burst-borrowing-publish",
        "name" => "Booster Burst Borrowing Publish"
      })

    {:ok, _version} =
      Flow.create_version(template.id, %{"definition" => @cpu_video_booster_definition})

    runs =
      for _index <- 1..3 do
        create_scheduled_booster_run!(template, "burst-space")
      end

    runs
    |> Enum.take(2)
    |> Enum.each(&mark_booster_step_executing!/1)

    waiting_run = List.last(runs)

    waiting_step =
      Repo.get_by!(StepRun,
        flow_run_id: waiting_run.id,
        step_id: "clip_h264_sd_keyframes"
      )

    waiting_step
    |> StepRun.changeset(%{
      error: "retrying transient failure 1/3 in 13s: temporary booster failure",
      execution_metadata:
        Map.merge(waiting_step.execution_metadata, %{
          "progress" => %{
            "percent" => 24.6,
            "status" => "executing",
            "stage" => "transcode"
          },
          "retry" => %{
            "automatic" => true,
            "attempt" => 1,
            "next_attempt" => 2,
            "max_attempts" => 3
          },
          "retry_policy" => %{"cycle_attempts" => 1}
        })
    })
    |> Repo.update!()

    assert {:snooze, 7} = perform_booster_step(waiting_run)

    step =
      Repo.get_by!(StepRun,
        flow_run_id: waiting_run.id,
        step_id: "clip_h264_sd_keyframes"
      )

    assert step.status == "scheduled"
    assert step.attempt == 0
    assert step.error == nil
    assert get_in(step.execution_metadata, ["retry_policy", "cycle_attempts"]) == 1
    assert get_in(step.execution_metadata, ["capacity", "deferrals"]) == 1
    assert get_in(step.execution_metadata, ["progress", "percent"]) == 24.6
    assert get_in(step.execution_metadata, ["progress", "status"]) == "queued"
    assert get_in(step.execution_metadata, ["last_retry", "automatic"]) == true

    assert get_in(step.execution_metadata, ["last_retry", "error"]) =~
             "temporary booster failure"

    refute Map.has_key?(step.execution_metadata, "retry")
  end

  test "work-conserving booster admission reclaims borrowed capacity for a new space" do
    configure_work_conserving_booster_test()

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "booster-burst-reclaim-publish",
        "name" => "Booster Burst Reclaim Publish"
      })

    {:ok, _version} =
      Flow.create_version(template.id, %{"definition" => @cpu_video_booster_definition})

    first_space_runs =
      for _index <- 1..3 do
        create_scheduled_booster_run!(template, "first-burst-space")
      end

    first_space_runs
    |> Enum.take(2)
    |> Enum.each(&mark_booster_step_executing!/1)

    second_space_run = create_scheduled_booster_run!(template, "second-burst-space")

    assert demanding_booster_spaces() == 2
    assert active_booster_steps() == 2

    assert {:snooze, 7} = perform_booster_step(List.last(first_space_runs))

    assert {:snooze, 7} = perform_booster_step(second_space_run)
  end

  test "background booster queue snoozes at its global admission ceiling" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "background-booster-admission-publish",
        "name" => "Background Booster Admission Publish"
      })

    definition =
      put_in(
        @cpu_video_booster_definition,
        ["steps", Access.at(0), "lane"],
        "background"
      )

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => definition})

    {:ok, executing_run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "background-admission-a",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    {:ok, waiting_run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "background-admission-b",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    {:ok, _run} = Flow.reconcile_run(executing_run.id, enqueue_jobs: false)
    {:ok, _run} = Flow.reconcile_run(waiting_run.id, enqueue_jobs: false)

    Repo.get_by!(StepRun,
      flow_run_id: executing_run.id,
      step_id: "clip_h264_sd_keyframes"
    )
    |> StepRun.changeset(%{
      status: "executing",
      execution_metadata: %{"queue" => "flow_booster_background"}
    })
    |> Repo.update!()

    old_config = Application.get_env(:mave_core, :flow_fair_queues)

    Application.put_env(:mave_core, :flow_fair_queues,
      flow_booster_background: [
        space_concurrency: 10,
        global_concurrency: 50,
        background_concurrency: 1,
        snooze_seconds: 7
      ]
    )

    on_exit(fn -> restore_env(:flow_fair_queues, old_config) end)

    assert {:snooze, 7} =
             FlowStepWorker.perform(%Job{
               queue: "flow_booster_background",
               args: %{
                 "flow_run_id" => waiting_run.id,
                 "step_id" => "clip_h264_sd_keyframes"
               }
             })

    assert Repo.get_by!(StepRun,
             flow_run_id: waiting_run.id,
             step_id: "clip_h264_sd_keyframes"
           ).status == "scheduled"
  end

  @tag :audio_pipeline
  test "derived asset booster work counts against the shared global ceiling" do
    {:ok, background_template} =
      Flow.create_template(%{
        "slug" => "derived-asset-global-admission-publish",
        "name" => "Derived Asset Global Admission"
      })

    background_definition = %{
      "steps" => [
        %{
          "id" => "segments",
          "type" => "media.generate_segments",
          "name" => "Generate Segments",
          "lane" => "background"
        },
        %{
          "id" => "storyboard",
          "type" => "media.generate_storyboard",
          "name" => "Generate Storyboard",
          "lane" => "background"
        },
        %{
          "id" => "segments_extra",
          "type" => "media.generate_segments",
          "name" => "Generate Extra Segments",
          "lane" => "background"
        }
      ]
    }

    {:ok, _version} =
      Flow.create_version(background_template.id, %{"definition" => background_definition})

    background_run = create_scheduled_run!(background_template, "derived-assets-space")

    for step_id <- ~w(segments storyboard segments_extra) do
      mark_step!(background_run.id, step_id, %{
        status: "executing",
        execution_metadata: %{"queue" => "flow_booster_background"}
      })
    end

    {:ok, foreground_template} =
      Flow.create_template(%{
        "slug" => "derived-asset-foreground-admission-publish",
        "name" => "Derived Asset Foreground Admission"
      })

    {:ok, _version} =
      Flow.create_version(foreground_template.id, %{
        "definition" => @cpu_video_booster_definition
      })

    foreground_run = create_scheduled_booster_run!(foreground_template, "foreground-space")

    old_config = Application.get_env(:mave_core, :flow_fair_queues)
    old_retry_config = Application.get_env(:mave_core, :flow_step_auto_retry)

    Application.put_env(:mave_core, :flow_fair_queues,
      flow_booster: [
        space_concurrency: 10,
        global_concurrency: 3,
        capacity_snooze_seconds: 5,
        snooze_seconds: 7
      ]
    )

    Application.put_env(:mave_core, :flow_step_auto_retry, false)
    Application.put_env(:mave_core, :encoding_booster, enabled: true, fallback_enabled: true)
    Application.put_env(:mave_core, :encoding_booster_adapter, BusyEncodingBoosterAdapterStub)

    on_exit(fn ->
      restore_env(:flow_fair_queues, old_config)
      restore_env(:flow_step_auto_retry, old_retry_config)
    end)

    assert {:snooze, 7} = perform_booster_step(foreground_run)

    step =
      Repo.get_by!(StepRun,
        flow_run_id: foreground_run.id,
        step_id: "clip_h264_sd_keyframes"
      )

    assert step.status == "scheduled"
    assert step.attempt == 0
  end

  test "background booster queue yields while foreground booster work is waiting" do
    {:ok, background_template} =
      Flow.create_template(%{
        "slug" => "background-booster-yields-publish",
        "name" => "Background Booster Yields"
      })

    background_definition =
      put_in(
        @cpu_video_booster_definition,
        ["steps", Access.at(0), "lane"],
        "background"
      )

    {:ok, _version} =
      Flow.create_version(background_template.id, %{"definition" => background_definition})

    background_run = create_scheduled_run!(background_template, "background-space")

    {:ok, foreground_template} =
      Flow.create_template(%{
        "slug" => "foreground-booster-demand-publish",
        "name" => "Foreground Booster Demand"
      })

    {:ok, _version} =
      Flow.create_version(foreground_template.id, %{
        "definition" => @cpu_video_booster_definition
      })

    _foreground_run = create_scheduled_booster_run!(foreground_template, "foreground-space")

    old_config = Application.get_env(:mave_core, :flow_fair_queues)

    Application.put_env(:mave_core, :flow_fair_queues,
      flow_booster_background: [
        space_concurrency: 10,
        global_concurrency: 50,
        background_concurrency: 38,
        background_concurrency_when_foreground_waiting: 0,
        snooze_seconds: 7
      ]
    )

    on_exit(fn -> restore_env(:flow_fair_queues, old_config) end)

    assert {:snooze, 7} =
             perform_background_booster_step(background_run, "clip_h264_sd_keyframes")

    assert Repo.get_by!(StepRun,
             flow_run_id: background_run.id,
             step_id: "clip_h264_sd_keyframes"
           ).status == "scheduled"
  end

  test "background booster queue limits one run without blocking independent runs" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "background-booster-run-admission-publish",
        "name" => "Background Booster Run Admission Publish"
      })

    definition = %{
      "steps" =>
        for suffix <- ~w(a b c) do
          %{
            "id" => "clip_#{suffix}",
            "type" => "media.transcode_video",
            "name" => "Transcode Clip #{String.upcase(suffix)}",
            "params" => %{
              "codec" => "h264",
              "size" => "sd",
              "container" => "mp4",
              "strict" => true
            },
            "lane" => "background"
          }
        end
    }

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => definition})

    first_run = create_scheduled_run!(template, "same-source-space")
    second_run = create_scheduled_run!(template, "same-source-space")

    for step_id <- ~w(clip_a clip_b) do
      mark_step!(first_run.id, step_id, %{
        status: "executing",
        execution_metadata: %{"queue" => "flow_booster_background"}
      })
    end

    old_config = Application.get_env(:mave_core, :flow_fair_queues)
    old_retry_config = Application.get_env(:mave_core, :flow_step_auto_retry)

    Application.put_env(:mave_core, :flow_fair_queues,
      flow_booster_background: [
        space_concurrency: 10,
        run_concurrency: 2,
        global_concurrency: 50,
        background_concurrency: 38,
        work_conserving: true,
        snooze_seconds: 7
      ]
    )

    Application.put_env(:mave_core, :flow_step_auto_retry, false)
    Application.put_env(:mave_core, :encoding_booster, enabled: true, fallback_enabled: true)
    Application.put_env(:mave_core, :encoding_booster_adapter, BusyEncodingBoosterAdapterStub)

    on_exit(fn ->
      restore_env(:flow_fair_queues, old_config)
      restore_env(:flow_step_auto_retry, old_retry_config)
    end)

    assert {:snooze, 7} = perform_background_booster_step(first_run, "clip_c")

    assert {:snooze, 7} = perform_background_booster_step(second_run, "clip_a")
  end

  test "media queue snoozes when the same space already has its fair share running" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "media_queue_fairness_publish",
        "name" => "Media Queue Fairness Publish"
      })

    {:ok, _version} =
      Flow.create_version(template.id, %{"definition" => @flame_failure_definition})

    run_input = %{
      "space_hash" => "fairspace",
      "embed_hash" => "LeDE9v86ye",
      "input_url" => "https://example.com/video.mp4"
    }

    {:ok, executing_run} = Flow.start_run(template.slug, run_input, enqueue: false)
    {:ok, waiting_run} = Flow.start_run(template.slug, run_input, enqueue: false)

    {:ok, _run} = Flow.reconcile_run(executing_run.id, enqueue_jobs: false)
    {:ok, _run} = Flow.reconcile_run(waiting_run.id, enqueue_jobs: false)

    Repo.get_by!(StepRun, flow_run_id: executing_run.id, step_id: "video")
    |> StepRun.changeset(%{status: "executing"})
    |> Repo.update!()

    old_config = Application.get_env(:mave_core, :flow_fair_queues)

    Application.put_env(:mave_core, :flow_fair_queues,
      flow_media: [space_concurrency: 1, snooze_seconds: 7]
    )

    on_exit(fn ->
      restore_env(:flow_fair_queues, old_config)
    end)

    assert {:snooze, 7} =
             FlowStepWorker.perform(%Job{
               queue: "flow_media",
               args: %{"flow_run_id" => waiting_run.id, "step_id" => "video"}
             })

    assert Repo.get_by!(StepRun, flow_run_id: waiting_run.id, step_id: "video").status ==
             "scheduled"
  end

  test "media queue ignores executing steps from terminal runs" do
    old_flame_pool = Application.get_env(:mave_core, :flow_flame_pool)
    old_retry_config = Application.get_env(:mave_core, :flow_step_auto_retry)

    Application.put_env(:mave_core, :flow_flame_pool, :missing_flow_flame_pool)
    Application.put_env(:mave_core, :flow_step_auto_retry, false)

    on_exit(fn ->
      restore_env(:flow_flame_pool, old_flame_pool)
      restore_env(:flow_step_auto_retry, old_retry_config)
    end)

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "media_queue_terminal_fairness_publish",
        "name" => "Media Queue Terminal Fairness Publish"
      })

    {:ok, _version} =
      Flow.create_version(template.id, %{"definition" => @flame_failure_definition})

    run_input = %{
      "space_hash" => "terminalfairspace",
      "embed_hash" => "LeDE9v86ye",
      "input_url" => "https://example.com/video.mp4"
    }

    {:ok, terminal_run} = Flow.start_run(template.slug, run_input, enqueue: false)
    {:ok, waiting_run} = Flow.start_run(template.slug, run_input, enqueue: false)

    {:ok, _run} = Flow.reconcile_run(terminal_run.id, enqueue_jobs: false)
    {:ok, _run} = Flow.reconcile_run(waiting_run.id, enqueue_jobs: false)

    Repo.get_by!(StepRun, flow_run_id: terminal_run.id, step_id: "video")
    |> StepRun.changeset(%{status: "executing"})
    |> Repo.update!()

    terminal_run
    |> Run.changeset(%{status: "failed", error: "one or more required steps failed"})
    |> Repo.update!()

    old_config = Application.get_env(:mave_core, :flow_fair_queues)

    Application.put_env(:mave_core, :flow_fair_queues,
      flow_media: [space_concurrency: 1, snooze_seconds: 7]
    )

    on_exit(fn ->
      restore_env(:flow_fair_queues, old_config)
    end)

    assert {:error, error} =
             FlowStepWorker.perform(%Job{
               queue: "flow_media",
               args: %{"flow_run_id" => waiting_run.id, "step_id" => "video"}
             })

    assert error =~ "flame_execution_failed"
  end

  test "skipped ladder variants do not enqueue hls packaging work" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "skip-ladder-hls-#{System.unique_integer([:positive])}",
        "name" => "Skip Ladder HLS"
      })

    {:ok, _version} =
      Flow.create_version(template.id, %{
        "definition" => %{
          "steps" => [
            %{"id" => "inspect_media", "type" => "media.inspect", "name" => "Inspect Media"},
            %{
              "id" => "video_h264_ladder",
              "type" => "media.transcode_h264_ladder",
              "name" => "Transcode H264 Ladder",
              "depends_on" => ["inspect_media"],
              "params" => %{"sizes" => ["sd", "hd", "fhd"]}
            },
            %{
              "id" => "hls_h264_fhd",
              "type" => "media.package_hls_variant",
              "name" => "Package FHD",
              "depends_on" => ["video_h264_ladder"],
              "params" => %{
                "codec" => "h264",
                "size" => "fhd",
                "source_step_id" => "video_h264_ladder",
                "strict" => true
              },
              "required" => false
            }
          ]
        }
      })

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "skipspace",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    now = DateTime.utc_now()

    mark_step!(run.id, "inspect_media", %{
      status: "succeeded",
      output: %{
        "status" => "ok",
        "step_type" => "media.inspect",
        "width" => 1280,
        "height" => 720,
        "duration" => 10.0
      },
      completed_at: now
    })

    mark_step!(run.id, "video_h264_ladder", %{
      status: "succeeded",
      output: %{
        "status" => "ok",
        "step_type" => "media.transcode_h264_ladder",
        "sizes" => ["sd", "hd"],
        "variant_outputs" => %{
          "fhd" => %{
            "status" => "skipped",
            "step_type" => "media.transcode_h264_ladder",
            "codec" => "h264",
            "size" => "fhd",
            "reason" => "source_resolution_below_variant",
            "source_width" => 1280
          }
        }
      },
      completed_at: now
    })

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, _run} = Flow.reconcile_run(run.id)

      hls_step = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "hls_h264_fhd")
      assert hls_step.status == "succeeded"
      assert is_nil(hls_step.scheduled_at)
      assert hls_step.output["status"] == "skipped"
      assert hls_step.output["reason"] == "source_resolution_below_variant"

      refute Repo.exists?(
               from job in Job,
                 where: job.worker == "MaveCore.Workers.FlowStepWorker",
                 where: fragment("?->>'flow_run_id' = ?", job.args, ^run.id),
                 where: fragment("?->>'step_id' = ?", job.args, "hls_h264_fhd")
             )
    end)
  end

  test "prepackaged frame outputs do not enqueue extract frame work" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "skip-prepackaged-frame-#{System.unique_integer([:positive])}",
        "name" => "Skip Prepackaged Frame"
      })

    {:ok, _version} =
      Flow.create_version(template.id, %{
        "definition" => %{
          "steps" => [
            %{"id" => "inspect_media", "type" => "media.inspect", "name" => "Inspect Media"},
            %{
              "id" => "video_h264_ladder",
              "type" => "media.transcode_h264_ladder",
              "name" => "Transcode H264 Ladder",
              "depends_on" => ["inspect_media"]
            },
            %{
              "id" => "poster_frame",
              "type" => "media.extract_frame",
              "name" => "Extract Poster",
              "depends_on" => ["inspect_media", "video_h264_ladder"],
              "params" => %{"role" => "poster", "codec" => "jpg"},
              "required" => false
            }
          ]
        }
      })

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "skipspace",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    now = DateTime.utc_now()

    mark_step!(run.id, "inspect_media", %{
      status: "succeeded",
      output: %{
        "status" => "ok",
        "step_type" => "media.inspect",
        "width" => 1280,
        "height" => 720,
        "duration" => 10.0
      },
      completed_at: now
    })

    mark_step!(run.id, "video_h264_ladder", %{
      status: "succeeded",
      output: %{
        "status" => "ok",
        "step_type" => "media.transcode_h264_ladder",
        "sizes" => ["sd", "hd"],
        "frame_outputs" => %{
          "poster:jpg" => %{
            "status" => "ok",
            "step_type" => "media.extract_frame",
            "mode" => "prepackaged",
            "step_id" => "poster_frame",
            "role" => "poster",
            "codec" => "jpg",
            "bucket" => "space-skipspace",
            "key" => "LeDE9v86ye/poster.jpg",
            "uri" => "s3://space-skipspace/LeDE9v86ye/poster.jpg",
            "src" => "s3://space-skipspace/LeDE9v86ye/poster.jpg",
            "file_size" => 1234,
            "source_step_id" => "video_h264_ladder",
            "source_size" => "hd",
            "space_hash" => "skipspace",
            "embed_hash" => "LeDE9v86ye",
            "version" => 0
          }
        }
      },
      completed_at: now
    })

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, _run} = Flow.reconcile_run(run.id)

      poster_step = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "poster_frame")
      assert poster_step.status == "succeeded"
      assert is_nil(poster_step.scheduled_at)
      assert poster_step.output["mode"] == "prepackaged"
      assert poster_step.output["step_id"] == "poster_frame"
      assert poster_step.output["key"] == "LeDE9v86ye/poster.jpg"

      artifact =
        Repo.get_by!(ArtifactRef,
          flow_run_id: run.id,
          producer_step_id: "poster_frame",
          name: "poster_frame"
        )

      assert artifact.media_type == "image/jpeg"
      assert artifact.size_bytes == 1234
      assert artifact.metadata["source_step_id"] == "video_h264_ladder"

      refute Repo.exists?(
               from job in Job,
                 where: job.worker == "MaveCore.Workers.FlowStepWorker",
                 where: fragment("?->>'flow_run_id' = ?", job.args, ^run.id),
                 where: fragment("?->>'step_id' = ?", job.args, "poster_frame")
             )
    end)
  end

  test "progress reporter persists step execution progress" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "progress-reporter-publish",
        "name" => "Progress Reporter Publish"
      })

    {:ok, _version} =
      Flow.create_version(template.id, %{"definition" => @flame_failure_definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "progressspace",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    step_run =
      Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "video")
      |> StepRun.changeset(%{status: "executing"})
      |> Repo.update!()

    {:ok, reporter} =
      ProgressReporter.start_link(
        flow_run_id: run.id,
        step_run_id: step_run.id,
        step_id: step_run.step_id,
        step_type: step_run.step_type
      )

    :ok =
      ProgressReporter.report(reporter, %{
        "source" => "ffmpeg",
        "stage" => "transcode",
        "codec" => "h264",
        "size" => "sd",
        "container" => "mp4",
        "variants" => ["sd", "hd"],
        "preset" => "veryfast",
        "percent" => 42.4,
        "out_time_ms" => 12_000,
        "total_ms" => 30_000,
        "frame" => 360,
        "fps" => "72.54",
        "speed_x" => "2.418",
        "ffmpeg_elapsed_ms" => 4_963,
        "total_size_bytes" => 1_234_567,
        "dup_frames" => 2,
        "drop_frames" => 1,
        "force" => true
      })

    assert :ok = ProgressReporter.flush(reporter)
    assert :ok = ProgressReporter.stop(reporter)

    step_run = Repo.get!(StepRun, step_run.id)
    assert get_in(step_run.execution_metadata, ["progress", "source"]) == "ffmpeg"
    assert get_in(step_run.execution_metadata, ["progress", "stage"]) == "transcode"
    assert get_in(step_run.execution_metadata, ["progress", "percent"]) == 42.4
    assert get_in(step_run.execution_metadata, ["progress", "out_time_ms"]) == 12_000
    assert get_in(step_run.execution_metadata, ["progress", "variants"]) == ["sd", "hd"]
    assert get_in(step_run.execution_metadata, ["progress", "preset"]) == "veryfast"
    assert get_in(step_run.execution_metadata, ["progress", "frame"]) == 360
    assert get_in(step_run.execution_metadata, ["progress", "fps"]) == 72.54
    assert get_in(step_run.execution_metadata, ["progress", "speed_x"]) == 2.418
    assert get_in(step_run.execution_metadata, ["progress", "ffmpeg_elapsed_ms"]) == 4_963

    assert get_in(step_run.execution_metadata, ["progress", "total_size_bytes"]) ==
             1_234_567

    assert get_in(step_run.execution_metadata, ["progress", "dup_frames"]) == 2
    assert get_in(step_run.execution_metadata, ["progress", "drop_frames"]) == 1
  end

  test "progress reporter rate-limits non-forced database updates" do
    old_config = Application.get_env(:mave_core, :flow_progress_reporter)

    Application.put_env(:mave_core, :flow_progress_reporter,
      interval_ms: 60_000,
      min_percent_delta: 1.0
    )

    on_exit(fn -> restore_env(:flow_progress_reporter, old_config) end)

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "progress-rate-limit-publish",
        "name" => "Progress Rate Limit Publish"
      })

    {:ok, _version} =
      Flow.create_version(template.id, %{"definition" => @flame_failure_definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "progress-rate-limit",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    step_run =
      Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "video")
      |> StepRun.changeset(%{status: "executing"})
      |> Repo.update!()

    {:ok, reporter} =
      ProgressReporter.start_link(
        flow_run_id: run.id,
        step_run_id: step_run.id,
        step_id: step_run.step_id,
        step_type: step_run.step_type
      )

    ProgressReporter.report(reporter, %{
      "source" => "encoding_booster",
      "stage" => "transcode",
      "percent" => 10.0,
      "force" => true
    })

    _ = :sys.get_state(reporter)

    ProgressReporter.report(reporter, %{
      "source" => "encoding_booster",
      "stage" => "transcode",
      "percent" => 60.0
    })

    _ = :sys.get_state(reporter)

    persisted = Repo.get!(StepRun, step_run.id)
    assert get_in(persisted.execution_metadata, ["progress", "percent"]) == 10.0

    assert :ok = ProgressReporter.stop(reporter)

    persisted = Repo.get!(StepRun, step_run.id)
    assert get_in(persisted.execution_metadata, ["progress", "percent"]) == 60.0
  end

  test "stale executing recovery resets orphaned steps and enqueues them again" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "stale-step-recovery-publish",
        "name" => "Stale Step Recovery Publish"
      })

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => @definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "recover-space",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    now = DateTime.utc_now()
    started_at = DateTime.add(now, -10 * 60, :second)

    Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "source")
    |> StepRun.changeset(%{
      status: "executing",
      started_at: started_at,
      execution_metadata: %{"progress" => %{"percent" => 45.0}}
    })
    |> Repo.update!()

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, %{recovered: 1}} =
               Flow.recover_stale_executing_steps(
                 now: now,
                 older_than_ms: :timer.minutes(5),
                 limit: 10
               )

      step = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "source")
      assert step.status == "scheduled"
      assert is_nil(step.started_at)
      assert get_in(step.execution_metadata, ["progress", "percent"]) == 45.0
      assert get_in(step.execution_metadata, ["recovery", "reason"]) == "orphaned_executing_step"
      assert get_in(step.execution_metadata, ["recovery", "count"]) == 1
      assert get_in(step.execution_metadata, ["retry_policy", "orphan_recoveries"]) == 1

      step_job =
        Repo.one!(
          from job in Job,
            where: job.worker == "MaveCore.Workers.FlowStepWorker",
            where: fragment("?->>'flow_run_id' = ?", job.args, ^run.id),
            where: fragment("?->>'step_id' = ?", job.args, "source")
        )

      assert step_job.queue == "flow_steps"
    end)
  end

  test "stale executing recovery leaves steps with active jobs alone" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "stale-step-active-job-publish",
        "name" => "Stale Step Active Job Publish"
      })

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => @definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "recover-space",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    now = DateTime.utc_now()
    started_at = DateTime.add(now, -10 * 60, :second)

    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, _run} = Flow.reconcile_run(run.id)

      Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "source")
      |> StepRun.changeset(%{status: "executing", started_at: started_at})
      |> Repo.update!()

      assert {:ok, %{recovered: 0}} =
               Flow.recover_stale_executing_steps(
                 now: now,
                 older_than_ms: :timer.minutes(5),
                 limit: 10
               )

      step = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "source")
      assert step.status == "executing"
      refute Map.has_key?(step.execution_metadata, "recovery")
    end)
  end

  test "stale non-executing recovery restores scheduled steps without live jobs" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "stale-scheduled-recovery-publish",
        "name" => "Stale Scheduled Recovery Publish"
      })

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => @definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "recover-space",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    now = DateTime.utc_now()
    stale_at = DateTime.add(now, -10 * 60, :second)

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, _run} = Flow.reconcile_run(run.id)

      original_job =
        Repo.one!(
          from job in Job,
            where: job.worker == "MaveCore.Workers.FlowStepWorker",
            where: fragment("?->>'flow_run_id' = ?", job.args, ^run.id),
            where: fragment("?->>'step_id' = ?", job.args, "source")
        )

      assert :ok = Oban.cancel_job(original_job)

      StepRun
      |> where([step_run], step_run.flow_run_id == ^run.id and step_run.step_id == "source")
      |> Repo.update_all(set: [updated_at: stale_at])

      assert {:ok, %{reconciled: 1, errors: 0}} =
               Flow.recover_stale_nonexecuting_runs(
                 now: now,
                 older_than_ms: :timer.minutes(5),
                 limit: 10
               )

      jobs =
        Repo.all(
          from job in Job,
            where: job.worker == "MaveCore.Workers.FlowStepWorker",
            where: fragment("?->>'flow_run_id' = ?", job.args, ^run.id),
            where: fragment("?->>'step_id' = ?", job.args, "source"),
            order_by: [asc: job.id]
        )

      assert Enum.map(jobs, & &1.state) == ["cancelled", "available"]
    end)
  end

  test "stale non-executing recovery schedules a queued run without jobs" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "stale-queued-recovery-publish",
        "name" => "Stale Queued Recovery Publish"
      })

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => @definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "recover-space",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    now = DateTime.utc_now()
    stale_at = DateTime.add(now, -10 * 60, :second)

    StepRun
    |> where([step_run], step_run.flow_run_id == ^run.id and step_run.step_id == "source")
    |> Repo.update_all(set: [updated_at: stale_at])

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, %{reconciled: 1, errors: 0}} =
               Flow.recover_stale_nonexecuting_runs(
                 now: now,
                 older_than_ms: :timer.minutes(5),
                 limit: 10
               )

      source = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "source")
      assert source.status == "scheduled"

      assert Repo.exists?(
               from job in Job,
                 where: job.worker == "MaveCore.Workers.FlowStepWorker",
                 where: fragment("?->>'flow_run_id' = ?", job.args, ^run.id),
                 where: fragment("?->>'step_id' = ?", job.args, "source"),
                 where: job.state == "available"
             )
    end)
  end

  test "stale non-executing recovery leaves scheduled steps with live jobs alone" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "stale-live-job-recovery-publish",
        "name" => "Stale Live Job Recovery Publish"
      })

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => @definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "recover-space",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    now = DateTime.utc_now()
    stale_at = DateTime.add(now, -10 * 60, :second)

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, _run} = Flow.reconcile_run(run.id)

      StepRun
      |> where([step_run], step_run.flow_run_id == ^run.id and step_run.step_id == "source")
      |> Repo.update_all(set: [updated_at: stale_at])

      assert {:ok, %{reconciled: 0, skipped: 1, errors: 0}} =
               Flow.recover_stale_nonexecuting_runs(
                 now: now,
                 older_than_ms: :timer.minutes(5),
                 limit: 10
               )

      assert 1 ==
               Repo.aggregate(
                 from(job in Job,
                   where: job.worker == "MaveCore.Workers.FlowStepWorker",
                   where: fragment("?->>'flow_run_id' = ?", job.args, ^run.id),
                   where: fragment("?->>'step_id' = ?", job.args, "source"),
                   where: job.state == "available"
                 ),
                 :count
               )
    end)
  end

  test "stale executing recovery fails a step after its orphan recovery budget is exhausted" do
    Application.put_env(:mave_core, :flow_step_retry_policy,
      max_execution_attempts: 3,
      max_orphan_recoveries: 1
    )

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "stale-step-recovery-exhausted-publish",
        "name" => "Stale Step Recovery Exhausted Publish"
      })

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => @definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "recover-space",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    now = DateTime.utc_now()
    started_at = DateTime.add(now, -10 * 60, :second)

    Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "source")
    |> StepRun.changeset(%{
      status: "executing",
      attempt: 2,
      started_at: started_at,
      execution_metadata: %{
        "retry_policy" => %{"cycle_attempts" => 2, "orphan_recoveries" => 1},
        "recovery" => %{"reason" => "orphaned_executing_step"}
      }
    })
    |> Repo.update!()

    assert {:ok, %{recovered: 0, exhausted: 1}} =
             Flow.recover_stale_executing_steps(
               now: now,
               older_than_ms: :timer.minutes(5),
               limit: 10
             )

    step = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "source")
    assert step.status == "failed"
    assert step.attempt == 2
    assert step.error =~ "automatic orphan recovery exhausted"
    assert get_in(step.execution_metadata, ["retry_policy", "exhausted"]) == true

    assert get_in(step.execution_metadata, ["recovery", "reason"]) ==
             "automatic_recovery_exhausted"

    assert Repo.get!(Run, run.id).status == "failed"
  end

  test "manual retry resets the automatic budget without erasing lifetime attempts" do
    Application.put_env(:mave_core, :flow_step_retry_policy,
      max_execution_attempts: 3,
      max_orphan_recoveries: 1
    )

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "manual-retry-budget-reset-publish",
        "name" => "Manual Retry Budget Reset Publish"
      })

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => @definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "recover-space",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "source")
    |> StepRun.changeset(%{
      status: "failed",
      attempt: 3,
      completed_at: DateTime.utc_now(),
      error: "automatic execution attempts exhausted",
      execution_metadata: %{
        "retry_policy" => %{
          "cycle_attempts" => 3,
          "orphan_recoveries" => 1,
          "exhausted" => true
        }
      }
    })
    |> Repo.update!()

    run
    |> Run.changeset(%{
      status: "failed",
      completed_at: DateTime.utc_now(),
      error: "one or more required steps failed"
    })
    |> Repo.update!()

    assert {:ok, retried_run} = Flow.retry_step(run.id, "source", enqueue_jobs: false)
    assert retried_run.status == "running"

    reset_step = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "source")
    assert reset_step.status == "scheduled"
    assert reset_step.attempt == 3
    assert get_in(reset_step.execution_metadata, ["retry_policy", "cycle_attempts"]) == 0
    assert get_in(reset_step.execution_metadata, ["retry_policy", "orphan_recoveries"]) == 0
    assert get_in(reset_step.execution_metadata, ["retry_policy", "reset"]) == "manual"

    assert {:ok, _output} =
             Flow.execute_step(run.id, "source", enqueue_coordinator: false)

    completed_step = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "source")
    assert completed_step.status == "succeeded"
    assert completed_step.attempt == 4
    assert get_in(completed_step.execution_metadata, ["retry_policy", "cycle_attempts"]) == 1
  end

  test "stale executing recovery resets orphaned executing jobs from a restarted producer" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "stale-step-orphaned-executing-job-publish",
        "name" => "Stale Step Orphaned Executing Job Publish"
      })

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => @definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "recover-space",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    now = DateTime.utc_now()
    started_at = DateTime.add(now, -10 * 60, :second)

    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, _run} = Flow.reconcile_run(run.id)

      Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "source")
      |> StepRun.changeset(%{status: "executing", started_at: started_at})
      |> Repo.update!()

      Job
      |> where([job], job.worker == "MaveCore.Workers.FlowStepWorker")
      |> where([job], fragment("?->>'flow_run_id' = ?", job.args, ^run.id))
      |> where([job], fragment("?->>'step_id' = ?", job.args, "source"))
      |> Repo.update_all(
        set: [
          state: "executing",
          attempted_by: [Atom.to_string(Node.self()), "stale-producer"]
        ]
      )

      assert {:ok, %{recovered: 1}} =
               Flow.recover_stale_executing_steps(
                 now: now,
                 older_than_ms: :timer.minutes(5),
                 limit: 10
               )

      step = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "source")
      assert step.status == "scheduled"
      assert is_nil(step.started_at)
      assert get_in(step.execution_metadata, ["recovery", "reason"]) == "orphaned_executing_step"

      jobs =
        Job
        |> where([job], job.worker == "MaveCore.Workers.FlowStepWorker")
        |> where([job], fragment("?->>'flow_run_id' = ?", job.args, ^run.id))
        |> where([job], fragment("?->>'step_id' = ?", job.args, "source"))
        |> Repo.all()

      assert Enum.any?(jobs, &(&1.state == "cancelled"))
      assert Enum.any?(jobs, &(&1.state == "available"))
    end)
  end

  test "stale executing recovery resets orphaned executing jobs from a dead node" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "stale-step-orphaned-dead-node-publish",
        "name" => "Stale Step Orphaned Dead Node Publish"
      })

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => @definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "recover-space",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    now = DateTime.utc_now()
    started_at = DateTime.add(now, -10 * 60, :second)

    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, _run} = Flow.reconcile_run(run.id)

      Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "source")
      |> StepRun.changeset(%{status: "executing", started_at: started_at})
      |> Repo.update!()

      Job
      |> where([job], job.worker == "MaveCore.Workers.FlowStepWorker")
      |> where([job], fragment("?->>'flow_run_id' = ?", job.args, ^run.id))
      |> where([job], fragment("?->>'step_id' = ?", job.args, "source"))
      |> Repo.update_all(
        set: [
          state: "executing",
          attempted_by: ["mave-core@dead-node", "stale-producer"]
        ]
      )

      assert {:ok, %{recovered: 1}} =
               Flow.recover_stale_executing_steps(
                 now: now,
                 older_than_ms: :timer.minutes(5),
                 limit: 10
               )

      step = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "source")
      assert step.status == "scheduled"
      assert is_nil(step.started_at)
      assert get_in(step.execution_metadata, ["recovery", "reason"]) == "orphaned_executing_step"
    end)
  end

  test "flow recovery worker delegates stale step recovery" do
    old_config = Application.get_env(:mave_core, :flow_stale_step_recovery)

    Application.put_env(:mave_core, :flow_stale_step_recovery,
      enabled: true,
      older_than_ms: 1,
      limit: 1
    )

    on_exit(fn ->
      restore_env(:flow_stale_step_recovery, old_config)
    end)

    assert :ok = FlowRecoveryWorker.perform(%Job{args: %{}})
  end

  test "import queue snoozes when the same space already has its fair share running" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "import_fairness_publish",
        "name" => "Import Fairness Publish"
      })

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => @definition})

    run_input = %{
      "space_hash" => "fairspace",
      "embed_hash" => "LeDE9v86ye",
      "input_url" => "https://example.com/video.mp4",
      "priority" => "import"
    }

    {:ok, executing_run} = Flow.start_run(template.slug, run_input, enqueue: false)
    {:ok, waiting_run} = Flow.start_run(template.slug, run_input, enqueue: false)

    {:ok, _run} = Flow.reconcile_run(executing_run.id, enqueue_jobs: false)
    {:ok, _run} = Flow.reconcile_run(waiting_run.id, enqueue_jobs: false)

    Repo.get_by!(StepRun, flow_run_id: executing_run.id, step_id: "source")
    |> StepRun.changeset(%{status: "executing"})
    |> Repo.update!()

    old_config = Application.get_env(:mave_core, :flow_fair_queues)

    Application.put_env(:mave_core, :flow_fair_queues,
      flow_imports: [space_concurrency: 1, snooze_seconds: 7]
    )

    on_exit(fn ->
      restore_env(:flow_fair_queues, old_config)
    end)

    assert {:snooze, 7} =
             FlowStepWorker.perform(%Job{
               queue: "flow_imports",
               args: %{"flow_run_id" => waiting_run.id, "step_id" => "source"}
             })

    assert Repo.get_by!(StepRun, flow_run_id: waiting_run.id, step_id: "source").status ==
             "scheduled"
  end

  test "flow step jobs are only unique while incomplete" do
    changeset = FlowStepWorker.new(%{flow_run_id: "run_1", step_id: "source"})

    assert %{
             fields: [:worker, :args],
             keys: [:flow_run_id, :step_id],
             period: 300,
             states: states
           } = Ecto.Changeset.get_change(changeset, :unique)

    assert states == Oban.Job.unique_states(:incomplete)
  end

  test "oban retry can reclaim its own interrupted executing step" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "interrupted_step_retry_publish",
        "name" => "Interrupted Step Retry Publish"
      })

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => @definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "retryspace",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4",
          "priority" => "import"
        },
        enqueue: false
      )

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "source")
    |> StepRun.changeset(%{status: "executing", attempt: 1})
    |> Repo.update!()

    old_config = Application.get_env(:mave_core, :flow_fair_queues)

    Application.put_env(:mave_core, :flow_fair_queues,
      flow_imports: [space_concurrency: 1, snooze_seconds: 7]
    )

    on_exit(fn ->
      restore_env(:flow_fair_queues, old_config)
    end)

    assert :ok =
             FlowStepWorker.perform(%Job{
               queue: "flow_imports",
               attempt: 2,
               args: %{"flow_run_id" => run.id, "step_id" => "source"}
             })

    source_step = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "source")
    assert source_step.status == "succeeded"
    assert source_step.attempt == 2
  end

  test "oban retry fails before execution when the Flow attempt budget is exhausted" do
    Application.put_env(:mave_core, :flow_step_retry_policy,
      max_execution_attempts: 3,
      max_orphan_recoveries: 1
    )

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "interrupted-step-budget-exhausted-publish",
        "name" => "Interrupted Step Budget Exhausted Publish"
      })

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => @definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "retryspace",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4",
          "priority" => "import"
        },
        enqueue: false
      )

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "source")
    |> StepRun.changeset(%{
      status: "executing",
      attempt: 3,
      execution_metadata: %{
        "retry_policy" => %{"cycle_attempts" => 3, "orphan_recoveries" => 0}
      }
    })
    |> Repo.update!()

    assert :ok =
             FlowStepWorker.perform(%Job{
               queue: "flow_imports",
               attempt: 648,
               args: %{"flow_run_id" => run.id, "step_id" => "source"}
             })

    source_step = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "source")
    assert source_step.status == "failed"
    assert source_step.attempt == 3
    assert source_step.error =~ "automatic execution attempts exhausted (3/3)"
    assert get_in(source_step.execution_metadata, ["retry_policy", "exhausted"]) == true
  end

  test "jobs for terminal runs complete without entering Oban retry" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "terminal-run-job-cleanup-publish",
        "name" => "Terminal Run Job Cleanup Publish"
      })

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => @definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "retryspace",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    run
    |> Run.changeset(%{
      status: "failed",
      completed_at: DateTime.utc_now(),
      error: "one or more required steps failed"
    })
    |> Repo.update!()

    assert :ok =
             FlowStepWorker.perform(%Job{
               queue: "flow_low",
               attempt: 646,
               max_attempts: 648,
               args: %{"flow_run_id" => run.id, "step_id" => "source"}
             })

    source_step = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "source")
    assert source_step.attempt == 0
    assert source_step.status == "queued"
  end

  test "transient FLAME failures are snoozed before becoming terminal step failures" do
    old_flame_pool = Application.get_env(:mave_core, :flow_flame_pool)
    old_retry_config = Application.get_env(:mave_core, :flow_step_auto_retry)

    Application.put_env(:mave_core, :flow_flame_pool, :missing_flow_flame_pool)

    Application.put_env(:mave_core, :flow_step_auto_retry,
      max_attempts: 2,
      backoff_seconds: [12],
      jitter_seconds: 0
    )

    on_exit(fn ->
      restore_env(:flow_flame_pool, old_flame_pool)
      restore_env(:flow_step_auto_retry, old_retry_config)
    end)

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "transient_flame_retry_publish",
        "name" => "Transient Flame Retry Publish"
      })

    {:ok, _version} =
      Flow.create_version(template.id, %{"definition" => @flame_failure_definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "retryspace",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    job = %Job{
      queue: "flow_steps",
      attempt: 1,
      args: %{"flow_run_id" => run.id, "step_id" => "video"}
    }

    assert {:snooze, 12} = FlowStepWorker.perform(job)

    step = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "video")
    assert step.status == "scheduled"
    assert step.attempt == 1
    assert is_nil(step.started_at)
    assert is_nil(step.completed_at)
    assert step.error =~ "retrying transient failure 1/2 in 12s"
    assert get_in(step.execution_metadata, ["retry", "automatic"]) == true
    assert get_in(step.execution_metadata, ["retry", "next_attempt"]) == 2
    assert get_in(step.execution_metadata, ["retry_policy", "cycle_attempts"]) == 1

    assert {:error, error} = FlowStepWorker.perform(job)
    assert error =~ "flame_execution_failed"

    step = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "video")
    assert step.status == "failed"
    assert step.attempt == 2
    assert %DateTime{} = step.completed_at
    assert step.error =~ "flame_execution_failed"
  end

  test "resumable H264 chunk failures receive an extended execution budget" do
    old_retry_config = Application.get_env(:mave_core, :flow_step_auto_retry)

    Application.put_env(:mave_core, :flow_step_auto_retry,
      max_attempts: 3,
      backoff_seconds: 1,
      jitter_seconds: 0
    )

    Application.put_env(:mave_core, :encoding_booster,
      enabled: true,
      fallback_enabled: true
    )

    Application.put_env(
      :mave_core,
      :encoding_booster_adapter,
      ChunkFailedEncodingBoosterAdapterStub
    )

    on_exit(fn -> restore_env(:flow_step_auto_retry, old_retry_config) end)

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "resumable-h264-chunk-retry",
        "name" => "Resumable H264 Chunk Retry"
      })

    definition = %{
      "steps" => [
        %{"id" => "inspect_media", "type" => "media.inspect", "name" => "Inspect Media"},
        %{
          "id" => "video_h264_ladder",
          "type" => "media.transcode_h264_ladder",
          "name" => "Transcode H264 Ladder",
          "depends_on" => ["inspect_media"],
          "params" => %{"sizes" => ["hd"], "strict" => true}
        }
      ]
    }

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "retryspace",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    mark_step!(run.id, "inspect_media", %{
      status: "succeeded",
      output: %{
        "status" => "ok",
        "step_type" => "media.inspect",
        "width" => 1280,
        "height" => 720,
        "duration" => 18_922.0,
        "audio" => true
      },
      completed_at: DateTime.utc_now()
    })

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    job = %Job{
      queue: "flow_booster",
      attempt: 1,
      args: %{"flow_run_id" => run.id, "step_id" => "video_h264_ladder"}
    }

    for _attempt <- 1..4 do
      assert {:snooze, 1} = FlowStepWorker.perform(job)
    end

    step = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "video_h264_ladder")
    assert step.status == "scheduled"
    assert step.attempt == 4
    assert step.error =~ "retrying transient failure 4/8 in 1s"
    assert get_in(step.execution_metadata, ["retry", "max_attempts"]) == 8
    assert get_in(step.execution_metadata, ["retry_policy", "cycle_attempts"]) == 4
    assert get_in(step.execution_metadata, ["retry_policy", "max_execution_attempts"]) == 8
  end

  test "status-only booster 502 failures receive a bounded extended retry budget" do
    old_retry_config = Application.get_env(:mave_core, :flow_step_auto_retry)

    Application.put_env(:mave_core, :flow_step_auto_retry,
      max_attempts: 3,
      backoff_seconds: 1,
      booster_gateway_max_attempts: 5,
      booster_gateway_backoff_seconds: 1,
      jitter_seconds: 0
    )

    Application.put_env(:mave_core, :encoding_booster,
      enabled: true,
      fallback_enabled: false
    )

    Application.put_env(
      :mave_core,
      :encoding_booster_adapter,
      GatewayEncodingBoosterAdapterStub
    )

    on_exit(fn -> restore_env(:flow_step_auto_retry, old_retry_config) end)

    {:ok, template} =
      Flow.create_template(%{
        "slug" => "booster-gateway-retry",
        "name" => "Booster Gateway Retry"
      })

    {:ok, _version} =
      Flow.create_version(template.id, %{"definition" => @cpu_video_booster_definition})

    run = create_scheduled_booster_run!(template, "retryspace")

    for _attempt <- 1..4 do
      assert {:snooze, 1} = perform_booster_step(run)
    end

    step =
      Repo.get_by!(StepRun,
        flow_run_id: run.id,
        step_id: "clip_h264_sd_keyframes"
      )

    assert step.status == "scheduled"
    assert step.attempt == 4
    assert step.error =~ "retrying transient failure 4/5 in 1s"
    assert get_in(step.execution_metadata, ["retry", "max_attempts"]) == 5
    assert get_in(step.execution_metadata, ["retry_policy", "max_execution_attempts"]) == 5

    assert {:error, error} = perform_booster_step(run)
    assert error =~ "encoding_booster_http_status"

    step = Repo.get!(StepRun, step.id)
    assert step.status == "failed"
    assert step.attempt == 5
    assert step.error =~ "encoding_booster_http_status"
  end

  test "claiming an automatic retry clears its stale error and retry marker" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "clear-transient-retry-state-publish",
        "name" => "Clear Transient Retry State Publish"
      })

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => @definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "retryspace",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "source")
    |> StepRun.changeset(%{
      status: "scheduled",
      attempt: 1,
      started_at: nil,
      error: "retrying transient failure 1/3 in 13s: temporary failure",
      execution_metadata: %{
        "retry" => %{"automatic" => true, "next_attempt" => 2},
        "retry_policy" => %{"cycle_attempts" => 1}
      }
    })
    |> Repo.update!()

    assert {:ok, _output} =
             Flow.execute_step(run.id, "source", enqueue_coordinator: false)

    step = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "source")
    assert step.status == "succeeded"
    assert step.attempt == 2
    assert is_nil(step.error)
    refute Map.has_key?(step.execution_metadata, "retry")
  end

  test "input URL alone does not make a processing player ready" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "queued_processing_view_publish",
        "name" => "Queued Processing View Publish"
      })

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => @definition})

    {:ok, _run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4",
          "priority" => "import"
        },
        enqueue: false
      )

    refute Embeds.processing_player_ready?("ubg50", "LeDE9v86ye")
    refute Embeds.processing_upload_ready?("ubg50", "LeDE9v86ye")
  end

  test "completed H264 ladder alone does not make the processing player ready" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "early-h264-player-#{System.unique_integer([:positive])}",
        "name" => "Early H264 Player"
      })

    {:ok, _version} =
      Flow.create_version(template.id, %{
        "definition" => %{
          "steps" => [
            %{
              "id" => "video_h264_ladder",
              "type" => "media.transcode_h264_ladder",
              "name" => "H264 Ladder"
            }
          ]
        }
      })

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    ladder = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "video_h264_ladder")

    ladder
    |> StepRun.changeset(%{
      status: "succeeded",
      output: %{
        "status" => "ok",
        "renditions" => [
          %{
            "type" => "video",
            "codec" => "h264",
            "container" => "mp4",
            "progress" => 99.0,
            "rendition_key" => "LeDE9v86ye/h264_sd.mp4"
          }
        ]
      }
    })
    |> Repo.update!()

    refute Embeds.processing_player_ready?("ubg50", "LeDE9v86ye")

    ladder
    |> StepRun.changeset(%{
      status: "succeeded",
      output: %{
        "status" => "ok",
        "renditions" => [
          %{
            "type" => "video",
            "codec" => "h264",
            "container" => "mp4",
            "progress" => 100.0,
            "rendition_key" => "LeDE9v86ye/h264_sd.mp4"
          }
        ]
      }
    })
    |> Repo.update!()

    refute Embeds.processing_player_ready?("ubg50", "LeDE9v86ye")
    refute Embeds.processing_upload_ready?("ubg50", "LeDE9v86ye")
  end

  test "completed H264 video rendition alone does not make the processing player ready" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "early-h264-video-player-#{System.unique_integer([:positive])}",
        "name" => "Early H264 Video Player"
      })

    {:ok, _version} =
      Flow.create_version(template.id, %{
        "definition" => %{
          "steps" => [
            %{
              "id" => "video_h264_hd",
              "type" => "media.transcode_video",
              "name" => "H264 HD"
            }
          ]
        }
      })

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    rendition = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "video_h264_hd")

    rendition
    |> StepRun.changeset(%{
      status: "succeeded",
      output: %{
        "status" => "ok",
        "rendition" => %{
          "type" => "video",
          "codec" => "h264",
          "container" => "mp4",
          "progress" => 100.0,
          "rendition_key" => "LeDE9v86ye/h264_hd.mp4"
        }
      }
    })
    |> Repo.update!()

    refute Embeds.processing_player_ready?("ubg50", "LeDE9v86ye")
  end

  test "optional failed steps do not fail the run or block downstream required steps" do
    {:ok, template} =
      Flow.create_template(%{"slug" => "optional_publish", "name" => "Optional Publish"})

    {:ok, _version} =
      Flow.create_version(template.id, %{"definition" => @optional_failure_definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)
    assert {:ok, _source_output} = Flow.execute_step(run.id, "source", enqueue_coordinator: false)

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    optional_notify = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "optional_notify")
    manifest = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "manifest")

    assert optional_notify.status == "scheduled"
    assert manifest.status == "queued"

    assert {:error, {:event_notify_webhook_failed, :missing_callback_url}} =
             Flow.execute_step(run.id, "optional_notify", enqueue_coordinator: false)

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    optional_notify = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "optional_notify")
    manifest = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "manifest")

    assert optional_notify.status == "failed"
    assert manifest.status == "scheduled"

    assert {:ok, _manifest_output} =
             Flow.execute_step(run.id, "manifest", enqueue_coordinator: false)

    {:ok, final_run} = Flow.reconcile_run(run.id, enqueue_jobs: false)
    assert final_run.status == "succeeded"
  end

  test "retry_step resets a step subtree and keeps upstream successes intact" do
    {:ok, template} =
      Flow.create_template(%{"slug" => "retry_publish", "name" => "Retry Publish"})

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => @definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)
    assert {:ok, _source_output} = Flow.execute_step(run.id, "source", enqueue_coordinator: false)
    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    assert {:ok, _manifest_output} =
             Flow.execute_step(run.id, "manifest", enqueue_coordinator: false)

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)
    assert {:ok, _notify_output} = Flow.execute_step(run.id, "notify", enqueue_coordinator: false)
    {:ok, final_run} = Flow.reconcile_run(run.id, enqueue_jobs: false)
    assert final_run.status == "succeeded"

    assert Repo.get_by!(ArtifactRef,
             flow_run_id: run.id,
             producer_step_id: "manifest",
             name: "manifest"
           )

    assert {:ok, retried_run} = Flow.retry_step(run.id, "manifest", enqueue_jobs: false)
    assert retried_run.status == "running"

    source = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "source")
    manifest = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "manifest")
    notify = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "notify")

    assert source.status == "succeeded"
    assert manifest.status == "scheduled"
    assert %DateTime{} = manifest.scheduled_at
    assert is_nil(manifest.output)
    assert is_nil(manifest.completed_at)
    assert notify.status == "queued"
    assert is_nil(notify.scheduled_at)
    assert is_nil(notify.output)
    assert is_nil(notify.completed_at)

    refute Repo.get_by(ArtifactRef,
             flow_run_id: run.id,
             producer_step_id: "manifest",
             name: "manifest"
           )
  end

  test "recover_run rewinds an invalid succeeded media producer for failed HLS packaging" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "recover_audio_publish",
        "name" => "Recover Audio Publish"
      })

    {:ok, _version} =
      Flow.create_version(template.id, %{"definition" => @audio_hls_recovery_definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    mark_step!(run.id, "source", %{
      status: "succeeded",
      output: %{"status" => "ok", "space_hash" => "ubg50", "embed_hash" => "LeDE9v86ye"},
      completed_at: now
    })

    mark_step!(run.id, "transcode_audio", %{
      status: "succeeded",
      output: %{
        "status" => "ok",
        "step_type" => "media.transcode_audio",
        "bucket" => "space-ubg50",
        "key" => "LeDE9v86ye/audio.mp3",
        "audio_track" => %{
          "id" => "default",
          "default" => true,
          "path" => "s3://space-ubg50/LeDE9v86ye/audio.mp3"
        }
      },
      completed_at: now
    })

    mark_step!(run.id, "hls_audio_default", %{
      status: "failed",
      error:
        ~s({:media_package_hls_audio_failed, {:encoding_booster_http_status, 500, "could not package HLS"}}),
      completed_at: now
    })

    mark_step!(run.id, "hls_master", %{
      status: "failed",
      error: "blocked by dependency hls_audio_default",
      completed_at: now
    })

    run
    |> Run.changeset(%{
      status: "failed",
      error: "one or more required steps failed",
      completed_at: now
    })
    |> Repo.update!()

    assert {:ok, recovered_run} = Flow.recover_run(run.id, enqueue_jobs: false)
    assert recovered_run.status == "running"

    source = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "source")
    transcode_audio = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "transcode_audio")
    hls_audio = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "hls_audio_default")
    hls_master = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "hls_master")
    manifest = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "manifest")

    assert source.status == "succeeded"
    assert transcode_audio.status == "scheduled"
    assert %DateTime{} = transcode_audio.scheduled_at
    assert is_nil(transcode_audio.output)
    assert hls_audio.status == "queued"
    assert hls_master.status == "queued"
    assert manifest.status == "queued"
  end

  test "recover_run preserves completed encodes and restarts only interrupted renditions" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "recover-parallel-hls-publish",
        "name" => "Recover Parallel HLS Publish"
      })

    {:ok, _version} =
      Flow.create_version(template.id, %{"definition" => @parallel_hls_recovery_definition})

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "igkry",
          "embed_hash" => "KOXxtI9sNI",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    sd_output = %{"status" => "ok", "key" => "KOXxtI9sNI/h264_sd.mp4"}

    mark_step!(run.id, "source", %{
      status: "succeeded",
      output: %{"status" => "ok"},
      completed_at: now
    })

    mark_step!(run.id, "video_h264_sd", %{
      status: "succeeded",
      output: sd_output,
      completed_at: now
    })

    for step_id <- ["video_h264_hd", "video_h264_fhd"] do
      mark_step!(run.id, step_id, %{
        status: "executing",
        attempt: 2,
        started_at: now,
        execution_metadata: %{
          "retry_policy" => %{"cycle_attempts" => 2, "orphan_recoveries" => 1}
        }
      })
    end

    mark_step!(run.id, "hls_h264_sd", %{
      status: "failed",
      error: "{:hls_upload_failed, \"segment_2166.m4s\", \"S3 error: 403\"}",
      completed_at: now
    })

    mark_step!(run.id, "hls_master_sd", %{
      status: "failed",
      error: "blocked by dependency hls_h264_sd",
      completed_at: now
    })

    run
    |> Run.changeset(%{
      status: "failed",
      error: "one or more required steps failed",
      completed_at: now
    })
    |> Repo.update!()

    assert {:ok, recovered_run} = Flow.recover_run(run.id, enqueue_jobs: false)
    assert recovered_run.status == "running"

    source = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "source")
    sd = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "video_h264_sd")
    hd = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "video_h264_hd")
    fhd = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "video_h264_fhd")
    hls_sd = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "hls_h264_sd")

    assert source.status == "succeeded"
    assert sd.status == "succeeded"
    assert sd.output == sd_output
    assert hd.status == "scheduled"
    assert fhd.status == "scheduled"
    assert hd.attempt == 2
    assert fhd.attempt == 2
    assert get_in(hd.execution_metadata, ["retry_policy", "cycle_attempts"]) == 0
    assert get_in(fhd.execution_metadata, ["retry_policy", "cycle_attempts"]) == 0
    assert hls_sd.status == "scheduled"
  end

  test "start_run broadcasts flow run updates" do
    {:ok, template} =
      Flow.create_template(%{"slug" => "broadcast_publish", "name" => "Broadcast Publish"})

    {:ok, _version} = Flow.create_version(template.id, %{"definition" => @definition})

    :ok = FlowEvents.subscribe()

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    assert_receive {:flow_run_updated, %{"flow_run_id" => flow_run_id, "status" => "running"}}
    assert flow_run_id == run.id
  end

  @tag :audio_pipeline
  test "install_preset creates or reuses the preset template/version" do
    assert {:ok, first_install} = Flow.install_preset("publish_default")
    assert first_install.version_created

    assert {:ok, second_install} = Flow.install_preset("publish_default")
    refute second_install.version_created

    template_count =
      Repo.aggregate(
        from(template in Template, where: template.slug == "publish_default"),
        :count
      )

    version_count =
      Repo.aggregate(
        from(version in Version,
          where: version.flow_template_id == ^first_install.template.id
        ),
        :count
      )

    assert {:ok, %{"definition" => definition}} = Presets.fetch("publish_default")
    step_ids = Enum.map(definition["steps"], & &1["id"])
    manifest_step = Enum.find(definition["steps"], &(&1["id"] == "manifest"))

    assert template_count == 1
    assert version_count == 1
    assert definition["encoding_booster_contract"] == "mave-production-v2"
    assert "clip_h264_sd_keyframes" in step_ids
    assert "clip_h264_hd_keyframes" in step_ids
    assert "clip_h264_fhd_keyframes" in step_ids

    for codec <- ~w(hevc av1), size <- ~w(sd hd fhd qhd uhd) do
      assert "clip_#{codec}_#{size}" in step_ids
    end

    assert "video_h264_sd" in step_ids
    assert "video_h264_hd" in step_ids
    assert "video_h264_fhd" in step_ids
    assert "video_h264_qhd" in step_ids
    assert "video_h264_uhd" in step_ids
    assert "hls_h264_fhd" in step_ids
    assert "hls_h264_qhd" in step_ids
    assert "hls_h264_uhd" in step_ids
    assert "hls_master_metadata" in step_ids
    assert "hls_master_qhd" in step_ids
    assert "hls_master_high" in step_ids
    assert "poster_frame_webp" in step_ids
    assert "poster_frame_avif" in step_ids
    assert "thumbnail_frame_webp" in step_ids
    assert "thumbnail_frame_avif" in step_ids
    assert "translate_subtitles" in step_ids

    h264_steps =
      definition["steps"]
      |> Enum.filter(
        &(&1["id"] in ~w(video_h264_sd video_h264_hd video_h264_fhd video_h264_qhd video_h264_uhd))
      )
      |> Map.new(&{&1["id"], &1})

    transcode_audio = Enum.find(definition["steps"], &(&1["id"] == "transcode_audio"))
    translate_subtitles = Enum.find(definition["steps"], &(&1["id"] == "translate_subtitles"))
    hls_h264_hd = Enum.find(definition["steps"], &(&1["id"] == "hls_h264_hd"))
    hls_h264_fhd = Enum.find(definition["steps"], &(&1["id"] == "hls_h264_fhd"))
    hls_h264_qhd = Enum.find(definition["steps"], &(&1["id"] == "hls_h264_qhd"))
    hls_h264_uhd = Enum.find(definition["steps"], &(&1["id"] == "hls_h264_uhd"))
    hls_audio_default = Enum.find(definition["steps"], &(&1["id"] == "hls_audio_default"))
    hls_master_sd = Enum.find(definition["steps"], &(&1["id"] == "hls_master_sd"))
    hls_master_hd = Enum.find(definition["steps"], &(&1["id"] == "hls_master_hd"))
    hls_master = Enum.find(definition["steps"], &(&1["id"] == "hls_master"))

    hls_master_metadata =
      Enum.find(definition["steps"], &(&1["id"] == "hls_master_metadata"))

    hls_master_qhd = Enum.find(definition["steps"], &(&1["id"] == "hls_master_qhd"))
    hls_master_high = Enum.find(definition["steps"], &(&1["id"] == "hls_master_high"))

    assert transcode_audio["lane"] == "fast"
    assert h264_steps["video_h264_sd"]["lane"] == "fast"
    assert h264_steps["video_h264_hd"]["lane"] == "fast"
    assert h264_steps["video_h264_fhd"]["lane"] == "fast"

    refute Map.has_key?(h264_steps["video_h264_sd"]["params"], "prepackage_frames")

    for step_id <- ["poster_frame", "thumbnail_frame", "placeholder_frame"] do
      assert Enum.find(definition["steps"], &(&1["id"] == step_id))["depends_on"] == [
               "inspect_media"
             ]
    end

    for step_id <- ~w(
          poster_frame_webp
          poster_frame_avif
          thumbnail_frame_webp
          thumbnail_frame_avif
        ) do
      step = Enum.find(definition["steps"], &(&1["id"] == step_id))
      assert step["depends_on"] == ["inspect_media"]
      refute Map.has_key?(step["params"], "source_step_id")
    end

    refute Enum.any?(definition["steps"], &(&1["type"] == "media.transcode_waveform"))

    for {step_id, size} <- [
          {"video_h264_sd", "sd"},
          {"video_h264_hd", "hd"},
          {"video_h264_fhd", "fhd"}
        ] do
      step = Map.fetch!(h264_steps, step_id)
      assert step["depends_on"] == ["inspect_media"]
      assert step["params"]["sizes"] == [size]
    end

    for {step_id, size} <- [
          {"video_h264_qhd", "qhd"},
          {"video_h264_uhd", "uhd"}
        ] do
      step = Map.fetch!(h264_steps, step_id)
      assert step["depends_on"] == ["inspect_media", "manifest"]
      assert step["params"]["sizes"] == [size]
    end

    assert h264_steps["video_h264_qhd"]["lane"] == "background"
    assert h264_steps["video_h264_qhd"]["required"] == false
    assert h264_steps["video_h264_qhd"]["params"]["require_source_resolution"] == true
    assert h264_steps["video_h264_uhd"]["lane"] == "background"
    assert h264_steps["video_h264_uhd"]["required"] == false
    assert h264_steps["video_h264_uhd"]["params"]["require_source_resolution"] == true

    clip_steps = Enum.filter(definition["steps"], &String.starts_with?(&1["id"], "clip_"))
    actual_clip_steps = Enum.reject(clip_steps, &String.ends_with?(&1["id"], "_keyframes"))

    assert Enum.all?(clip_steps, fn step ->
             source_step_id = "video_h264_#{step["params"]["size"]}"

             step["depends_on"] == ["inspect_media", source_step_id] and
               not Map.has_key?(step["params"], "source_step_id")
           end)

    assert Enum.all?(clip_steps, &(&1["lane"] == "background"))
    assert Enum.all?(clip_steps, &(&1["required"] == false))
    assert Enum.all?(clip_steps, &(&1["params"]["conditional_size"] == true))
    assert length(actual_clip_steps) == 10

    assert Enum.all?(actual_clip_steps, fn step ->
             step["params"]["codec"] in ["hevc", "av1"] and
               step["params"]["keyframe_interval"] == 250
           end)

    segments = Enum.find(definition["steps"], &(&1["id"] == "segments"))
    storyboard = Enum.find(definition["steps"], &(&1["id"] == "storyboard"))

    assert segments["depends_on"] == ["video_h264_sd"]
    assert storyboard["depends_on"] == ["inspect_media", "video_h264_sd"]
    assert storyboard["params"]["count"] == 60

    assert hls_h264_hd["lane"] == "fast"
    assert hls_h264_hd["required"] == false
    assert hls_h264_fhd["lane"] == "fast"
    assert hls_h264_fhd["required"] == false
    assert hls_h264_hd["depends_on"] == ["video_h264_hd"]
    assert hls_h264_hd["params"]["source_step_id"] == "video_h264_hd"
    assert hls_h264_fhd["depends_on"] == ["video_h264_fhd"]
    assert hls_h264_fhd["params"]["source_step_id"] == "video_h264_fhd"
    assert hls_h264_qhd["depends_on"] == ["video_h264_qhd"]
    assert hls_h264_qhd["params"]["source_step_id"] == "video_h264_qhd"
    assert hls_h264_uhd["depends_on"] == ["video_h264_uhd"]
    assert hls_h264_uhd["params"]["source_step_id"] == "video_h264_uhd"
    assert hls_audio_default["lane"] == "fast"
    assert translate_subtitles["depends_on"] == ["transcribe_audio"]
    assert translate_subtitles["lane"] == "background"
    assert translate_subtitles["required"] == false

    assert hls_master_sd["depends_on"] == ["hls_h264_sd", "hls_audio_default"]
    assert hls_master_hd["depends_on"] == ["hls_master_sd", "hls_h264_hd"]
    assert hls_master["depends_on"] == ["hls_master_hd", "hls_h264_fhd"]

    assert hls_master_metadata["depends_on"] == [
             "hls_master",
             "inspect_media",
             "transcribe_audio",
             "translate_subtitles"
           ]

    assert hls_master_qhd["lane"] == "background"
    assert hls_master_qhd["required"] == false
    assert hls_master_qhd["depends_on"] == ["hls_master_metadata", "hls_h264_qhd"]

    assert hls_master_high["lane"] == "background"
    assert hls_master_high["required"] == false
    assert hls_master_high["depends_on"] == ["hls_master_qhd", "hls_h264_uhd"]

    assert Enum.find(definition["steps"], &(&1["id"] == "poster_frame"))["required"] == false
    assert Enum.find(definition["steps"], &(&1["id"] == "notify_webhook"))["required"] == false

    inspect_media = Enum.find(definition["steps"], &(&1["id"] == "inspect_media"))
    upload_original = Enum.find(definition["steps"], &(&1["id"] == "upload_original"))

    assert inspect_media["depends_on"] == ["ensure_bucket"]
    assert inspect_media["lane"] == "fast"
    assert upload_original["depends_on"] == ["ensure_bucket"]
    refute Map.has_key?(upload_original, "starts_after")

    assert manifest_step["depends_on"] == [
             "inspect_media",
             "upload_original",
             "transcode_audio",
             "transcribe_audio",
             "translate_subtitles",
             "poster_frame",
             "thumbnail_frame",
             "placeholder_frame",
             "video_h264_sd",
             "video_h264_hd",
             "video_h264_fhd",
             "hls_master_metadata"
           ]

    refute Enum.any?(
             manifest_step["depends_on"],
             &(&1 in [
                 "video_h264_qhd",
                 "video_h264_uhd",
                 "clip_h264_sd_keyframes",
                 "clip_hevc_qhd",
                 "clip_hevc_uhd",
                 "clip_av1_qhd",
                 "clip_av1_uhd",
                 "poster_frame_webp",
                 "thumbnail_frame_avif",
                 "hls_master_qhd",
                 "hls_master_high",
                 "segments",
                 "storyboard"
               ])
           )
  end

  test "publish_default refreshes the master with QHD before UHD finishes" do
    assert {:ok, _installed} = Flow.install_preset("publish_default")

    {:ok, run} =
      Flow.start_run(
        "publish_default",
        %{
          "space_hash" => "qhd-master-space",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    mark_step!(run.id, "hls_master_metadata", %{
      status: "succeeded",
      output: %{
        "status" => "ok",
        "step_type" => "media.build_hls_master",
        "variants" => [
          %{
            "size" => "fhd",
            "codec" => "h264",
            "playlist_path" => "h264_fhd_hls/playlist.m3u8"
          }
        ]
      },
      completed_at: now
    })

    mark_step!(run.id, "hls_h264_qhd", %{
      status: "succeeded",
      output: %{
        "status" => "ok",
        "step_type" => "media.package_hls_variant",
        "size" => "qhd",
        "codec" => "h264",
        "playlist_path" => "h264_qhd_hls/playlist.m3u8"
      },
      completed_at: now
    })

    mark_step!(run.id, "hls_h264_uhd", %{
      status: "executing",
      started_at: now,
      execution_metadata: %{"queue" => "flow_booster_background"}
    })

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)
    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    assert Repo.get_by!(StepRun,
             flow_run_id: run.id,
             step_id: "hls_master_qhd"
           ).status == "scheduled"

    assert Repo.get_by!(StepRun,
             flow_run_id: run.id,
             step_id: "hls_master_high"
           ).status == "queued"

    assert {:ok, output} =
             Flow.execute_step(run.id, "hls_master_qhd", enqueue_coordinator: false)

    assert {:ok, playlist} =
             FlowStorageAdapterStub.get(output["bucket"], output["key"], nil)

    assert playlist =~ "h264_fhd_hls/playlist.m3u8"
    assert playlist =~ "h264_qhd_hls/playlist.m3u8"
  end

  @tag :audio_pipeline
  test "publish_local installs as a distinct lighter preset" do
    assert {:ok, installed} = Flow.install_preset("publish_local")
    assert installed.version_created

    assert {:ok, %{"definition" => definition}} = Presets.fetch("publish_local")

    step_ids = Enum.map(definition["steps"], & &1["id"])
    manifest_step = Enum.find(definition["steps"], &(&1["id"] == "manifest"))

    assert "clip_hevc_sd" not in step_ids
    assert "clip_av1_sd" not in step_ids
    assert "video_h264_ladder" in step_ids
    assert "clip_h264_sd_keyframes" in step_ids
    assert "poster_frame_webp" in step_ids
    assert "poster_frame_avif" in step_ids
    assert "thumbnail_frame_webp" in step_ids
    assert "thumbnail_frame_avif" in step_ids
    assert "translate_subtitles" in step_ids
    assert Enum.find(definition["steps"], &(&1["id"] == "transcode_audio"))["lane"] == "fast"
    video_h264_ladder = Enum.find(definition["steps"], &(&1["id"] == "video_h264_ladder"))

    clip_h264_sd =
      Enum.find(definition["steps"], &(&1["id"] == "clip_h264_sd_keyframes"))

    assert video_h264_ladder["lane"] == "fast"
    assert clip_h264_sd["depends_on"] == ["inspect_media", "video_h264_ladder"]
    assert clip_h264_sd["params"]["source_step_id"] == "video_h264_ladder"

    refute Map.has_key?(video_h264_ladder["params"], "prepackage_frames")

    for step_id <- ["poster_frame", "thumbnail_frame", "placeholder_frame"] do
      assert Enum.find(definition["steps"], &(&1["id"] == step_id))["depends_on"] == [
               "inspect_media"
             ]
    end

    for step_id <- ~w(
          poster_frame_webp
          poster_frame_avif
          thumbnail_frame_webp
          thumbnail_frame_avif
        ) do
      step = Enum.find(definition["steps"], &(&1["id"] == step_id))
      assert step["depends_on"] == ["inspect_media"]
      refute Map.has_key?(step["params"], "source_step_id")
    end

    refute Enum.any?(definition["steps"], &(&1["type"] == "media.transcode_waveform"))

    storyboard = Enum.find(definition["steps"], &(&1["id"] == "storyboard"))
    assert storyboard["depends_on"] == ["inspect_media", "video_h264_ladder"]
    assert storyboard["params"]["count"] == 60

    assert Enum.find(definition["steps"], &(&1["id"] == "hls_h264_hd"))["lane"] == "fast"
    assert Enum.find(definition["steps"], &(&1["id"] == "hls_audio_default"))["lane"] == "fast"
    assert Enum.find(definition["steps"], &(&1["id"] == "poster_frame"))["required"] == false

    inspect_media = Enum.find(definition["steps"], &(&1["id"] == "inspect_media"))
    upload_original = Enum.find(definition["steps"], &(&1["id"] == "upload_original"))

    assert inspect_media["depends_on"] == ["ensure_bucket"]
    assert inspect_media["lane"] == "fast"
    assert upload_original["depends_on"] == ["ensure_bucket"]
    refute Map.has_key?(upload_original, "starts_after")

    refute Enum.any?(manifest_step["depends_on"], &(&1 in ["clip_hevc_sd", "clip_av1_sd"]))

    assert manifest_step["depends_on"] == [
             "inspect_media",
             "upload_original",
             "transcode_audio",
             "transcribe_audio",
             "translate_subtitles",
             "poster_frame",
             "thumbnail_frame",
             "placeholder_frame",
             "video_h264_ladder",
             "hls_master_metadata"
           ]
  end

  @tag :audio_pipeline
  test "start_run auto-syncs changed built-in presets into a new active version" do
    assert {:ok, first_install} = Flow.install_preset("publish_local")
    assert first_install.version.version == 1

    assert {:ok, %{"definition" => definition}} = Presets.fetch("publish_local")

    override_definition =
      Map.update!(definition, "steps", fn steps ->
        steps ++
          [
            %{
              "id" => "post_sync_notify",
              "type" => "event.notify_webhook",
              "name" => "Post Sync Notify",
              "depends_on" => ["manifest"],
              "required" => false
            }
          ]
      end)

    Application.put_env(:mave_core, :flow_preset_overrides, %{
      "publish_local" => %{"definition" => override_definition}
    })

    assert {:ok, run} =
             Flow.start_run(
               "publish_local",
               %{
                 "space_hash" => "ubg50",
                 "embed_hash" => "LeDE9v86ye",
                 "input_url" => "https://example.com/video.mp4"
               },
               enqueue: false
             )

    assert run.flow_version.version == 2
    assert Enum.any?(run.flow_version.definition["steps"], &(&1["id"] == "post_sync_notify"))

    version_count =
      Repo.aggregate(
        from(version in Version, where: version.flow_template_id == ^first_install.template.id),
        :count
      )

    active_versions =
      Repo.all(
        from(version in Version,
          where:
            version.flow_template_id == ^first_install.template.id and version.status == "active",
          select: version.version
        )
      )

    assert version_count == 2
    assert active_versions == [2]
  end

  @tag :audio_pipeline
  test "run_inline executes a full preset flow end-to-end" do
    assert {:ok, _installed} = Flow.install_preset("publish_default")

    assert {:ok, run} =
             Flow.run_inline(
               "publish_default",
               %{
                 "space_hash" => "ubg50",
                 "embed_hash" => "LeDE9v86ye",
                 "input_url" => "https://example.com/video.mp4",
                 "source_body" => "stub-media-body",
                 "source_content_type" => "video/mp4",
                 "media_package_hls_variant_strict" => false,
                 "media_package_hls_audio_strict" => false,
                 "media_probe" => %{
                   "duration" => 10.0,
                   "size_bytes" => 15,
                   "filetype" => "mp4",
                   "aspect_ratio" => "16 / 9",
                   "streams" => []
                 }
               }
             )

    assert run.status == "succeeded"

    manifest_artifact =
      Repo.get_by!(ArtifactRef,
        flow_run_id: run.id,
        producer_step_id: "manifest",
        name: "manifest"
      )

    assert manifest_artifact.uri == "s3://space-ubg50/LeDE9v86ye/manifest.json"
    assert manifest_artifact.size_bytes > 0

    manifest_step_run = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "manifest")
    assert is_binary(get_in(manifest_step_run.output, ["checksum"]))

    original_artifact =
      Repo.get_by!(ArtifactRef,
        flow_run_id: run.id,
        producer_step_id: "upload_original",
        name: "original"
      )

    assert original_artifact.uri == "s3://space-ubg50/LeDE9v86ye/original"
  end

  test "run_inline emits subtitle artifact when transcription input is provided" do
    assert {:ok, _installed} = Flow.install_preset("publish_default")

    assert {:ok, run} =
             Flow.run_inline(
               "publish_default",
               %{
                 "space_hash" => "ubg50",
                 "embed_hash" => "LeDE9v86ye",
                 "input_url" => "https://example.com/video.mp4",
                 "source_body" => "stub-media-body",
                 "source_content_type" => "video/mp4",
                 "media_package_hls_variant_strict" => false,
                 "media_package_hls_audio_strict" => false,
                 "media_probe" => %{
                   "duration" => 10.0,
                   "size_bytes" => 15,
                   "filetype" => "mp4",
                   "aspect_ratio" => "16 / 9",
                   "streams" => []
                 },
                 "transcription_text" => "Hello world from flow test"
               }
             )

    assert run.status == "succeeded"

    subtitle_artifact =
      Repo.get_by!(ArtifactRef,
        flow_run_id: run.id,
        producer_step_id: "transcribe_audio",
        name: "subtitle_en"
      )

    assert subtitle_artifact.media_type == "text/vtt"
    assert subtitle_artifact.uri == "s3://space-ubg50/LeDE9v86ye/subtitle_en.vtt"
    assert subtitle_artifact.size_bytes > 0

    transcribe_step = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "transcribe_audio")
    assert transcribe_step.status == "succeeded"
    assert get_in(transcribe_step.output, ["status"]) == "ok"
    assert get_in(transcribe_step.output, ["subtitle", "language"]) == "en"
  end

  test "run_inline projects inspect metadata and finished renditions onto the current video" do
    assert {:ok, _installed} = Flow.install_preset("publish_local")

    space =
      space_fixture()
      |> Ecto.Changeset.change(%{region: "eu"})
      |> Repo.update!()

    {:ok, embed} = Embeds.create_video_embed(space, %{name: "Projected Upload"})

    {:ok, embed} =
      Embeds.begin_video_upload(space.hash, embed.hash, %{
        "title" => "Projected Upload.mp4",
        "source_url" => "https://example.com/projected.mp4",
        "upload_size" => 654_321
      })

    custom_thumbnail_key = "#{embed.hash}/custom_thumbnail.jpg"

    public_thumbnail_key = "#{embed.hash}/thumbnail.jpg"

    assert Embeds.current_video_version(embed) == 0

    bucket = "space-#{space.hash}"

    assert {:ok, _body} =
             FlowStorageAdapterStub.put_public(
               bucket,
               custom_thumbnail_key,
               "selected-custom-thumbnail",
               "image/jpeg",
               space.region
             )

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all("renditions", [
      %{
        id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
        video_id: MaveCore.LegacyShortUUID.dump!(embed.asset.current_video_id),
        rendition_key: public_thumbnail_key,
        type: "custom_thumbnail",
        codec: nil,
        container: "jpg",
        size: nil,
        progress: 100.0,
        file_size: byte_size("selected-custom-thumbnail"),
        inserted_at: now,
        updated_at: now
      }
    ])

    assert {:ok, embed} =
             Embeds.update_settings(embed, %{
               poster: :upload,
               external_poster:
                 SettingsSerializer.storage_object_url(bucket, public_thumbnail_key)
             })

    {:ok, run} =
      Flow.run_inline(
        "publish_local",
        %{
          "space_hash" => space.hash,
          "embed_hash" => embed.hash,
          "region" => space.region,
          "input_url" => "https://example.com/projected.mp4",
          "source_url" => "https://example.com/projected.mp4",
          "source_body" => "stub-media-body",
          "source_content_type" => "video/mp4",
          "media_package_hls_variant_strict" => false,
          "media_package_hls_audio_strict" => false,
          "media_build_hls_master_strict" => false,
          "transcription_text" => "Hello world from projected upload",
          "media_probe" => %{
            "duration" => 12.5,
            "size_bytes" => 654_321,
            "aspect_ratio" => "16 / 9",
            "width" => 1920,
            "height" => 1080,
            "streams" => [
              %{
                "codec_type" => "video",
                "avg_frame_rate" => "30000/1001",
                "bit_rate" => "4200000"
              },
              %{
                "codec_type" => "audio",
                "bit_rate" => "128000"
              }
            ]
          }
        }
      )

    assert run.status == "succeeded"

    embed = Repo.get!(Embed, embed.id) |> Repo.preload([:settings, asset: [:current_video]])
    video = embed.asset.current_video
    assert video.status == "ready"
    assert video.language == "en"

    assert embed.settings.external_poster ==
             SettingsSerializer.storage_object_url(bucket, public_thumbnail_key)

    renditions =
      from(r in "renditions",
        where: r.video_id == type(^video.id, MaveCore.Ecto.LegacyShortUUID),
        select: {r.type, r.rendition_key}
      )
      |> Repo.all()

    assert Enum.any?(renditions, fn {type, key} ->
             type == "video" and String.ends_with?(key, "h264_sd.mp4")
           end)

    assert Enum.any?(renditions, fn {type, key} ->
             type == "video" and String.ends_with?(key, "h264_hd.mp4")
           end)

    assert Enum.any?(renditions, fn {type, key} ->
             type == "poster" and String.ends_with?(key, "poster.jpg")
           end)

    assert Enum.any?(renditions, fn {type, key} ->
             type == "poster" and String.ends_with?(key, "poster.webp")
           end)

    assert Enum.any?(renditions, fn {type, key} ->
             type == "poster" and String.ends_with?(key, "poster.avif")
           end)

    assert Enum.any?(renditions, fn {type, key} ->
             type == "thumbnail" and String.ends_with?(key, "thumbnail.webp")
           end)

    assert Enum.any?(renditions, fn {type, key} ->
             type == "thumbnail" and String.ends_with?(key, "thumbnail.avif")
           end)

    assert {"custom_thumbnail", public_thumbnail_key} in renditions

    assert Embeds.current_video_version(embed) == 0

    assert {:ok, "selected-custom-thumbnail"} =
             FlowStorageAdapterStub.get(bucket, custom_thumbnail_key, space.region)

    assert {:ok, "selected-custom-thumbnail"} =
             FlowStorageAdapterStub.get(
               bucket,
               "#{embed.hash}/thumbnail.jpg",
               space.region
             )

    assert Enum.any?(renditions, fn {type, key} ->
             type == "placeholder" and String.ends_with?(key, "placeholder.jpg")
           end)

    assert Enum.any?(renditions, fn {type, key} ->
             type == "storyboard" and String.ends_with?(key, "storyboard.jpg")
           end)

    audio_tracks =
      AudioTrack
      |> where([track], track.video_id == ^video.id)
      |> order_by([track], asc: track.inserted_at)
      |> Repo.all()

    assert [%AudioTrack{} = audio_track] = audio_tracks
    assert audio_track.codec == "mp3"
    assert audio_track.filename == "audio.mp3"
    assert audio_track.default == true
    assert audio_track.language == "en"

    subtitles =
      Subtitle
      |> where([subtitle], subtitle.video_id == ^video.id)
      |> order_by([subtitle], asc: subtitle.inserted_at)
      |> Repo.all()

    assert [%Subtitle{} = subtitle] = subtitles
    assert subtitle.language == "en"
    assert subtitle.path == "#{embed.hash}/subtitle_en.vtt"
  end

  test "rapid replacement runs finalize their own videos without republishing stale aliases" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "run-specific-video-#{System.unique_integer([:positive])}",
        "name" => "Run Specific Video"
      })

    {:ok, _version} =
      Flow.create_version(template.id, %{
        "definition" => %{
          "steps" => [
            %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"},
            %{
              "id" => "upload_original",
              "type" => "asset.upload_original",
              "name" => "Upload Original",
              "depends_on" => ["source"]
            }
          ]
        }
      })

    space = space_fixture()
    {:ok, embed} = Embeds.create_video_embed(space, %{name: "Rapid Replacements"})

    {:ok, first_embed} =
      Embeds.begin_video_upload(space.hash, embed.hash, %{
        "title" => "First.mp4",
        "source_url" => "https://upload.example/first.mp4"
      })

    first_video = first_embed.asset.current_video
    first_upload_key = "#{space.hash}/first.mp4"
    first_rendition_key = "#{embed.hash}/v0/h264_sd.mp4"

    {:ok, first_run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => space.hash,
          "embed_hash" => embed.hash,
          "version" => 0,
          "source_url" => "https://upload.example/first.mp4",
          "source_content_type" => "video/mp4",
          "upload_bucket" => "mave-upload",
          "upload_key" => first_upload_key,
          "source_region" => "upload-region",
          "region" => space.region
        },
        enqueue: false
      )

    assert first_run.input["video_id"] == first_video.id

    first_run
    |> Run.changeset(%{input: Map.delete(first_run.input, "video_id")})
    |> Repo.update!()

    {:ok, second_embed} =
      Embeds.begin_video_upload(space.hash, embed.hash, %{
        "title" => "Second.mp4",
        "source_url" => "https://upload.example/second.mp4"
      })

    second_video = second_embed.asset.current_video
    second_upload_key = "#{space.hash}/second.mp4"
    second_rendition_key = "#{embed.hash}/v1/h264_sd.mp4"

    {:ok, second_run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => space.hash,
          "embed_hash" => embed.hash,
          "version" => 1,
          "source_url" => "https://upload.example/second.mp4",
          "source_content_type" => "video/mp4",
          "upload_bucket" => "mave-upload",
          "upload_key" => second_upload_key,
          "source_region" => "upload-region",
          "region" => space.region
        },
        enqueue: false
      )

    assert second_run.input["video_id"] == second_video.id

    assert {:ok, _body} =
             FlowStorageAdapterStub.put_public(
               "mave-upload",
               first_upload_key,
               "first source",
               "video/mp4",
               "upload-region"
             )

    assert {:ok, _body} =
             FlowStorageAdapterStub.put_public(
               "mave-upload",
               second_upload_key,
               "second source",
               "video/mp4",
               "upload-region"
             )

    %Rendition{}
    |> Rendition.changeset(%{
      video_id: first_video.id,
      rendition_key: first_rendition_key,
      type: :video,
      codec: :h264,
      container: :mp4,
      size: :sd,
      progress: 100.0,
      file_size: 111
    })
    |> Repo.insert!()

    mark_step!(first_run.id, "source", %{
      status: "succeeded",
      output: %{
        "status" => "ok",
        "renditions" => [rendition_output(first_rendition_key, 111)]
      }
    })

    mark_step!(first_run.id, "upload_original", %{
      status: "succeeded",
      output: durable_original_output(space, embed.hash, 0)
    })

    assert {:ok, %Run{status: "succeeded"}} =
             Flow.reconcile_run(first_run.id, enqueue_jobs: false)

    assert Repo.get_by!(Rendition, rendition_key: first_rendition_key).video_id ==
             first_video.id

    assert Repo.get!(Video, first_video.id).status == "ready"
    refute Repo.get!(Video, second_video.id).status == "ready"

    first_run = Repo.get!(Run, first_run.id)
    assert first_run.input["durable_source_promoted"] == true
    assert first_run.input["source_key"] == "#{embed.hash}/v0/original"

    refute FlowStorageAdapterStub.public?(
             "mave-upload",
             first_upload_key,
             "upload-region"
           )

    assert {:error, :not_found} =
             FlowStorageAdapterStub.get(
               "space-#{space.hash}",
               "#{embed.hash}/manifest.json",
               space.region
             )

    mark_step!(second_run.id, "source", %{
      status: "succeeded",
      output: %{
        "status" => "ok",
        "renditions" => [rendition_output(second_rendition_key, 222)]
      }
    })

    mark_step!(second_run.id, "upload_original", %{
      status: "succeeded",
      output: durable_original_output(space, embed.hash, 1)
    })

    assert {:ok, %Run{status: "succeeded"}} =
             Flow.reconcile_run(second_run.id, enqueue_jobs: false)

    assert Repo.get_by!(Rendition, rendition_key: first_rendition_key).video_id ==
             first_video.id

    assert Repo.get_by!(Rendition, rendition_key: second_rendition_key).video_id ==
             second_video.id

    assert Repo.get!(Video, second_video.id).status == "ready"

    assert {:ok, manifest_json} =
             FlowStorageAdapterStub.get(
               "space-#{space.hash}",
               "#{embed.hash}/manifest.json",
               space.region
             )

    manifest = Jason.decode!(manifest_json)
    assert get_in(manifest, ["video", "original"]) == nil
    assert get_in(manifest, ["video", "src"]) == nil
  end

  for preset <- ~w(publish_local publish_default), artwork? <- [false, true] do
    @tag preset: preset, artwork?: artwork?, audio_pipeline: true
    test "#{preset} accepts audio-only uploads (artwork: #{artwork?}) and skips video-only work",
         %{preset: preset, artwork?: artwork?} do
      assert {:ok, _installed} = Flow.install_preset(preset)

      space = space_fixture()
      {:ok, embed} = Embeds.create_video_embed(space, %{name: "Audio Upload"})

      {:ok, embed} =
        Embeds.begin_video_upload(space.hash, embed.hash, %{
          "title" => "Audio Upload.m4a",
          "source_url" => "https://example.com/audio.m4a",
          "upload_size" => 123_456,
          "content_type" => "audio/mp4"
        })

      artwork =
        if artwork? do
          [
            %{
              "codec_type" => "video",
              "codec_name" => "mjpeg",
              "width" => 600,
              "height" => 600,
              "avg_frame_rate" => "0/0",
              "r_frame_rate" => "90000/1",
              "disposition" => %{"attached_pic" => 1}
            }
          ]
        else
          []
        end

      {:ok, run} =
        Flow.run_inline(
          preset,
          %{
            "space_hash" => space.hash,
            "embed_hash" => embed.hash,
            "input_url" => "https://example.com/audio.m4a",
            "source_url" => "https://example.com/audio.m4a",
            "source_body" => "stub-audio-body",
            "source_content_type" => "audio/mp4",
            "region" => space.region,
            "media_package_hls_audio_strict" => false,
            "media_package_hls_variant_strict" => false,
            "transcription_text" => "Hello from an audio upload",
            "media_probe" => %{
              "duration" => 42.25,
              "size_bytes" => 123_456,
              "filetype" => "m4a",
              "format" => %{"format_name" => "mov,mp4,m4a,3gp,3g2,mj2"},
              "streams" =>
                [
                  %{
                    "codec_type" => "audio",
                    "codec_name" => "aac",
                    "bit_rate" => "128000"
                  }
                ] ++ artwork
            }
          }
        )

      assert run.status == "succeeded"

      video_step_id = if preset == "publish_local", do: "video_h264_ladder", else: "video_h264_sd"
      video_h264_ladder = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: video_step_id)
      assert video_h264_ladder.status == "succeeded"
      assert video_h264_ladder.output["status"] == "skipped"
      assert video_h264_ladder.output["reason"] == "no video stream"

      hls_h264_sd = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "hls_h264_sd")
      assert hls_h264_sd.status == "succeeded"
      assert hls_h264_sd.output["status"] == "skipped"

      segments = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "segments")
      assert segments.status == "succeeded"
      assert segments.output["status"] == "skipped"
      assert segments.output["reason"] == "no video stream"

      storyboard = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "storyboard")
      assert storyboard.status == "succeeded"
      assert storyboard.output["status"] == "skipped"
      assert storyboard.output["reason"] == "no video stream"

      embed = Repo.get!(Embed, embed.id) |> Repo.preload(asset: [current_video: [:audio_tracks]])
      video = embed.asset.current_video
      assert video.status == "ready"
      assert video.file_name == "Audio Upload.m4a"
      assert video.duration == 42.25
      assert video.original_file_size == 123_456
      assert video.max_width == nil
      assert video.max_height == nil
      assert video.max_frame_rate == nil

      assert [%{filename: "audio.mp3", codec: "mp3", default: true}] = video.audio_tracks

      renditions =
        from(r in "renditions",
          where: r.video_id == type(^video.id, MaveCore.Ecto.LegacyShortUUID),
          select: {r.type, r.rendition_key}
        )
        |> Repo.all()

      refute Enum.any?(renditions, fn {type, _key} ->
               type in [
                 "video",
                 "clip_keyframes",
                 "placeholder",
                 "segments",
                 "storyboard"
               ]
             end)

      assert Enum.any?(renditions, fn {type, key} ->
               type == "audio" and String.ends_with?(key, "audio.mp3")
             end)

      refute Enum.any?(renditions, fn {type, _key} -> type in ["poster", "thumbnail"] end)
      refute Repo.get_by(StepRun, flow_run_id: run.id, step_id: "transcode_waveform")

      assert {:ok, manifest_json} =
               FlowStorageAdapterStub.get(
                 "space-#{space.hash}",
                 "#{embed.hash}/manifest.json",
                 space.region
               )

      manifest = Jason.decode!(manifest_json)
      assert manifest["video"]["renditions"] == []
      assert [%{"filename" => "audio.mp3"}] = manifest["audio_tracks"]

      assert {:ok, player_html} =
               FlowStorageAdapterStub.get(
                 "space-#{space.hash}",
                 "#{embed.hash}/player.html",
                 space.region
               )

      assert player_html =~ "<mave-audio "
      refute player_html =~ "<mave-player "
    end
  end

  @tag :audio_playback
  @tag :audio_pipeline
  test "audio uploads publish playable audio and real peaks without generated video" do
    old_direct_input = Application.get_env(:mave_core, :flow_direct_storage_ffmpeg_input)
    Application.put_env(:mave_core, :flow_direct_storage_ffmpeg_input, false)
    on_exit(fn -> restore_env(:flow_direct_storage_ffmpeg_input, old_direct_input) end)

    if ffmpeg_bin = System.find_executable("ffmpeg") do
      StepSupport.with_temp_dir("audio_playback_flow", fn tmp_dir ->
        audio_path = Path.join(tmp_dir, "audio.mp3")

        {_log, 0} =
          System.cmd(
            ffmpeg_bin,
            [
              "-v",
              "error",
              "-f",
              "lavfi",
              "-i",
              "sine=frequency=440:duration=2",
              audio_path
            ],
            stderr_to_stdout: true
          )

        audio_body = File.read!(audio_path)

        assert {:ok, _installed} = Flow.install_preset("publish_local")
        space = space_fixture()

        {:ok, _} =
          FlowStorageAdapterStub.put(
            "mave-upload",
            "audio.mp3",
            audio_body,
            "audio/mpeg",
            space.region
          )

        {:ok, embed} = Embeds.create_video_embed(space, %{name: "Waveform Playback"})

        {:ok, embed} =
          Embeds.begin_video_upload(space.hash, embed.hash, %{
            "title" => "audio.mp3",
            "source_url" => "https://example.com/audio.mp3",
            "upload_size" => byte_size(audio_body),
            "content_type" => "audio/mpeg"
          })

        assert {:ok, run} =
                 Flow.run_inline("publish_local", %{
                   "space_hash" => space.hash,
                   "embed_hash" => embed.hash,
                   "source_url" => "https://example.com/audio.mp3",
                   "source_bucket" => "mave-upload",
                   "source_key" => "audio.mp3",
                   "source_region" => space.region,
                   "source_content_type" => "audio/mpeg",
                   "region" => space.region,
                   "media_transcode_audio_mode" => "ffmpeg",
                   "media_extract_frame_mode" => "ffmpeg",
                   "transcription_text" => "Audio playback test",
                   "media_probe" => %{
                     "duration" => 2.0,
                     "size_bytes" => byte_size(audio_body),
                     "filetype" => "mp3",
                     "streams" => [%{"codec_type" => "audio", "codec_name" => "mp3"}]
                   }
                 })

        assert run.status == "succeeded"

        assert {:ok, json} =
                 FlowStorageAdapterStub.get(
                   "space-#{space.hash}",
                   "#{embed.hash}/manifest.json",
                   space.region
                 )

        manifest = Jason.decode!(json)
        assert manifest["video"]["ready"]
        assert manifest["video"]["audio"]
        assert manifest["video"]["renditions"] == []
        assert manifest["poster"]["renditions"] == []
        assert [%{"filename" => "audio.mp3"}] = manifest["audio_tracks"]

        assert %{"version" => 1, "audio_track" => "audio.mp3", "peaks" => peaks} =
                 manifest["waveform"]

        assert length(peaks) in 510..512
        assert Enum.any?(peaks, &(&1 > 0))
        refute Repo.get_by(StepRun, flow_run_id: run.id, step_id: "transcode_waveform")
        refute Repo.get_by(StepRun, flow_run_id: run.id, step_id: "hls_waveform_sd")

        assert {:ok, encoded_audio} =
                 FlowStorageAdapterStub.get(
                   "space-#{space.hash}",
                   "#{embed.hash}/audio.mp3",
                   space.region
                 )

        encoded_path = Path.join(tmp_dir, "encoded.mp3")
        File.write!(encoded_path, encoded_audio)

        {_decoded, 0} =
          System.cmd(
            ffmpeg_bin,
            ["-v", "error", "-i", encoded_path, "-map", "0:a:0", "-f", "null", "-"],
            stderr_to_stdout: true
          )
      end)
    end
  end

  test "upload_original publishes an intermediate manifest with an original source" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "intermediate-manifest-#{System.unique_integer([:positive])}",
        "name" => "Intermediate Manifest"
      })

    {:ok, _version} =
      Flow.create_version(template.id, %{
        "definition" => %{
          "steps" => [
            %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"},
            %{
              "id" => "upload_original",
              "type" => "asset.upload_original",
              "name" => "Upload Original",
              "depends_on" => ["source"]
            }
          ]
        }
      })

    space = space_fixture()
    {:ok, embed} = Embeds.create_video_embed(space, %{name: "Intermediate Manifest Upload"})
    upload_id = Ecto.UUID.generate()
    UploadEvents.subscribe(upload_id)

    {:ok, _embed} =
      Embeds.begin_video_upload(space.hash, embed.hash, %{
        "title" => "Intermediate Manifest Upload.mp4",
        "source_url" => "https://example.com/intermediate.mp4",
        "upload_size" => 654_321
      })

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => space.hash,
          "embed_hash" => embed.hash,
          "input_url" => "https://example.com/intermediate.mp4",
          "source_url" => "https://example.com/intermediate.mp4",
          "source_body" => "stub-media-body",
          "source_content_type" => "video/mp4",
          "upload_id" => upload_id
        },
        enqueue: false
      )

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)
    assert {:ok, _source_output} = Flow.execute_step(run.id, "source", enqueue_coordinator: false)
    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)
    refute_receive {:completed, _payload}, 0

    assert {:ok, upload_original_output} =
             Flow.execute_step(run.id, "upload_original", enqueue_coordinator: false)

    assert upload_original_output["original_key"] == "#{embed.hash}/original"

    assert {:ok, manifest_json} =
             FlowStorageAdapterStub.get(
               "space-#{space.hash}",
               "#{embed.hash}/manifest.json",
               space.region
             )

    manifest = Jason.decode!(manifest_json)

    assert get_in(manifest, ["video", "original"]) ==
             SettingsSerializer.storage_object_url(
               "space-#{space.hash}",
               "#{embed.hash}/original"
             )

    assert get_in(manifest, ["video", "status"]) == "playable"
    assert get_in(manifest, ["video", "ready"]) == true

    refreshed_embed = Repo.get!(Embed, embed.id) |> Repo.preload(asset: [:current_video])
    assert refreshed_embed.asset.current_video.status == "playable"

    assert {:ok, player_html} =
             FlowStorageAdapterStub.get(
               "space-#{space.hash}",
               "#{embed.hash}/player.html",
               space.region
             )

    assert player_html =~ "<mave-player"

    upload_original_step =
      Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "upload_original")

    assert get_in(upload_original_step.execution_metadata, ["processing_player", "ready"]) ==
             true

    assert Embeds.processing_player_ready?(space.hash, embed.hash)

    assert_receive {:completed, %{embed: completed_embed}}
    assert completed_embed == "#{space.hash}#{embed.hash}"
  end

  test "processing player stays hidden when manifest publication fails" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "failed-processing-manifest-#{System.unique_integer([:positive])}",
        "name" => "Failed Processing Manifest"
      })

    {:ok, _version} =
      Flow.create_version(template.id, %{
        "definition" => %{
          "steps" => [
            %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"},
            %{
              "id" => "upload_original",
              "type" => "asset.upload_original",
              "name" => "Upload Original",
              "depends_on" => ["source"]
            }
          ]
        }
      })

    space = space_fixture()
    {:ok, embed} = Embeds.create_video_embed(space, %{name: "Failed Processing Manifest"})
    upload_id = Ecto.UUID.generate()
    UploadEvents.subscribe(upload_id)

    {:ok, _embed} =
      Embeds.begin_video_upload(space.hash, embed.hash, %{
        "title" => "Failed Processing Manifest.mp4",
        "source_url" => "https://example.com/failed-processing-manifest.mp4",
        "upload_size" => 123_456
      })

    bucket = "space-#{space.hash}"
    manifest_key = "#{embed.hash}/manifest.json"
    FlowStorageAdapterStub.fail_public_put!(bucket, manifest_key, space.region)

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => space.hash,
          "embed_hash" => embed.hash,
          "input_url" => "https://example.com/failed-processing-manifest.mp4",
          "source_url" => "https://example.com/failed-processing-manifest.mp4",
          "source_body" => "stub-media-body",
          "source_content_type" => "video/mp4",
          "upload_id" => upload_id
        },
        enqueue: false
      )

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)
    assert {:ok, _source_output} = Flow.execute_step(run.id, "source", enqueue_coordinator: false)
    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    assert {:ok, _output} =
             Flow.execute_step(run.id, "upload_original", enqueue_coordinator: false)

    assert {:ok, _player_html} =
             FlowStorageAdapterStub.get(bucket, "#{embed.hash}/player.html", space.region)

    assert {:error, :not_found} =
             FlowStorageAdapterStub.get(bucket, manifest_key, space.region)

    upload_original_step =
      Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "upload_original")

    refute get_in(upload_original_step.execution_metadata, ["processing_player", "ready"])
    refute Embeds.processing_player_ready?(space.hash, embed.hash)
    refute_receive {:completed, _payload}, 0
  end

  test "completed upload switches playback to the durable original before becoming private" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "private-completed-upload-#{System.unique_integer([:positive])}",
        "name" => "Private Completed Upload"
      })

    {:ok, _version} =
      Flow.create_version(template.id, %{
        "definition" => %{
          "steps" => [
            %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"},
            %{
              "id" => "upload_original",
              "type" => "asset.upload_original",
              "name" => "Upload Original",
              "depends_on" => ["source"]
            }
          ]
        }
      })

    space = space_fixture()
    {:ok, embed} = Embeds.create_video_embed(space, %{name: "Private Completed Upload"})

    {:ok, _embed} =
      Embeds.begin_video_upload(space.hash, embed.hash, %{
        "title" => "Private Completed Upload.mp4",
        "source_url" => "https://storage.video-dns.com/#{space.hash}/temporary.mp4",
        "upload_size" => 15
      })

    upload_bucket = "mave-upload"
    upload_key = "#{space.hash}/temporary.mp4"
    source_region = "upload-region"

    assert {:ok, _body} =
             FlowStorageAdapterStub.put_public(
               upload_bucket,
               upload_key,
               "stub-media-body",
               "video/mp4",
               source_region
             )

    assert {:ok, run} =
             Flow.run_inline(template.slug, %{
               "space_hash" => space.hash,
               "embed_hash" => embed.hash,
               "source_url" => "https://storage.video-dns.com/#{space.hash}/temporary.mp4",
               "source_body" => "stub-media-body",
               "source_content_type" => "video/mp4",
               "upload_bucket" => upload_bucket,
               "upload_key" => upload_key,
               "source_region" => source_region,
               "region" => space.region
             })

    assert run.status == "succeeded"

    promoted_run = Repo.get!(Run, run.id)

    assert promoted_run.input["source_bucket"] == "space-#{space.hash}"
    assert promoted_run.input["source_key"] == "#{embed.hash}/original"
    assert promoted_run.input["source_region"] == space.region
    assert promoted_run.input["durable_source_promoted"] == true

    assert promoted_run.input["source_url"] ==
             "https://storage.example/space-#{space.hash}/#{embed.hash}/original"

    assert promoted_run.input["upload_bucket"] == upload_bucket
    assert promoted_run.input["upload_key"] == upload_key
    assert FlowStorageAdapterStub.public?(upload_bucket, upload_key, source_region) == false

    assert {:ok, manifest_json} =
             FlowStorageAdapterStub.get(
               "space-#{space.hash}",
               "#{embed.hash}/manifest.json",
               space.region
             )

    manifest = Jason.decode!(manifest_json)

    durable_original =
      SettingsSerializer.storage_object_url(
        "space-#{space.hash}",
        "#{embed.hash}/original"
      )

    assert get_in(manifest, ["video", "original"]) == durable_original
    assert get_in(manifest, ["video", "src"]) == durable_original

    legacy_input =
      promoted_run.input
      |> Map.merge(%{
        "source_bucket" => upload_bucket,
        "source_key" => upload_key,
        "source_region" => source_region,
        "source_url" => "https://storage.video-dns.com/#{space.hash}/temporary.mp4",
        "input_url" => "https://storage.video-dns.com/#{space.hash}/temporary.mp4",
        "upload_ffmpeg_input_url" => "https://storage.video-dns.com/#{space.hash}/temporary.mp4"
      })
      |> Map.delete("durable_source_promoted")

    promoted_run
    |> Run.changeset(%{input: legacy_input})
    |> Repo.update!()

    assert {:ok, _run} =
             Flow.retry_step(run.id, "upload_original", enqueue_jobs: false)

    recovered_run = Repo.get!(Run, run.id)
    assert recovered_run.input["source_bucket"] == "space-#{space.hash}"
    assert recovered_run.input["source_key"] == "#{embed.hash}/original"
    assert recovered_run.input["durable_source_promoted"] == true
  end

  test "completed upload stays public when the durable manifest cannot be published" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "public-failed-finalization-#{System.unique_integer([:positive])}",
        "name" => "Public Failed Finalization"
      })

    {:ok, _version} =
      Flow.create_version(template.id, %{
        "definition" => %{
          "steps" => [
            %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"},
            %{
              "id" => "upload_original",
              "type" => "asset.upload_original",
              "name" => "Upload Original",
              "depends_on" => ["source"]
            }
          ]
        }
      })

    space = space_fixture()
    {:ok, embed} = Embeds.create_video_embed(space, %{name: "Public Failed Finalization"})

    {:ok, _embed} =
      Embeds.begin_video_upload(space.hash, embed.hash, %{
        "title" => "Public Failed Finalization.mp4",
        "source_url" => "https://storage.video-dns.com/#{space.hash}/temporary.mp4",
        "upload_size" => 15
      })

    upload_bucket = "mave-upload"
    upload_key = "#{space.hash}/temporary.mp4"
    source_region = "upload-region"
    manifest_bucket = "space-#{space.hash}"
    manifest_key = "#{embed.hash}/manifest.json"

    assert {:ok, _body} =
             FlowStorageAdapterStub.put_public(
               upload_bucket,
               upload_key,
               "stub-media-body",
               "video/mp4",
               source_region
             )

    FlowStorageAdapterStub.fail_public_put!(manifest_bucket, manifest_key, space.region)

    assert {:ok, run} =
             Flow.run_inline(template.slug, %{
               "space_hash" => space.hash,
               "embed_hash" => embed.hash,
               "source_url" => "https://storage.video-dns.com/#{space.hash}/temporary.mp4",
               "source_body" => "stub-media-body",
               "source_content_type" => "video/mp4",
               "upload_bucket" => upload_bucket,
               "upload_key" => upload_key,
               "source_region" => source_region
             })

    assert run.status == "succeeded"
    assert FlowStorageAdapterStub.public?(upload_bucket, upload_key, source_region) == true

    assert {:error, :not_found} =
             FlowStorageAdapterStub.get(manifest_bucket, manifest_key, space.region)
  end

  test "media inspect publishes player and manifest from the public upload before original copy" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "upload-origin-manifest-#{System.unique_integer([:positive])}",
        "name" => "Upload Origin Manifest"
      })

    {:ok, _version} =
      Flow.create_version(template.id, %{
        "definition" => %{
          "steps" => [
            %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"},
            %{
              "id" => "inspect_media",
              "type" => "media.inspect",
              "name" => "Inspect Media",
              "depends_on" => ["source"]
            },
            %{
              "id" => "upload_original",
              "type" => "asset.upload_original",
              "name" => "Upload Original",
              "depends_on" => ["source"]
            }
          ]
        }
      })

    upload = Application.fetch_env!(:mave_core, :upload)

    source_url =
      "#{Keyword.fetch!(upload, :source_base_url)}/#{Keyword.fetch!(upload, :bucket)}/uploads/public/source.mp4"

    space = space_fixture()
    {:ok, embed} = Embeds.create_video_embed(space, %{name: "Upload Origin Manifest"})
    upload_id = Ecto.UUID.generate()
    UploadEvents.subscribe(upload_id)

    {:ok, _embed} =
      Embeds.begin_video_upload(space.hash, embed.hash, %{
        "title" => "Upload Origin Manifest.mp4",
        "source_url" => source_url,
        "upload_size" => 654_321
      })

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => space.hash,
          "embed_hash" => embed.hash,
          "source_url" => source_url,
          "upload_ffmpeg_input_url" => source_url,
          "source_content_type" => "video/mp4",
          "upload_id" => upload_id,
          "media_probe" => %{
            "duration" => 8.25,
            "size_bytes" => 654_321,
            "width" => 1280,
            "height" => 720,
            "streams" => [%{"codec_type" => "video", "width" => 1280, "height" => 720}]
          }
        },
        enqueue: false
      )

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)
    assert {:ok, _source_output} = Flow.execute_step(run.id, "source", enqueue_coordinator: false)
    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    assert {:ok, _inspect_output} =
             Flow.execute_step(run.id, "inspect_media", enqueue_coordinator: false)

    assert Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "upload_original").status in [
             "queued",
             "scheduled"
           ]

    assert {:ok, manifest_json} =
             FlowStorageAdapterStub.get(
               "space-#{space.hash}",
               "#{embed.hash}/manifest.json",
               space.region
             )

    manifest = Jason.decode!(manifest_json)
    assert get_in(manifest, ["video", "original"]) == source_url
    assert get_in(manifest, ["video", "src"]) == source_url
    assert get_in(manifest, ["video", "status"]) == "playable"
    assert get_in(manifest, ["video", "ready"]) == true

    assert {:ok, player_html} =
             FlowStorageAdapterStub.get(
               "space-#{space.hash}",
               "#{embed.hash}/player.html",
               space.region
             )

    assert player_html =~ "<mave-player"

    inspect_step = Repo.get_by!(StepRun, flow_run_id: run.id, step_id: "inspect_media")
    assert get_in(inspect_step.execution_metadata, ["processing_player", "ready"]) == true

    assert_receive {:completed, %{embed: completed_embed}}
    assert completed_embed == "#{space.hash}#{embed.hash}"
    assert Embeds.processing_player_ready?(space.hash, embed.hash)
  end

  test "media inspect enqueues processing webhook after projecting playable metadata" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "processing-webhook-#{System.unique_integer([:positive])}",
        "name" => "Processing Webhook"
      })

    {:ok, _version} =
      Flow.create_version(template.id, %{
        "definition" => %{
          "steps" => [
            %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"},
            %{
              "id" => "upload_original",
              "type" => "asset.upload_original",
              "name" => "Upload Original",
              "depends_on" => ["source"]
            },
            %{
              "id" => "inspect_media",
              "type" => "media.inspect",
              "name" => "Inspect Media",
              "depends_on" => ["upload_original"]
            }
          ]
        }
      })

    space = space_fixture()
    {:ok, webhook} = Spaces.create_webhook(space, %{"url" => "https://example.com/webhook"})
    {:ok, _webhook} = Spaces.update_webhook(webhook, %{"enabled_events" => [:video_processing]})
    {:ok, embed} = Embeds.create_video_embed(space, %{name: "Processing Webhook Upload"})

    {:ok, _embed} =
      Embeds.begin_video_upload(space.hash, embed.hash, %{
        "title" => "Processing Webhook Upload.mp4",
        "source_url" => "https://example.com/processing.mp4",
        "upload_size" => 654_321
      })

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => space.hash,
          "embed_hash" => embed.hash,
          "input_url" => "https://example.com/processing.mp4",
          "source_url" => "https://example.com/processing.mp4",
          "source_body" => "stub-media-body",
          "source_content_type" => "video/mp4",
          "media_probe" => %{
            "duration" => 8.25,
            "size_bytes" => 987_654,
            "aspect_ratio" => "16 / 9",
            "width" => 1280,
            "height" => 720,
            "streams" => [
              %{
                "codec_type" => "video",
                "width" => 1280,
                "height" => 720,
                "avg_frame_rate" => "25/1",
                "bit_rate" => "2100000"
              }
            ]
          }
        },
        enqueue: false
      )

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)
    assert {:ok, _source_output} = Flow.execute_step(run.id, "source", enqueue_coordinator: false)
    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    assert {:ok, _upload_output} =
             Flow.execute_step(run.id, "upload_original", enqueue_coordinator: false)

    assert Spaces.list_webhook_deliveries(space) == []

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    assert {:ok, _inspect_output} =
             Flow.execute_step(run.id, "inspect_media", enqueue_coordinator: false)

    assert [delivery] = Spaces.list_webhook_deliveries(space)
    assert delivery.event_type == :video_processing

    payload = delivery.payload |> Jason.encode!() |> Jason.decode!()
    assert payload["id"] == "#{space.hash}#{embed.hash}"
    assert payload["duration"] == 8.25
    assert payload["width"] == 1280
    assert payload["height"] == 720
    assert payload["size"] == 987_654
    assert payload["renditions"] == []

    refreshed_embed = Repo.get!(Embed, embed.id) |> Repo.preload(asset: [:current_video])
    assert %Video{status: "playable"} = refreshed_embed.asset.current_video
  end

  test "public video rendition sizes enqueue ready webhooks as they finish" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "ready-renditions-#{System.unique_integer([:positive])}",
        "name" => "Ready Renditions"
      })

    {:ok, _version} =
      Flow.create_version(template.id, %{
        "definition" => %{
          "steps" => [
            %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"},
            %{
              "id" => "upload_original",
              "type" => "asset.upload_original",
              "name" => "Upload Original",
              "depends_on" => ["source"]
            },
            %{
              "id" => "inspect_media",
              "type" => "media.inspect",
              "name" => "Inspect Media",
              "depends_on" => ["upload_original"]
            },
            %{
              "id" => "video_sd",
              "type" => "media.transcode_video",
              "name" => "Video SD",
              "depends_on" => ["inspect_media"],
              "params" => %{"codec" => "h264", "size" => "sd", "container" => "mp4"}
            },
            %{
              "id" => "video_sd_webm",
              "type" => "media.transcode_video",
              "name" => "Video SD WebM",
              "depends_on" => ["video_sd"],
              "params" => %{"codec" => "h264", "size" => "sd", "container" => "webm"}
            },
            %{
              "id" => "video_hd",
              "type" => "media.transcode_video",
              "name" => "Video HD",
              "depends_on" => ["video_sd_webm"],
              "params" => %{"codec" => "h264", "size" => "hd", "container" => "mp4"}
            },
            %{
              "id" => "clip_keyframes",
              "type" => "media.transcode_video",
              "name" => "Clip Keyframes",
              "depends_on" => ["video_hd"],
              "params" => %{
                "codec" => "h264",
                "size" => "sd",
                "container" => "mp4",
                "keyframe_interval" => 2
              }
            }
          ]
        }
      })

    space = space_fixture()
    {:ok, webhook} = Spaces.create_webhook(space, %{"url" => "https://example.com/webhook"})
    {:ok, _webhook} = Spaces.update_webhook(webhook, %{"enabled_events" => [:video_ready]})
    {:ok, embed} = Embeds.create_video_embed(space, %{name: "Ready Renditions Upload"})
    upload_id = Ecto.UUID.generate()
    UploadEvents.subscribe(upload_id)

    {:ok, _embed} =
      Embeds.begin_video_upload(space.hash, embed.hash, %{
        "title" => "Ready Renditions Upload.mp4",
        "source_url" => "https://example.com/ready-renditions.mp4",
        "upload_size" => 123_456
      })

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => space.hash,
          "embed_hash" => embed.hash,
          "input_url" => "https://example.com/ready-renditions.mp4",
          "source_url" => "https://example.com/ready-renditions.mp4",
          "source_body" => "stub-media-body",
          "source_content_type" => "video/mp4",
          "upload_id" => upload_id,
          "media_probe" => %{
            "duration" => 9.5,
            "size_bytes" => 123_456,
            "width" => 1280,
            "height" => 720,
            "streams" => [
              %{"codec_type" => "video", "width" => 1280, "height" => 720}
            ]
          }
        },
        enqueue: false
      )

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)
    assert {:ok, _source_output} = Flow.execute_step(run.id, "source", enqueue_coordinator: false)
    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    assert {:ok, _upload_output} =
             Flow.execute_step(run.id, "upload_original", enqueue_coordinator: false)

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    assert {:ok, _inspect_output} =
             Flow.execute_step(run.id, "inspect_media", enqueue_coordinator: false)

    assert Spaces.list_webhook_deliveries(space) == []

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)
    assert {:ok, _sd_output} = Flow.execute_step(run.id, "video_sd", enqueue_coordinator: false)

    assert_receive {:rendition,
                    %{
                      id: _id,
                      type: "video",
                      codec: "h264",
                      container: "mp4",
                      size: "sd"
                    }}

    assert [sd_delivery] = Spaces.list_webhook_deliveries(space)
    assert sd_delivery.event_type == :video_ready
    assert %{"renditions" => ["sd"]} = sd_delivery.payload |> Jason.encode!() |> Jason.decode!()

    assert {:ok, sd_manifest_json} =
             FlowStorageAdapterStub.get(
               "space-#{space.hash}",
               "#{embed.hash}/manifest.json",
               space.region
             )

    sd_manifest = Jason.decode!(sd_manifest_json)

    assert get_in(sd_manifest, ["video", "original"]) == nil
    assert get_in(sd_manifest, ["video", "src"]) == nil

    assert Enum.any?(get_in(sd_manifest, ["video", "renditions"]), fn rendition ->
             rendition["type"] == "video" and rendition["size"] == "sd" and
               rendition["container"] == "mp4"
           end)

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    assert {:ok, _sd_webm_output} =
             Flow.execute_step(run.id, "video_sd_webm", enqueue_coordinator: false)

    assert [_sd_delivery] = Spaces.list_webhook_deliveries(space)

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)
    assert {:ok, _hd_output} = Flow.execute_step(run.id, "video_hd", enqueue_coordinator: false)

    deliveries = Spaces.list_webhook_deliveries(space)
    assert length(deliveries) == 2
    payloads = Enum.map(deliveries, &(&1.payload |> Jason.encode!() |> Jason.decode!()))
    assert Enum.any?(payloads, &(&1["renditions"] == ["sd"]))
    assert Enum.any?(payloads, &(&1["renditions"] == ["sd", "hd"]))

    assert {:ok, hd_manifest_json} =
             FlowStorageAdapterStub.get(
               "space-#{space.hash}",
               "#{embed.hash}/manifest.json",
               space.region
             )

    hd_renditions = hd_manifest_json |> Jason.decode!() |> get_in(["video", "renditions"])
    assert Enum.any?(hd_renditions, &(&1["size"] == "sd" and &1["container"] == "mp4"))
    assert Enum.any?(hd_renditions, &(&1["size"] == "hd" and &1["container"] == "mp4"))

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    assert {:ok, _clip_output} =
             Flow.execute_step(run.id, "clip_keyframes", enqueue_coordinator: false)

    video_id =
      embed
      |> Repo.reload!()
      |> Repo.preload(asset: [:current_video])
      |> get_in([Access.key!(:asset), Access.key!(:current_video), Access.key!(:id)])

    clip_rendition =
      from(r in "renditions",
        where:
          r.video_id == type(^video_id, MaveCore.Ecto.LegacyShortUUID) and
            r.type == "clip_keyframes",
        select: %{type: r.type, size: r.size, container: r.container}
      )
      |> Repo.one!()

    assert clip_rendition == %{type: "clip_keyframes", size: "sd", container: "mp4"}
    assert length(Spaces.list_webhook_deliveries(space)) == 2

    assert {:ok, clip_manifest_json} =
             FlowStorageAdapterStub.get(
               "space-#{space.hash}",
               "#{embed.hash}/manifest.json",
               space.region
             )

    clip_renditions = clip_manifest_json |> Jason.decode!() |> get_in(["video", "renditions"])
    assert Enum.any?(clip_renditions, &(&1["type"] == "clip_keyframes"))

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)
    assert length(Spaces.list_webhook_deliveries(space)) == 2
  end

  test "audio tracks and subtitles are published before the full run finishes" do
    {:ok, template} =
      Flow.create_template(%{
        "slug" => "progressive-media-metadata-#{System.unique_integer([:positive])}",
        "name" => "Progressive Media Metadata"
      })

    {:ok, _version} =
      Flow.create_version(template.id, %{
        "definition" => %{
          "steps" => [
            %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"},
            %{
              "id" => "upload_original",
              "type" => "asset.upload_original",
              "name" => "Upload Original",
              "depends_on" => ["source"]
            },
            %{
              "id" => "inspect_media",
              "type" => "media.inspect",
              "name" => "Inspect Media",
              "depends_on" => ["upload_original"]
            },
            %{
              "id" => "transcode_audio",
              "type" => "media.transcode_audio",
              "name" => "Transcode Audio",
              "depends_on" => ["inspect_media"],
              "params" => %{
                "codec" => "mp3",
                "container" => "mp3",
                "label" => "Original",
                "language" => "en",
                "default" => true
              }
            },
            %{
              "id" => "transcribe_audio",
              "type" => "ai.transcribe_audio",
              "name" => "Transcribe Audio",
              "depends_on" => ["inspect_media", "transcode_audio"]
            },
            %{
              "id" => "manifest",
              "type" => "manifest.build",
              "name" => "Build Final Manifest",
              "depends_on" => ["transcribe_audio"]
            }
          ]
        }
      })

    space = space_fixture()
    {:ok, embed} = Embeds.create_video_embed(space, %{name: "Progressive Metadata Upload"})

    {:ok, embed} =
      Embeds.begin_video_upload(space.hash, embed.hash, %{
        "title" => "Progressive Metadata Upload.mp4",
        "source_url" => "https://example.com/progressive-metadata.mp4",
        "upload_size" => 123_456
      })

    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => space.hash,
          "embed_hash" => embed.hash,
          "input_url" => "https://example.com/progressive-metadata.mp4",
          "source_url" => "https://example.com/progressive-metadata.mp4",
          "source_body" => "stub-media-body",
          "source_content_type" => "video/mp4",
          "transcription_text" => "Hello world from progressive metadata",
          "transcription_language" => "en",
          "media_probe" => %{
            "duration" => 9.5,
            "size_bytes" => 123_456,
            "width" => 1280,
            "height" => 720,
            "streams" => [
              %{"codec_type" => "video", "codec_name" => "h264", "width" => 1280},
              %{"codec_type" => "audio", "codec_name" => "aac", "channels" => 2}
            ]
          }
        },
        enqueue: false
      )

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)
    assert {:ok, _source} = Flow.execute_step(run.id, "source", enqueue_coordinator: false)
    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    assert {:ok, _original} =
             Flow.execute_step(run.id, "upload_original", enqueue_coordinator: false)

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    assert {:ok, _inspect} =
             Flow.execute_step(run.id, "inspect_media", enqueue_coordinator: false)

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    assert {:ok, _audio} =
             Flow.execute_step(run.id, "transcode_audio", enqueue_coordinator: false)

    assert %Run{status: "running"} = Repo.get!(Run, run.id)

    assert [%AudioTrack{filename: "audio.mp3", codec: "mp3", default: true}] =
             Repo.all(
               from(track in AudioTrack, where: track.video_id == ^embed.asset.current_video_id)
             )

    assert {:ok, audio_manifest_json} =
             FlowStorageAdapterStub.get(
               "space-#{space.hash}",
               "#{embed.hash}/manifest.json",
               space.region
             )

    assert [%{"filename" => "audio.mp3", "codec" => "mp3"}] =
             audio_manifest_json |> Jason.decode!() |> Map.fetch!("audio_tracks")

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    assert {:ok, _subtitle} =
             Flow.execute_step(run.id, "transcribe_audio", enqueue_coordinator: false)

    assert %Run{status: "running"} = Repo.get!(Run, run.id)

    assert [%Subtitle{language: "en"}] =
             Repo.all(
               from(subtitle in Subtitle,
                 where: subtitle.video_id == ^embed.asset.current_video_id
               )
             )

    assert {:ok, subtitle_manifest_json} =
             FlowStorageAdapterStub.get(
               "space-#{space.hash}",
               "#{embed.hash}/manifest.json",
               space.region
             )

    subtitle_manifest = Jason.decode!(subtitle_manifest_json)
    assert [%{"filename" => "audio.mp3"}] = subtitle_manifest["audio_tracks"]
    assert [%{"language" => "en"}] = subtitle_manifest["subtitles"]
  end

  defp rendition_output(rendition_key, file_size) do
    %{
      "rendition_key" => rendition_key,
      "type" => "video",
      "codec" => "h264",
      "container" => "mp4",
      "size" => "sd",
      "progress" => 100.0,
      "file_size" => file_size
    }
  end

  defp durable_original_output(space, embed_hash, version) do
    %{
      "status" => "ok",
      "bucket" => "space-#{space.hash}",
      "original_key" => "#{embed_hash}/v#{version}/original",
      "region" => space.region,
      "content_type" => "video/mp4"
    }
  end

  defp space_fixture do
    email = "flow-space-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(email)
    user.current_space_membership.space
  end

  defp mark_step!(flow_run_id, step_id, attrs) do
    StepRun
    |> Repo.get_by!(flow_run_id: flow_run_id, step_id: step_id)
    |> StepRun.changeset(attrs)
    |> Repo.update!()
  end

  defp enable_booster do
    Application.put_env(:mave_core, :encoding_booster,
      enabled: true,
      fallback_enabled: true
    )
  end

  defp configure_work_conserving_booster_test do
    old_fair_queues = Application.get_env(:mave_core, :flow_fair_queues)
    old_retry_config = Application.get_env(:mave_core, :flow_step_auto_retry)

    Application.put_env(:mave_core, :flow_fair_queues,
      flow_booster: [
        space_concurrency: 2,
        global_concurrency: 4,
        work_conserving: true,
        snooze_seconds: 7
      ]
    )

    Application.put_env(:mave_core, :flow_step_auto_retry, false)
    Application.put_env(:mave_core, :encoding_booster, enabled: true, fallback_enabled: true)
    Application.put_env(:mave_core, :encoding_booster_adapter, BusyEncodingBoosterAdapterStub)

    on_exit(fn ->
      restore_env(:flow_fair_queues, old_fair_queues)
      restore_env(:flow_step_auto_retry, old_retry_config)
    end)
  end

  defp configure_work_conserving_flow_steps_test do
    old_fair_queues = Application.get_env(:mave_core, :flow_fair_queues)

    Application.put_env(:mave_core, :flow_fair_queues,
      flow_steps: [
        space_concurrency: 1,
        global_concurrency: 4,
        new_space_headroom: 1,
        work_conserving: true,
        snooze_seconds: 7
      ]
    )

    on_exit(fn -> restore_env(:flow_fair_queues, old_fair_queues) end)
  end

  defp create_scheduled_source_run!(template, space_hash) do
    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => space_hash,
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4"
        },
        enqueue: false
      )

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    {:ok, _job} =
      Oban.Testing.with_testing_mode(:manual, fn ->
        %{
          "flow_run_id" => run.id,
          "step_id" => "source",
          "space_hash" => space_hash
        }
        |> FlowStepWorker.new(queue: :flow_steps)
        |> Oban.insert()
      end)

    run
  end

  defp mark_source_step_executing!(run) do
    mark_step!(run.id, "source", %{
      status: "executing",
      execution_metadata: %{"queue" => "flow_steps"}
    })
  end

  defp perform_source_step(run) do
    FlowStepWorker.perform(%Job{
      queue: "flow_steps",
      args: %{"flow_run_id" => run.id, "step_id" => "source"}
    })
  end

  defp demanding_flow_step_spaces do
    Job
    |> where([job], job.worker == "MaveCore.Workers.FlowStepWorker")
    |> where([job], job.state in ["available", "scheduled", "retryable", "executing"])
    |> where([job], job.queue == "flow_steps")
    |> select([job], count(fragment("?->>'space_hash'", job.args), :distinct))
    |> Repo.one!()
  end

  defp create_scheduled_booster_run!(template, space_hash) do
    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => space_hash,
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4",
          "media_transcode_video_mode" => "ffmpeg"
        },
        enqueue: false
      )

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)

    {:ok, _job} =
      Oban.Testing.with_testing_mode(:manual, fn ->
        %{
          "flow_run_id" => run.id,
          "step_id" => "clip_h264_sd_keyframes",
          "space_hash" => space_hash
        }
        |> FlowStepWorker.new(queue: :flow_booster)
        |> Oban.insert()
      end)

    run
  end

  defp create_scheduled_run!(template, space_hash) do
    {:ok, run} =
      Flow.start_run(
        template.slug,
        %{
          "space_hash" => space_hash,
          "embed_hash" => "LeDE9v86ye",
          "input_url" => "https://example.com/video.mp4",
          "media_transcode_video_mode" => "ffmpeg"
        },
        enqueue: false
      )

    {:ok, _run} = Flow.reconcile_run(run.id, enqueue_jobs: false)
    run
  end

  defp mark_booster_step_executing!(run) do
    mark_step!(run.id, "clip_h264_sd_keyframes", %{
      status: "executing",
      execution_metadata: %{"queue" => "flow_booster"}
    })
  end

  defp perform_booster_step(run) do
    FlowStepWorker.perform(%Job{
      queue: "flow_booster",
      args: %{
        "flow_run_id" => run.id,
        "step_id" => "clip_h264_sd_keyframes"
      }
    })
  end

  defp perform_background_booster_step(run, step_id) do
    FlowStepWorker.perform(%Job{
      queue: "flow_booster_background",
      args: %{
        "flow_run_id" => run.id,
        "step_id" => step_id
      }
    })
  end

  defp demanding_booster_spaces do
    Job
    |> where([job], job.worker == "MaveCore.Workers.FlowStepWorker")
    |> where([job], job.state in ["available", "scheduled", "retryable", "executing"])
    |> where([job], job.queue == "flow_booster")
    |> select([job], count(fragment("?->>'space_hash'", job.args), :distinct))
    |> Repo.one!()
  end

  defp active_booster_steps do
    StepRun
    |> join(:inner, [step_run], run in Run, on: run.id == step_run.flow_run_id)
    |> where([step_run, _run], step_run.status == "executing")
    |> where([_step_run, run], run.status in ["queued", "running"])
    |> where(
      [step_run, _run],
      step_run.step_type in [
        "media.transcode_h264_ladder",
        "media.transcode_video",
        "media.package_hls_variant"
      ]
    )
    |> Repo.aggregate(:count)
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)

  defp with_runtime_env(values, fun) do
    previous = Map.new(values, fn {key, _value} -> {key, System.get_env(key)} end)

    Enum.each(values, fn {key, value} -> System.put_env(key, value) end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end
end
