defmodule MaveCore.Flow.Steps.SupportTest do
  use ExUnit.Case, async: false

  alias MaveCore.Flow.Steps.Support
  alias MaveCore.Media.Storage
  alias MaveCore.TestSupport.FlowStorageAdapterStub

  defmodule FfmpegUrlStorageAdapter do
    @moduledoc false

    alias MaveCore.TestSupport.FlowStorageAdapterStub

    def ffmpeg_input_url(bucket, path, _region) do
      {:ok, "https://s3.test/#{bucket}/#{path}"}
    end

    def download_to_file(bucket, path, destination_path, region) do
      FlowStorageAdapterStub.download_to_file(bucket, path, destination_path, region)
    end
  end

  setup do
    old_storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter)

    old_direct_storage_ffmpeg_input =
      Application.get_env(:mave_core, :flow_direct_storage_ffmpeg_input)

    old_media_command_timeout = Application.get_env(:mave_core, :flow_media_command_timeout_ms)

    Application.put_env(
      :mave_core,
      :flow_storage_adapter,
      FlowStorageAdapterStub
    )

    Application.put_env(:mave_core, :flow_direct_storage_ffmpeg_input, true)

    FlowStorageAdapterStub.reset!()

    on_exit(fn ->
      FlowStorageAdapterStub.reset!()
      restore_env(:flow_storage_adapter, old_storage_adapter)
      restore_env(:flow_direct_storage_ffmpeg_input, old_direct_storage_ffmpeg_input)
      restore_env(:flow_media_command_timeout_ms, old_media_command_timeout)
    end)

    :ok
  end

  test "streams storage-backed ffmpeg input when direct storage reads are enabled" do
    assert {:ok, _body} =
             FlowStorageAdapterStub.put(
               "mave-upload",
               "uploads/demo.mp4",
               "stub-from-storage",
               "video/mp4",
               "us-east-1"
             )

    Support.with_temp_dir("support_test", fn tmp_dir ->
      assert {:ok, input_path} =
               Support.prepare_ffmpeg_input(
                 tmp_dir,
                 %{
                   "source_bucket" => "mave-upload",
                   "source_key" => "uploads/demo.mp4",
                   "source_region" => "us-east-1",
                   "source_content_type" => "video/mp4"
                 },
                 "https://example.com/video.mp4"
               )

      assert input_path == "https://storage.example/mave-upload/uploads/demo.mp4"
      refute File.exists?(Path.join(tmp_dir, "input.mp4"))
    end)
  end

  test "keeps the completed upload object as the original ffmpeg input" do
    Application.put_env(:mave_core, :flow_storage_adapter, FfmpegUrlStorageAdapter)

    assert {:ok, _body} =
             FlowStorageAdapterStub.put(
               "mave-upload",
               "uploads/demo.mp4",
               "external-source",
               "video/mp4",
               "us-east-1"
             )

    assert {:ok, _body} =
             FlowStorageAdapterStub.put(
               "space-ubg50",
               "LeDE9v86ye/original",
               "our-original",
               "video/mp4",
               "us-east-1"
             )

    run_input = %{
      "region" => "us-east-1",
      "source_bucket" => "mave-upload",
      "source_key" => "uploads/demo.mp4",
      "source_region" => "us-east-1",
      "source_content_type" => "video/mp4"
    }

    dependency_outputs = %{
      "upload_original" => %{
        "bucket" => "space-ubg50",
        "original_key" => "LeDE9v86ye/original",
        "original_uri" => "s3://space-ubg50/LeDE9v86ye/original",
        "content_type" => "video/mp4"
      }
    }

    Support.with_temp_dir("support_test", fn tmp_dir ->
      assert {:ok, input_path} =
               Support.prepare_ffmpeg_input(
                 tmp_dir,
                 run_input,
                 "https://example.com/video.mp4",
                 dependency_outputs
               )

      assert input_path == "https://s3.test/mave-upload/uploads/demo.mp4"

      refute File.exists?(Path.join(tmp_dir, "input.mp4"))
    end)
  end

  test "uses a presigned streaming URL for local ffmpeg reading a private customer object" do
    Support.with_temp_dir("support_test", fn tmp_dir ->
      assert {:ok, input_path} =
               Support.prepare_ffmpeg_input(
                 tmp_dir,
                 %{
                   "source_bucket" => "space-trial",
                   "source_key" => "LeDE9v86ye/original.mp4",
                   "source_region" => "eu_3",
                   "source_content_type" => "video/mp4"
                 },
                 "https://example.com/video.mp4"
               )

      assert input_path ==
               "https://storage.example/space-trial/LeDE9v86ye/original.mp4?signature=test"

      refute File.exists?(Path.join(tmp_dir, "input.mp4"))
    end)
  end

  test "ignores a legacy private URL stored as the upload ffmpeg input" do
    Support.with_temp_dir("support_test", fn tmp_dir ->
      assert {:ok, input_path} =
               Support.prepare_ffmpeg_input(
                 tmp_dir,
                 %{
                   "source_bucket" => "space-trial",
                   "source_key" => "LeDE9v86ye/original.mp4",
                   "source_region" => "eu_3",
                   "source_content_type" => "video/mp4",
                   "upload_ffmpeg_input_url" =>
                     "https://storage.example/space-trial/LeDE9v86ye/original.mp4"
                 },
                 "https://example.com/video.mp4"
               )

      assert input_path ==
               "https://storage.example/space-trial/LeDE9v86ye/original.mp4?signature=test"

      refute File.exists?(Path.join(tmp_dir, "input.mp4"))
    end)
  end

  test "can prefer the upload bucket URL for the encoding booster" do
    Application.put_env(:mave_core, :flow_storage_adapter, FfmpegUrlStorageAdapter)

    run_input = %{
      "source_bucket" => "mave-upload",
      "source_key" => "uploads/demo.mp4",
      "source_region" => "us-east-1",
      "source_content_type" => "video/mp4"
    }

    dependency_outputs = %{
      "upload_original" => %{
        "bucket" => "space-ubg50",
        "original_key" => "LeDE9v86ye/original",
        "original_uri" => "s3://space-ubg50/LeDE9v86ye/original",
        "content_type" => "video/mp4"
      }
    }

    assert {:ok, url} =
             Support.encoding_booster_input_url(
               run_input,
               "https://example.com/video.mp4",
               dependency_outputs,
               prefer_source_storage: true
             )

    assert url ==
             "https://s3.test/mave-upload/uploads/demo.mp4"
  end

  test "uses a presigned streaming URL for a private customer-bucket source" do
    run_input = %{
      "source_bucket" => "space-trial",
      "source_key" => "LeDE9v86ye/original.mp4",
      "source_region" => "eu_3",
      "source_content_type" => "video/mp4"
    }

    assert {:ok, url} =
             Support.encoding_booster_input_url(
               run_input,
               "https://example.com/video.mp4",
               %{},
               prefer_source_storage: true
             )

    assert url ==
             "https://storage.example/space-trial/LeDE9v86ye/original.mp4?signature=test"
  end

  test "uses a presigned streaming URL for an intermediate video rendition" do
    dependency_outputs = %{
      "video_h264_sd" => %{
        "status" => "ok",
        "step_type" => "media.transcode_h264_ladder",
        "bucket" => "space-ubg50",
        "region" => "eu_2",
        "variant_outputs" => %{
          "sd" => %{
            "status" => "ok",
            "bucket" => "space-ubg50",
            "key" => "LeDE9v86ye/h264_sd.mp4",
            "codec" => "h264",
            "size" => "sd",
            "container" => "mp4"
          }
        }
      }
    }

    assert {:ok, url} =
             Support.encoding_booster_input_url(
               %{"region" => "eu_2"},
               "https://example.com/video.mp4",
               dependency_outputs,
               prefer_video_rendition: true,
               preferred_video_step_id: "video_h264_sd",
               preferred_video_size: "sd",
               preferred_video_codec: "h264"
             )

    assert url ==
             "https://storage.example/space-ubg50/LeDE9v86ye/h264_sd.mp4?signature=test"
  end

  test "uses a requested completed step output instead of the upload URL" do
    dependency_outputs = %{
      "transcode_audio" => %{
        "status" => "ok",
        "step_type" => "media.transcode_audio",
        "bucket" => "space-ubg50",
        "region" => "eu_2",
        "key" => "LeDE9v86ye/audio.mp3",
        "uri" => "s3://space-ubg50/LeDE9v86ye/audio.mp3"
      }
    }

    assert {:ok, url} =
             Support.encoding_booster_input_url(
               %{
                 "region" => "eu_2",
                 "upload_ffmpeg_input_url" => "https://uploads.test/mave-upload/uploads/demo.mp4"
               },
               "https://example.com/video.mp4",
               dependency_outputs,
               preferred_storage_step_id: "transcode_audio",
               preferred_storage_content_type: "audio/mpeg"
             )

    assert url ==
             "https://storage.example/space-ubg50/LeDE9v86ye/audio.mp3?signature=test"
  end

  test "accepts a remote HTTPS source URL for the encoding booster" do
    assert {:ok, "https://example.com/video.mp4"} =
             Support.encoding_booster_input_url(%{}, "https://example.com/video.mp4")

    assert {:ok, "https://video:p%40ssword@example.com/video.mp4"} =
             Support.encoding_booster_input_url(
               %{},
               "https://video:p%40ssword@example.com/video.mp4"
             )
  end

  test "durable remote runs never fall back from storage to the tenant URL" do
    Application.put_env(:mave_core, :flow_storage_adapter, Map)

    dependency_outputs = %{
      "upload_original" => %{
        "bucket" => "space-ubg50",
        "original_key" => "LeDE9v86ye/original",
        "original_uri" => "s3://space-ubg50/LeDE9v86ye/original",
        "content_type" => "video/mp4"
      }
    }

    assert {:error, :durable_media_source_required} =
             Support.encoding_booster_input_url(
               %{"durable_source_required" => true, "region" => "eu"},
               "https://tenant.example/video.mp4",
               dependency_outputs
             )
  end

  test "rejects inline and non-HTTPS encoding booster sources" do
    assert {:error, :encoding_booster_inline_source_unsupported} =
             Support.encoding_booster_input_url(
               %{"source_body" => "media"},
               "https://example.com/video.mp4"
             )

    assert {:error, :encoding_booster_input_must_be_https} =
             Support.encoding_booster_input_url(%{}, "http://example.com/video.mp4")
  end

  test "can force download storage-backed ffmpeg input for fallback" do
    Application.put_env(:mave_core, :flow_storage_adapter, FfmpegUrlStorageAdapter)

    assert {:ok, _body} =
             FlowStorageAdapterStub.put(
               "mave-upload",
               "uploads/demo.mp4",
               "completed-upload",
               "video/mp4",
               "us-east-1"
             )

    assert {:ok, _body} =
             FlowStorageAdapterStub.put(
               "space-ubg50",
               "LeDE9v86ye/original",
               "our-original",
               "video/mp4",
               "us-east-1"
             )

    run_input = %{
      "region" => "us-east-1",
      "source_bucket" => "mave-upload",
      "source_key" => "uploads/demo.mp4",
      "source_region" => "us-east-1",
      "source_content_type" => "video/mp4"
    }

    dependency_outputs = %{
      "upload_original" => %{
        "bucket" => "space-ubg50",
        "original_key" => "LeDE9v86ye/original",
        "original_uri" => "s3://space-ubg50/LeDE9v86ye/original",
        "content_type" => "video/mp4"
      }
    }

    Support.with_temp_dir("support_test", fn tmp_dir ->
      assert {:ok, input_path} =
               Support.prepare_ffmpeg_input(
                 tmp_dir,
                 run_input,
                 "https://example.com/video.mp4",
                 dependency_outputs,
                 force_download: true
               )

      assert input_path == Path.join(tmp_dir, "input.mp4")
      assert File.read!(input_path) == "completed-upload"
    end)
  end

  test "downloads storage-backed ffmpeg input when direct storage URLs are disabled" do
    Application.put_env(:mave_core, :flow_storage_adapter, FfmpegUrlStorageAdapter)
    Application.put_env(:mave_core, :flow_direct_storage_ffmpeg_input, false)

    assert {:ok, _body} =
             FlowStorageAdapterStub.put(
               "mave-upload",
               "uploads/demo.mp4",
               "completed-upload",
               "video/mp4",
               "us-east-1"
             )

    run_input = %{
      "region" => "us-east-1",
      "source_bucket" => "mave-upload",
      "source_key" => "uploads/demo.mp4",
      "source_region" => "us-east-1",
      "source_content_type" => "video/mp4"
    }

    dependency_outputs = %{
      "upload_original" => %{
        "bucket" => "space-ubg50",
        "original_key" => "LeDE9v86ye/original",
        "original_uri" => "s3://space-ubg50/LeDE9v86ye/original",
        "content_type" => "video/mp4"
      }
    }

    Support.with_temp_dir("support_test", fn tmp_dir ->
      assert {:ok, input_path} =
               Support.prepare_ffmpeg_input(
                 tmp_dir,
                 run_input,
                 "https://example.com/video.mp4",
                 dependency_outputs
               )

      assert input_path == Path.join(tmp_dir, "input.mp4")
      assert File.read!(input_path) == "completed-upload"
    end)
  end

  test "uses the tusd upload URL even when generic direct storage input is disabled" do
    Application.put_env(:mave_core, :flow_storage_adapter, FfmpegUrlStorageAdapter)
    Application.put_env(:mave_core, :flow_direct_storage_ffmpeg_input, false)

    assert {:ok, _body} =
             FlowStorageAdapterStub.put(
               "mave-upload",
               "uploads/demo.mp4",
               "uploaded-source",
               "video/mp4",
               "us-east-1"
             )

    run_input = %{
      "upload_ffmpeg_input_url" => "https://uploads.test/mave-upload/uploads/demo.mp4",
      "source_bucket" => "mave-upload",
      "source_key" => "uploads/demo.mp4",
      "source_region" => "us-east-1",
      "source_content_type" => "video/mp4"
    }

    Support.with_temp_dir("support_test", fn tmp_dir ->
      assert {:ok, "https://uploads.test/mave-upload/uploads/demo.mp4"} =
               Support.prepare_ffmpeg_input(
                 tmp_dir,
                 run_input,
                 "https://example.com/video.mp4"
               )

      assert {:ok, input_path} =
               Support.prepare_ffmpeg_input(
                 tmp_dir,
                 run_input,
                 "https://example.com/video.mp4",
                 %{},
                 force_download: true
               )

      assert input_path == Path.join(tmp_dir, "input.mp4")
      assert File.read!(input_path) == "uploaded-source"
    end)
  end

  test "prefers requested video rendition over upload URL and uploaded original" do
    Application.put_env(:mave_core, :flow_direct_storage_ffmpeg_input, false)

    assert {:ok, _body} =
             FlowStorageAdapterStub.put(
               "space-ubg50",
               "LeDE9v86ye/original",
               "large-original",
               "video/mp4",
               "us-east-1"
             )

    assert {:ok, _body} =
             FlowStorageAdapterStub.put(
               "space-ubg50",
               "LeDE9v86ye/h264_sd.mp4",
               "small-rendition",
               "video/mp4",
               "us-east-1"
             )

    run_input = %{
      "region" => "us-east-1",
      "upload_ffmpeg_input_url" => "https://uploads.test/mave-upload/uploads/demo.mp4"
    }

    dependency_outputs = %{
      "upload_original" => %{
        "bucket" => "space-ubg50",
        "original_key" => "LeDE9v86ye/original",
        "content_type" => "video/mp4"
      },
      "video_h264_ladder" => %{
        "status" => "ok",
        "step_type" => "media.transcode_h264_ladder",
        "bucket" => "space-ubg50",
        "region" => "us-east-1",
        "variant_outputs" => %{
          "sd" => %{
            "status" => "ok",
            "bucket" => "space-ubg50",
            "key" => "LeDE9v86ye/h264_sd.mp4",
            "codec" => "h264",
            "size" => "sd",
            "container" => "mp4"
          }
        }
      }
    }

    Support.with_temp_dir("support_test", fn tmp_dir ->
      assert {:ok, input_path} =
               Support.prepare_ffmpeg_input(
                 tmp_dir,
                 run_input,
                 "https://example.com/video.mp4",
                 dependency_outputs,
                 prefer_video_rendition: true,
                 preferred_video_step_id: "video_h264_ladder",
                 preferred_video_sizes: ["sd"],
                 preferred_video_codec: "h264"
               )

      assert input_path == Path.join(tmp_dir, "input.mp4")
      assert File.read!(input_path) == "small-rendition"
    end)
  end

  test "falls back to uploaded original when a preferred rendition is unavailable" do
    Application.put_env(:mave_core, :flow_direct_storage_ffmpeg_input, false)

    assert {:ok, _body} =
             FlowStorageAdapterStub.put(
               "space-ubg50",
               "LeDE9v86ye/original",
               "our-original",
               "video/mp4",
               "us-east-1"
             )

    run_input = %{
      "region" => "us-east-1",
      "upload_ffmpeg_input_url" => "https://uploads.test/mave-upload/uploads/demo.mp4"
    }

    dependency_outputs = %{
      "upload_original" => %{
        "bucket" => "space-ubg50",
        "original_key" => "LeDE9v86ye/original",
        "content_type" => "video/mp4"
      }
    }

    Support.with_temp_dir("support_test", fn tmp_dir ->
      assert {:ok, input_path} =
               Support.prepare_ffmpeg_input(
                 tmp_dir,
                 run_input,
                 "https://example.com/video.mp4",
                 dependency_outputs,
                 prefer_video_rendition: true,
                 preferred_video_step_id: "video_h264_ladder",
                 preferred_video_sizes: ["sd"],
                 preferred_video_codec: "h264"
               )

      assert input_path == Path.join(tmp_dir, "input.mp4")
      assert File.read!(input_path) == "our-original"
    end)
  end

  test "redacts signed storage URLs from media command output" do
    output =
      "error opening https://s3.test/space-ubg50/video.mp4?X-Amz-Credential=key&X-Amz-Signature=secret"

    assert Support.sanitize_media_output(output) ==
             "error opening https://s3.test/space-ubg50/video.mp4?[redacted]"
  end

  test "run_media_cmd captures media command output and status" do
    with_fake_ffmpeg(
      """
      #!/bin/sh
      echo "ffmpeg output"
      exit 7
      """,
      fn ffmpeg_path, _tmp_dir ->
        assert {"ffmpeg output\n", 7} = Support.run_media_cmd(ffmpeg_path, [])
      end
    )
  end

  test "run_media_cmd bounds noisy output and retains the final diagnostics" do
    with_fake_ffmpeg(
      """
      #!/bin/sh
      head -c 2097152 /dev/zero | tr '\\000' x
      printf 'last diagnostic\\n'
      """,
      fn ffmpeg_path, _tmp_dir ->
        assert {output, 0} = Support.run_media_cmd(ffmpeg_path, [])
        assert byte_size(output) == 1024 * 1024
        assert String.ends_with?(output, "last diagnostic\n")
      end
    )
  end

  test "run_media_cmd adds the private Referer only to configured storage inputs" do
    old_s3 = Application.get_env(:mave_core, :s3)

    Application.put_env(:mave_core, :s3,
      access_key_id: "test-key",
      secret_access_key: "test-secret",
      endpoint: "https://s3.test",
      region: "fr-par"
    )

    on_exit(fn -> restore_env(:s3, old_s3) end)
    referer = Storage.ffmpeg_input_referer()

    with_fake_ffmpeg(
      """
      #!/bin/sh
      printf '<%s>\n' "$@"
      """,
      fn ffmpeg_path, _tmp_dir ->
        assert {output, 0} =
                 Support.run_media_cmd(ffmpeg_path, [
                   "-i",
                   "https://s3.test/mave-upload/uploads/video.mp4",
                   "-i",
                   "https://example.com/overlay.png",
                   "output.mp4"
                 ])

        assert output =~
                 "<-headers>\n<Referer: #{referer}\r\n>\n<-protocol_whitelist>\n<file,http,https,tcp,tls,crypto,pipe>\n<-i>\n<https://s3.test/mave-upload/uploads/video.mp4>"

        assert output =~ "<-i>\n<https://example.com/overlay.png>"
        assert length(Regex.scan(~r/<-headers>/, output)) == 1
      end
    )
  end

  test "run_media_cmd adds the private Referer to configured ffprobe inputs" do
    old_upload = Application.get_env(:mave_core, :upload)

    Application.put_env(:mave_core, :upload, source_base_url: "https://uploads.test/storage")

    on_exit(fn -> restore_env(:upload, old_upload) end)
    referer = Storage.ffmpeg_input_referer()

    with_fake_media_tool(
      "ffprobe",
      """
      #!/bin/sh
      printf '<%s>\n' "$@"
      """,
      fn ffprobe_path, _tmp_dir ->
        assert {output, 0} =
                 Support.run_media_cmd(ffprobe_path, [
                   "-show_streams",
                   "https://uploads.test/storage/mave-upload/video.mp4"
                 ])

        assert output =~ "<-headers>\n<Referer: #{referer}\r\n>"
      end
    )
  end

  test "run_media_cmd reports durable ffmpeg performance fields" do
    test_pid = self()

    reporter =
      spawn(fn ->
        receive do
          {:"$gen_cast", {:progress, event}} -> send(test_pid, {:ffmpeg_progress, event})
        end
      end)

    with_fake_ffmpeg(
      """
      #!/bin/sh
      echo "frame=300"
      echo "fps=72.5"
      echo "total_size=1234567"
      echo "out_time_us=10000000"
      echo "dup_frames=2"
      echo "drop_frames=1"
      echo "speed=2.4x"
      echo "progress=end"
      """,
      fn ffmpeg_path, _tmp_dir ->
        assert {output, 0} =
                 Support.run_media_cmd(ffmpeg_path, [],
                   progress: %{
                     reporter: reporter,
                     stage: "transcode",
                     step_id: "video_h264_ladder",
                     codec: "h264",
                     size: "ladder",
                     container: "mp4",
                     variants: ["sd", "hd"],
                     preset: "veryfast",
                     total_ms: 10_000
                   }
                 )

        assert output =~ "progress=end"

        assert_receive {:ffmpeg_progress, event}
        assert event["status"] == "completed"
        assert event["frame"] == 300
        assert event["fps"] == 72.5
        assert event["speed_x"] == 2.4
        assert event["out_time_ms"] == 10_000
        assert event["total_size_bytes"] == 1_234_567
        assert event["dup_frames"] == 2
        assert event["drop_frames"] == 1
        assert event["variants"] == ["sd", "hd"]
        assert event["preset"] == "veryfast"
        assert is_integer(event["ffmpeg_elapsed_ms"])
        assert event["ffmpeg_elapsed_ms"] > 0
      end
    )
  end

  test "run_media_cmd enables ffmpeg progress output when a reporter is configured" do
    with_fake_ffmpeg(
      """
      #!/bin/sh
      printf '%s\n' "$*"
      """,
      fn ffmpeg_path, _tmp_dir ->
        progress = %{reporter: self(), stage: "transcode", step_id: "audio"}

        assert {output, 0} =
                 Support.run_media_cmd(ffmpeg_path, ["-hide_banner"], progress: progress)

        assert output ==
                 "-nostdin -protocol_whitelist file,http,https,tcp,tls,crypto,pipe -nostats -progress pipe:1 -hide_banner\n"

        assert {output, 0} =
                 Support.run_media_cmd(
                   ffmpeg_path,
                   ["-nostats", "-progress", "pipe:1", "-hide_banner"],
                   progress: progress
                 )

        assert output ==
                 "-nostdin -protocol_whitelist file,http,https,tcp,tls,crypto,pipe -nostats -progress pipe:1 -hide_banner\n"
      end
    )
  end

  test "run_media_cmd times out and terminates long-running media commands" do
    Application.put_env(:mave_core, :flow_media_command_timeout_ms, 1_000)

    with_fake_ffmpeg(
      """
      #!/bin/sh
      echo "started"
      trap 'echo "terminated"; exit 0' TERM
      while :; do
        read _line
      done
      """,
      fn ffmpeg_path, _tmp_dir ->
        assert {output, 124} = Support.run_media_cmd(ffmpeg_path, [])
        assert output =~ "started"
        assert output =~ "terminated"
        assert output =~ "media command timed out after 1000 ms"
      end
    )
  end

  test "run_media_cmd accepts per-call timeout overrides" do
    Application.put_env(:mave_core, :flow_media_command_timeout_ms, 60_000)

    with_fake_ffmpeg(
      """
      #!/bin/sh
      echo "started"
      trap 'echo "terminated"; exit 0' TERM
      while :; do
        read _line
      done
      """,
      fn ffmpeg_path, _tmp_dir ->
        assert {output, 124} =
                 Support.run_media_cmd(ffmpeg_path, [], command_timeout_ms: 1_000)

        assert output =~ "started"
        assert output =~ "terminated"
        assert output =~ "media command timed out after 1000 ms"
      end
    )
  end

  test "recognizes ffmpeg partial storage-read errors" do
    assert Support.ffmpeg_storage_read_error?("""
           [mov,mp4,m4a,3gp,3g2,mj2 @ 0x123] stream 0, offset 0x66e: partial file
           Cannot determine format of input 0:0 after EOF
           """)

    refute Support.ffmpeg_storage_read_error?("Unknown encoder 'libdoesnotexist'")
  end

  test "recognizes remote storage availability errors for local fallback" do
    assert Support.ffmpeg_storage_read_error?("Server returned 403 Forbidden")
    assert Support.ffmpeg_storage_read_error?("HTTP error 503 Service Unavailable")
    assert Support.ffmpeg_storage_read_error?("Server returned 5XX Server Error reply")

    assert Support.ffmpeg_storage_read_error?(
             "Server returned 4XX Client Error, but not one of 40{0,1,3,4}"
           )

    assert Support.ffmpeg_storage_read_error?("Connection refused")

    refute Support.ffmpeg_storage_read_error?("Unknown encoder 'libdoesnotexist'")
  end

  test "decodes ffprobe json when diagnostics are emitted before the payload" do
    output = """
    moov atom metadata warning
    {
      "streams": [
        {"codec_type": "video", "codec_name": "h264"}
      ]
    }
    """

    assert {:ok, payload} = Support.decode_probe_output(output)
    assert [%{"codec_type" => "video", "codec_name" => "h264"}] = payload["streams"]
  end

  test "rejects invalid generated media files" do
    if is_nil(System.find_executable("ffprobe")) do
      :ok
    else
      Support.with_temp_dir("support_test", fn tmp_dir ->
        assert {:ok, output_path} = Support.tmp_file_path(tmp_dir, "output", "mp3")
        assert :ok = Support.write_tmp_file(output_path, "not-an-mp3")

        assert {:error, {:invalid_media_output, :audio, _reason}} =
                 Support.validate_media_file(output_path, :audio)
      end)
    end
  end

  test "retries ffmpeg when output validation fails after a zero exit" do
    if is_nil(System.find_executable("ffmpeg")) do
      :ok
    else
      Application.put_env(:mave_core, :flow_storage_adapter, FfmpegUrlStorageAdapter)

      assert {:ok, _body} =
               FlowStorageAdapterStub.put(
                 "mave-upload",
                 "uploads/demo.mp4",
                 "stub-from-storage",
                 "video/mp4",
                 "us-east-1"
               )

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Support.with_temp_dir("support_test", fn tmp_dir ->
        assert {:ok, _output, true} =
                 Support.run_ffmpeg_with_storage_fallback(
                   tmp_dir,
                   %{
                     "source_bucket" => "mave-upload",
                     "source_key" => "uploads/demo.mp4",
                     "source_region" => "us-east-1",
                     "source_content_type" => "video/mp4"
                   },
                   "https://example.com/video.mp4",
                   %{},
                   fn _input_ref -> {:ok, ["-version"]} end,
                   validate_output: fn ->
                     Agent.get_and_update(counter, fn count -> {count, count + 1} end)
                     |> case do
                       0 -> {:error, :invalid_first_output}
                       _ -> :ok
                     end
                   end
                 )
      end)

      assert Agent.get(counter, & &1) == 2
      Agent.stop(counter)
    end
  end

  test "prefers the completed upload object for source body when available" do
    assert {:ok, _body} =
             FlowStorageAdapterStub.put(
               "mave-upload",
               "uploads/demo.mp4",
               "external-source",
               "video/mp4",
               "us-east-1"
             )

    assert {:ok, _body} =
             FlowStorageAdapterStub.put(
               "space-ubg50",
               "LeDE9v86ye/original",
               "our-original",
               "video/mp4",
               "us-east-1"
             )

    run_input = %{
      "region" => "us-east-1",
      "source_bucket" => "mave-upload",
      "source_key" => "uploads/demo.mp4",
      "source_region" => "us-east-1"
    }

    dependency_outputs = %{
      "upload_original" => %{
        "bucket" => "space-ubg50",
        "original_key" => "LeDE9v86ye/original"
      }
    }

    assert {:ok, "external-source"} =
             Support.resolve_source_body(
               run_input,
               "https://example.com/video.mp4",
               dependency_outputs
             )
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)

  defp with_fake_ffmpeg(script, fun) when is_binary(script) and is_function(fun, 2) do
    with_fake_media_tool("ffmpeg", script, fun)
  end

  defp with_fake_media_tool(tool, script, fun)
       when tool in ["ffmpeg", "ffprobe"] and is_binary(script) and is_function(fun, 2) do
    tmp_dir =
      Path.join(System.tmp_dir!(), "mave_fake_#{tool}_#{System.unique_integer([:positive])}")

    tool_path = Path.join(tmp_dir, tool)

    try do
      File.mkdir_p!(tmp_dir)
      File.write!(tool_path, script)
      File.chmod!(tool_path, 0o755)
      fun.(tool_path, tmp_dir)
    after
      File.rm_rf(tmp_dir)
    end
  end
end
