defmodule MaveCore.Flow.Steps.MediaPackageHlsVariantStepTest do
  use ExUnit.Case, async: false

  alias MaveCore.Flow.Steps.MediaPackageHlsVariantStep
  alias MaveCore.Flow.Steps.Support
  alias MaveCore.TestSupport.ConcurrentFlowStorageAdapter
  alias MaveCore.TestSupport.FlowStorageAdapterStub

  defmodule EncodingBoosterAdapterStub do
    @moduledoc false

    def package_hls_to_storage(input_url, _upload_token, options) do
      send(
        Application.fetch_env!(:mave_core, :hls_booster_test_pid),
        {:package_hls, input_url, options}
      )

      size = if String.contains?(input_url, ["h264_sd", "waveform_sd"]), do: "sd", else: "hd"
      prefix = "LeDE9v86ye/h264_#{size}_hls/"

      files = [
        {"init.mp4", "init", "video/mp4"},
        {"playlist.m3u8", "#EXTM3U\n", "application/vnd.apple.mpegurl"},
        {"segment_000.m4s", "segment", "video/mp4"}
      ]

      metadata =
        Enum.map(files, fn {name, body, content_type} ->
          key = prefix <> name

          {:ok, _body} =
            FlowStorageAdapterStub.put(
              "space-ubg50",
              key,
              body,
              content_type,
              nil
            )

          %{
            "name" => name,
            "key" => key,
            "file_size" => byte_size(body),
            "content_type" => content_type
          }
        end)

      {:ok, %{files: metadata, elapsed_ms: 12, instance_id: "cpu-hls-a"}}
    end
  end

  setup do
    old_storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter)
    old_storage_concurrency = Application.get_env(:mave_core, :storage_object_max_concurrency)
    old_upload_barrier = Application.get_env(:mave_core, :test_hls_upload_barrier)
    old_booster_adapter = Application.get_env(:mave_core, :encoding_booster_adapter)
    old_booster_test_pid = Application.get_env(:mave_core, :hls_booster_test_pid)

    Application.put_env(:mave_core, :flow_storage_adapter, FlowStorageAdapterStub)
    FlowStorageAdapterStub.reset!()
    Application.put_env(:mave_core, :hls_booster_test_pid, self())

    on_exit(fn ->
      FlowStorageAdapterStub.reset!()
      restore_env(:flow_storage_adapter, old_storage_adapter)
      restore_env(:storage_object_max_concurrency, old_storage_concurrency)
      restore_env(:test_hls_upload_barrier, old_upload_barrier)
      restore_env(:encoding_booster_adapter, old_booster_adapter)
      restore_env(:hls_booster_test_pid, old_booster_test_pid)
    end)

    :ok
  end

  test "packages the completed rendition on the CPU booster before uploading HLS" do
    Application.put_env(:mave_core, :encoding_booster_adapter, EncodingBoosterAdapterStub)

    step_definition = %{
      "id" => "hls_h264_hd",
      "type" => "media.package_hls_variant",
      "params" => %{
        "codec" => "h264",
        "size" => "hd",
        "source_step_id" => "video_h264_hd",
        "strict" => true
      }
    }

    context = %{
      encoding_booster_dispatch: :direct,
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "version" => 0
      },
      dependency_outputs: %{
        "video_h264_hd" => %{
          "step_type" => "media.transcode_video",
          "status" => "ok",
          "bucket" => "space-ubg50",
          "key" => "LeDE9v86ye/h264_hd.mp4",
          "uri" => "https://cdn.example/LeDE9v86ye/h264_hd.mp4",
          "codec" => "h264",
          "container" => "mp4",
          "size" => "hd",
          "resolution" => "1280x720"
        }
      }
    }

    assert {:ok, output, artifacts} = MediaPackageHlsVariantStep.run(step_definition, context)
    assert output["status"] == "ok"
    assert output["mode"] == "encoding_booster"
    assert output["encoding_booster_elapsed_ms"] == 12
    assert output["encoding_booster_instance"] == "cpu-hls-a"
    assert output["playlist_key"] == "LeDE9v86ye/h264_hd_hls/playlist.m3u8"
    assert [%{name: "h264_hd_hls_playlist"}] = artifacts

    assert_received {:package_hls, input_url, []}
    assert input_url =~ "https://storage.example/space-ubg50/LeDE9v86ye/h264_hd.mp4"
  end

  test "packages an explicitly selected waveform on the booster without advertising silent playback" do
    Application.put_env(:mave_core, :encoding_booster_adapter, EncodingBoosterAdapterStub)

    step = %{
      "id" => "hls_waveform_sd",
      "params" => %{
        "source_step_id" => "transcode_waveform",
        "audio_only" => true,
        "strict" => true
      }
    }

    context = %{
      encoding_booster_dispatch: :direct,
      run_input: %{"space_hash" => "ubg50", "embed_hash" => "LeDE9v86ye"},
      dependency_outputs: %{
        "inspect_media" => %{"has_audio" => true, "has_video" => false},
        "transcode_waveform" => %{
          "step_type" => "media.transcode_waveform",
          "status" => "ok",
          "bucket" => "space-ubg50",
          "key" => "LeDE9v86ye/waveform_sd.mp4",
          "codec" => "h264",
          "size" => "sd",
          "resolution" => "640x360"
        }
      }
    }

    assert {:ok, output, [_]} = MediaPackageHlsVariantStep.run(step, context)
    assert output["status"] == "ok"
    assert output["resolution"] == "640x360"
    assert output["renditions"] == []
    assert output["rendition"] == nil
    assert output["waveform_rendition"]["container"] == "hls"
    assert_received {:package_hls, input_url, []}
    assert input_url =~ "space-ubg50/LeDE9v86ye/waveform_sd.mp4"

    context = put_in(context, [:dependency_outputs, "inspect_media", "has_video"], true)
    assert {:ok, skipped, []} = MediaPackageHlsVariantStep.run(step, context)
    assert skipped["status"] == "skipped"
    assert skipped["reason"] == "source has video"
    refute_received {:package_hls, _, _}
  end

  test "verifies every object published directly by the booster" do
    Application.put_env(:mave_core, :encoding_booster_adapter, EncodingBoosterAdapterStub)

    step_definition = %{
      "id" => "hls_h264_sd",
      "type" => "media.package_hls_variant",
      "params" => %{
        "codec" => "h264",
        "size" => "sd",
        "source_step_id" => "video_h264_sd",
        "strict" => true
      }
    }

    context = %{
      encoding_booster_dispatch: :direct,
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "version" => 0
      },
      dependency_outputs: %{
        "video_h264_sd" => %{
          "status" => "ok",
          "step_type" => "media.transcode_video",
          "bucket" => "space-ubg50",
          "key" => "LeDE9v86ye/h264_sd.mp4",
          "uri" => "https://cdn.example/LeDE9v86ye/h264_sd.mp4",
          "codec" => "h264",
          "container" => "mp4",
          "size" => "sd",
          "resolution" => "640x360"
        }
      }
    }

    assert {:ok, output, artifacts} = MediaPackageHlsVariantStep.run(step_definition, context)
    assert output["status"] == "ok"
    assert output["segment_count"] == 1
    assert [%{name: "h264_sd_hls_playlist"}] = artifacts

    assert {:ok, "segment"} =
             FlowStorageAdapterStub.get(
               "space-ubg50",
               "LeDE9v86ye/h264_sd_hls/segment_000.m4s",
               nil
             )
  end

  test "uploads independent hls files concurrently in deterministic order" do
    ffmpeg_bin = System.find_executable("ffmpeg")

    if is_nil(ffmpeg_bin) do
      assert true
    else
      Support.with_temp_dir("hls_concurrent_test", fn tmp_dir ->
        input_path = Path.join(tmp_dir, "input.mp4")

        {_output, 0} =
          System.cmd(
            ffmpeg_bin,
            [
              "-y",
              "-f",
              "lavfi",
              "-i",
              "testsrc=duration=1:size=640x360:rate=24",
              "-pix_fmt",
              "yuv420p",
              input_path
            ],
            stderr_to_stdout: true
          )

        barrier =
          start_supervised!(
            {ConcurrentFlowStorageAdapter,
             owner: self(), threshold: 2, id: ConcurrentFlowStorageAdapter}
          )

        Application.put_env(:mave_core, :flow_storage_adapter, ConcurrentFlowStorageAdapter)
        Application.put_env(:mave_core, :storage_object_max_concurrency, 2)
        Application.put_env(:mave_core, :test_hls_upload_barrier, barrier)

        assert {:ok, output} =
                 MediaPackageHlsVariantStep.package_local_variant(%{
                   storage_adapter: ConcurrentFlowStorageAdapter,
                   input_path: input_path,
                   bucket: "space-ubg50",
                   embed_hash: "LeDE9v86ye",
                   version: 0,
                   codec: "h264",
                   size: "sd",
                   region: nil,
                   tmp_dir: tmp_dir,
                   hls_dir_basename: "hls_concurrent",
                   step_id: "hls_h264_sd"
                 })

        assert_receive {:hls_upload_batch_started, 2}

        file_names = Enum.map(output["files"], & &1["name"])
        assert file_names == Enum.sort(file_names)
        assert length(file_names) >= 3
      end)
    end
  end

  test "packages a transcoded video object into hls files" do
    ffmpeg_bin = System.find_executable("ffmpeg")

    if is_nil(ffmpeg_bin) do
      assert true
    else
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "mave_hls_variant_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      input_path = Path.join(tmp_dir, "input.mp4")

      {_output, 0} =
        System.cmd(
          ffmpeg_bin,
          [
            "-y",
            "-f",
            "lavfi",
            "-i",
            "testsrc=duration=2:size=640x360:rate=30",
            "-pix_fmt",
            "yuv420p",
            input_path
          ],
          stderr_to_stdout: true
        )

      body = File.read!(input_path)

      assert {:ok, _} =
               FlowStorageAdapterStub.put(
                 "space-ubg50",
                 "LeDE9v86ye/h264_sd.mp4",
                 body,
                 "video/mp4",
                 nil
               )

      step_definition = %{
        "id" => "hls_h264_sd",
        "type" => "media.package_hls_variant",
        "params" => %{"codec" => "h264", "size" => "sd", "source_step_id" => "video_h264_sd"}
      }

      context = %{
        run_input: %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "version" => 0
        },
        dependency_outputs: %{
          "video_h264_sd" => %{
            "step_type" => "media.transcode_video",
            "status" => "ok",
            "bucket" => "space-ubg50",
            "key" => "LeDE9v86ye/h264_sd.mp4",
            "codec" => "h264",
            "size" => "sd"
          }
        }
      }

      assert {:ok, output, artifacts} = MediaPackageHlsVariantStep.run(step_definition, context)
      assert output["status"] == "ok"
      assert output["step_type"] == "media.package_hls_variant"
      assert output["playlist_key"] == "LeDE9v86ye/h264_sd_hls/playlist.m3u8"
      assert output["playlist_uri"] == "s3://space-ubg50/LeDE9v86ye/h264_sd_hls/playlist.m3u8"
      assert output["playlist_path"] == "h264_sd_hls/playlist.m3u8"
      assert output["resolution"] == "640x360"
      assert output["segment_count"] > 0
      assert is_list(output["files"])
      assert Enum.any?(output["files"], &(&1["name"] == "playlist.m3u8"))
      assert Enum.any?(output["files"], &(&1["name"] == "init.mp4"))
      assert Enum.any?(output["files"], &String.ends_with?(&1["name"], ".m4s"))
      assert [%{name: "h264_sd_hls_playlist"}] = artifacts

      assert {:ok, playlist_body} =
               FlowStorageAdapterStub.get(
                 "space-ubg50",
                 "LeDE9v86ye/h264_sd_hls/playlist.m3u8",
                 nil
               )

      assert String.contains?(playlist_body, "#EXTM3U")

      _ = File.rm_rf(tmp_dir)
    end
  end

  test "returns unavailable output in non-strict mode when no source rendition is available" do
    step_definition = %{
      "id" => "hls_h264_sd",
      "type" => "media.package_hls_variant",
      "params" => %{"codec" => "h264", "size" => "sd"}
    }

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye"
      },
      dependency_outputs: %{}
    }

    assert {:ok, output, []} = MediaPackageHlsVariantStep.run(step_definition, context)
    assert output["status"] == "unavailable"
    assert output["step_type"] == "media.package_hls_variant"
  end

  test "packages a selected variant from a h264 ladder output" do
    ffmpeg_bin = System.find_executable("ffmpeg")

    if is_nil(ffmpeg_bin) do
      assert true
    else
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "mave_hls_ladder_variant_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      input_path = Path.join(tmp_dir, "input.mp4")

      {_output, 0} =
        System.cmd(
          ffmpeg_bin,
          [
            "-y",
            "-f",
            "lavfi",
            "-i",
            "testsrc=duration=2:size=1280x720:rate=30",
            "-pix_fmt",
            "yuv420p",
            input_path
          ],
          stderr_to_stdout: true
        )

      body = File.read!(input_path)

      assert {:ok, _} =
               FlowStorageAdapterStub.put(
                 "space-ubg50",
                 "LeDE9v86ye/h264_hd.mp4",
                 body,
                 "video/mp4",
                 nil
               )

      step_definition = %{
        "id" => "hls_h264_hd",
        "type" => "media.package_hls_variant",
        "params" => %{
          "codec" => "h264",
          "size" => "hd",
          "source_step_id" => "video_h264_ladder"
        }
      }

      context = %{
        run_input: %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "version" => 0
        },
        dependency_outputs: %{
          "video_h264_ladder" => %{
            "step_type" => "media.transcode_h264_ladder",
            "status" => "ok",
            "bucket" => "space-ubg50",
            "variant_outputs" => %{
              "sd" => %{
                "codec" => "h264",
                "size" => "sd",
                "bucket" => "space-ubg50",
                "key" => "LeDE9v86ye/h264_sd.mp4"
              },
              "hd" => %{
                "codec" => "h264",
                "size" => "hd",
                "bucket" => "space-ubg50",
                "key" => "LeDE9v86ye/h264_hd.mp4"
              }
            }
          }
        }
      }

      assert {:ok, output, artifacts} = MediaPackageHlsVariantStep.run(step_definition, context)
      assert output["status"] == "ok"
      assert output["playlist_key"] == "LeDE9v86ye/h264_hd_hls/playlist.m3u8"
      assert output["playlist_path"] == "h264_hd_hls/playlist.m3u8"
      assert output["resolution"] == "1280x720"
      assert [%{name: "h264_hd_hls_playlist"}] = artifacts

      assert {:ok, playlist_body} =
               FlowStorageAdapterStub.get(
                 "space-ubg50",
                 "LeDE9v86ye/h264_hd_hls/playlist.m3u8",
                 nil
               )

      assert String.contains?(playlist_body, "#EXTM3U")

      _ = File.rm_rf(tmp_dir)
    end
  end

  test "reuses prepackaged hls output from a h264 ladder variant" do
    step_definition = %{
      "id" => "hls_h264_sd",
      "type" => "media.package_hls_variant",
      "params" => %{
        "codec" => "h264",
        "size" => "sd",
        "source_step_id" => "video_h264_ladder"
      }
    }

    hls_output = %{
      "status" => "ok",
      "step_type" => "media.package_hls_variant",
      "step_id" => "hls_h264_sd",
      "codec" => "h264",
      "size" => "sd",
      "container" => "hls",
      "bucket" => "space-ubg50",
      "variant_dir" => "h264_sd_hls",
      "playlist_key" => "LeDE9v86ye/h264_sd_hls/playlist.m3u8",
      "playlist_uri" => "s3://space-ubg50/LeDE9v86ye/h264_sd_hls/playlist.m3u8",
      "playlist_path" => "h264_sd_hls/playlist.m3u8",
      "files" => [
        %{
          "name" => "playlist.m3u8",
          "key" => "LeDE9v86ye/h264_sd_hls/playlist.m3u8",
          "uri" => "s3://space-ubg50/LeDE9v86ye/h264_sd_hls/playlist.m3u8",
          "file_size" => 100,
          "content_type" => "application/vnd.apple.mpegurl"
        }
      ],
      "segment_count" => 1,
      "file_size" => 100,
      "rendition" => %{
        "type" => "video",
        "size" => "sd",
        "codec" => "h264",
        "container" => "hls",
        "progress" => 100.0,
        "rendition_key" => "LeDE9v86ye/h264_sd_hls/playlist.m3u8",
        "src" => "s3://space-ubg50/LeDE9v86ye/h264_sd_hls/playlist.m3u8",
        "file_size" => 100
      }
    }

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "version" => 0
      },
      dependency_outputs: %{
        "video_h264_ladder" => %{
          "step_type" => "media.transcode_h264_ladder",
          "status" => "ok",
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "version" => 0,
          "bucket" => "space-ubg50",
          "variant_outputs" => %{
            "sd" => %{
              "codec" => "h264",
              "size" => "sd",
              "bucket" => "space-ubg50",
              "hls" => hls_output
            }
          }
        }
      }
    }

    assert {:ok, output, artifacts} = MediaPackageHlsVariantStep.run(step_definition, context)
    assert output["status"] == "ok"
    assert output["mode"] == "prepackaged"
    assert output["prepackaged"] == true
    assert output["playlist_key"] == "LeDE9v86ye/h264_sd_hls/playlist.m3u8"
    assert [%{name: "h264_sd_hls_playlist", size_bytes: 100}] = artifacts
  end

  test "returns skipped output when selected ladder variant was skipped" do
    step_definition = %{
      "id" => "hls_h264_uhd",
      "type" => "media.package_hls_variant",
      "params" => %{
        "codec" => "h264",
        "size" => "uhd",
        "source_step_id" => "video_h264_ladder",
        "strict" => true
      }
    }

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "version" => 0
      },
      dependency_outputs: %{
        "video_h264_ladder" => %{
          "step_type" => "media.transcode_h264_ladder",
          "status" => "ok",
          "bucket" => "space-ubg50",
          "variant_outputs" => %{
            "uhd" => %{
              "status" => "skipped",
              "step_type" => "media.transcode_h264_ladder",
              "codec" => "h264",
              "size" => "uhd",
              "reason" => "source_resolution_below_variant"
            }
          }
        }
      }
    }

    assert {:ok, output, []} = MediaPackageHlsVariantStep.run(step_definition, context)
    assert output["status"] == "skipped"
    assert output["reason"] == "source_resolution_below_variant"
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)
end
