defmodule MaveCore.Flow.Steps.MediaPackageHlsAudioStepTest do
  use ExUnit.Case, async: false

  alias MaveCore.Flow.Steps.MediaPackageHlsAudioStep
  alias MaveCore.TestSupport.FlowStorageAdapterStub

  defmodule EncodingBoosterAdapterStub do
    def package_hls_to_storage(input_url, _token, options) do
      send(Application.fetch_env!(:mave_core, :encoding_booster_test_pid), {
        :hls_audio_booster_request,
        input_url,
        options
      })

      files = [
        {"playlist.m3u8", "#EXTM3U\n", "application/vnd.apple.mpegurl"},
        {"init.mp4", "audio-init", "audio/mp4"},
        {"segment_000.m4s", "audio-segment", "audio/mp4"}
      ]

      uploaded =
        Enum.map(files, fn {name, body, content_type} ->
          key = "audio12345/v1/audio_hls/#{name}"

          {:ok, _body} =
            FlowStorageAdapterStub.put_public(
              "space-qingb",
              key,
              body,
              content_type,
              "qingb"
            )

          %{
            "name" => name,
            "key" => key,
            "file_size" => byte_size(body),
            "content_type" => content_type
          }
        end)

      {:ok,
       %{
         files: uploaded,
         elapsed_ms: 30,
         ffmpeg_elapsed_ms: 20,
         instance_id: "hls-audio-instance"
       }}
    end
  end

  setup do
    old_storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter)
    old_booster_adapter = Application.get_env(:mave_core, :encoding_booster_adapter)
    old_booster_pid = Application.get_env(:mave_core, :encoding_booster_test_pid)

    Application.put_env(:mave_core, :flow_storage_adapter, FlowStorageAdapterStub)
    Application.put_env(:mave_core, :encoding_booster_adapter, EncodingBoosterAdapterStub)
    Application.put_env(:mave_core, :encoding_booster_test_pid, self())
    FlowStorageAdapterStub.reset!()

    on_exit(fn ->
      FlowStorageAdapterStub.reset!()
      restore_env(:flow_storage_adapter, old_storage_adapter)
      restore_env(:encoding_booster_adapter, old_booster_adapter)
      restore_env(:encoding_booster_test_pid, old_booster_pid)
    end)

    :ok
  end

  test "packages audio HLS through the CPU booster directly into object storage" do
    assert {:ok, _body} =
             FlowStorageAdapterStub.put_public(
               "space-qingb",
               "audio12345/v1/audio.mp3",
               "audio-source",
               "audio/mpeg",
               "qingb"
             )

    step_definition = %{
      "id" => "hls_audio_default",
      "type" => "media.package_hls_audio",
      "params" => %{"source_step_id" => "transcode_audio", "strict" => true}
    }

    context = %{
      run_input: %{
        "space_hash" => "qingb",
        "embed_hash" => "audio12345",
        "version" => 1,
        "region" => "qingb"
      },
      dependency_outputs: %{
        "source" => %{"space_hash" => "qingb", "embed_hash" => "audio12345"},
        "inspect_media" => %{"duration" => 10.0},
        "transcode_audio" => %{
          "step_type" => "media.transcode_audio",
          "status" => "ok",
          "bucket" => "space-qingb",
          "key" => "audio12345/v1/audio.mp3",
          "uri" => "s3://space-qingb/audio12345/v1/audio.mp3",
          "audio_track" => %{
            "id" => "default",
            "label" => "Original",
            "default" => true,
            "filename" => "audio.mp3",
            "src" => "s3://space-qingb/audio12345/v1/audio.mp3"
          }
        }
      },
      encoding_booster_dispatch: :direct,
      progress_reporter: self()
    }

    assert {:ok, output, [_artifact]} =
             MediaPackageHlsAudioStep.run(step_definition, context)

    assert output["mode"] == "encoding_booster"
    assert output["playlist_key"] == "audio12345/v1/audio_hls/playlist.m3u8"
    assert output["segment_count"] == 1
    assert output["encoding_booster_instance"] == "hls-audio-instance"

    assert_receive {:"$gen_cast",
                    {:progress,
                     %{
                       "executor" => "encoding_booster",
                       "status" => "completed",
                       "step_id" => "hls_audio_default",
                       "total_size_bytes" => total_size_bytes
                     }}}

    assert total_size_bytes == output["file_size"]

    assert_receive {:hls_audio_booster_request, input_url, options}
    assert input_url =~ "audio12345/v1/audio.mp3"
    assert options[:media_kind] == "audio"
    assert options[:channels] == 2
  end

  test "packages a transcoded audio object into hls files" do
    ffmpeg_bin = System.find_executable("ffmpeg")

    if is_nil(ffmpeg_bin) do
      assert true
    else
      tmp_dir =
        Path.join(System.tmp_dir!(), "mave_hls_audio_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      input_path = Path.join(tmp_dir, "input.mp3")

      {_output, 0} =
        System.cmd(
          ffmpeg_bin,
          [
            "-y",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=1000:duration=2",
            "-codec:a",
            "libmp3lame",
            "-b:a",
            "128k",
            input_path
          ],
          stderr_to_stdout: true
        )

      body = File.read!(input_path)

      assert {:ok, _} =
               FlowStorageAdapterStub.put(
                 "space-ubg50",
                 "LeDE9v86ye/audio.mp3",
                 body,
                 "audio/mpeg",
                 nil
               )

      step_definition = %{
        "id" => "hls_audio_default",
        "type" => "media.package_hls_audio",
        "params" => %{"source_step_id" => "transcode_audio"}
      }

      context = %{
        run_input: %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "version" => 0
        },
        dependency_outputs: %{
          "transcode_audio" => %{
            "step_type" => "media.transcode_audio",
            "status" => "ok",
            "bucket" => "space-ubg50",
            "key" => "LeDE9v86ye/audio.mp3",
            "uri" => "s3://space-ubg50/LeDE9v86ye/audio.mp3",
            "audio_track" => %{
              "id" => "default",
              "label" => "Original",
              "language" => "en",
              "default" => true,
              "filename" => "audio.mp3",
              "src" => "s3://space-ubg50/LeDE9v86ye/audio.mp3"
            }
          }
        }
      }

      assert {:ok, output, artifacts} = MediaPackageHlsAudioStep.run(step_definition, context)
      assert output["status"] == "ok"
      assert output["step_type"] == "media.package_hls_audio"
      assert output["playlist_key"] == "LeDE9v86ye/audio_hls/playlist.m3u8"
      assert output["playlist_path"] == "audio_hls/playlist.m3u8"
      assert output["segment_count"] > 0
      assert length(output["audio_tracks"]) == 1
      assert length(output["renditions"]) == 1
      assert output["audio_track"]["hls_playlist"] == "audio_hls/playlist.m3u8"
      assert output["audio_track"]["hls_group_id"] == "audio"
      assert output["audio_track"]["hls_codec"] == "aac"
      assert [%{name: "audio_hls_playlist"}] = artifacts

      assert {:ok, playlist_body} =
               FlowStorageAdapterStub.get(
                 "space-ubg50",
                 "LeDE9v86ye/audio_hls/playlist.m3u8",
                 nil
               )

      assert String.contains?(playlist_body, "#EXTM3U")
      _ = File.rm_rf(tmp_dir)
    end
  end

  test "the native audio decoder refuses a playlist disguised as an audio object" do
    if System.find_executable("ffmpeg") do
      body = "ffconcat version 1.0\nfile 'http://127.0.0.1:9/never-fetch'\n"

      assert {:ok, _} =
               FlowStorageAdapterStub.put("space-ubg50", "audio.mp3", body, "audio/mpeg", nil)

      step = %{
        "id" => "hls_audio_default",
        "type" => "media.package_hls_audio",
        "params" => %{"source_step_id" => "transcode_audio", "strict" => true}
      }

      context = %{
        run_input: %{"space_hash" => "ubg50", "embed_hash" => "LeDE9v86ye"},
        dependency_outputs: %{
          "transcode_audio" => %{
            "status" => "ok",
            "bucket" => "space-ubg50",
            "key" => "audio.mp3",
            "uri" => "s3://space-ubg50/audio.mp3",
            "audio_track" => %{"id" => "default", "filename" => "audio.mp3"}
          }
        }
      }

      assert {:error, reason} = MediaPackageHlsAudioStep.run(step, context)
      assert inspect(reason) =~ "not on whitelist"
    end
  end

  test "packages multiple transcoded audio tracks into separate hls playlists" do
    ffmpeg_bin = System.find_executable("ffmpeg")

    if is_nil(ffmpeg_bin) do
      assert true
    else
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "mave_hls_audio_multi_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      input_a = Path.join(tmp_dir, "audio.mp3")
      input_b = Path.join(tmp_dir, "track_2_mp3.mp3")

      for {path, frequency} <- [{input_a, 1000}, {input_b, 500}] do
        {_output, 0} =
          System.cmd(
            ffmpeg_bin,
            [
              "-y",
              "-f",
              "lavfi",
              "-i",
              "sine=frequency=#{frequency}:duration=2",
              "-codec:a",
              "libmp3lame",
              "-b:a",
              "128k",
              path
            ],
            stderr_to_stdout: true
          )
      end

      assert {:ok, _} =
               FlowStorageAdapterStub.put(
                 "space-ubg50",
                 "LeDE9v86ye/audio.mp3",
                 File.read!(input_a),
                 "audio/mpeg",
                 nil
               )

      assert {:ok, _} =
               FlowStorageAdapterStub.put(
                 "space-ubg50",
                 "LeDE9v86ye/track_2_mp3.mp3",
                 File.read!(input_b),
                 "audio/mpeg",
                 nil
               )

      step_definition = %{
        "id" => "hls_audio_default",
        "type" => "media.package_hls_audio",
        "params" => %{"source_step_id" => "transcode_audio"}
      }

      context = %{
        run_input: %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "version" => 0
        },
        dependency_outputs: %{
          "transcode_audio" => %{
            "step_type" => "media.transcode_audio",
            "status" => "ok",
            "audio_track" => %{
              "id" => "default",
              "label" => "Original",
              "language" => "en",
              "default" => true,
              "filename" => "audio.mp3",
              "src" => "s3://space-ubg50/LeDE9v86ye/audio.mp3"
            },
            "audio_tracks" => [
              %{
                "id" => "default",
                "label" => "Original",
                "language" => "en",
                "default" => true,
                "filename" => "audio.mp3",
                "src" => "s3://space-ubg50/LeDE9v86ye/audio.mp3"
              },
              %{
                "id" => "track_2",
                "label" => "Dutch",
                "language" => "nl",
                "default" => false,
                "filename" => "track_2_mp3.mp3",
                "src" => "s3://space-ubg50/LeDE9v86ye/track_2_mp3.mp3"
              }
            ]
          }
        }
      }

      assert {:ok, output, artifacts} = MediaPackageHlsAudioStep.run(step_definition, context)
      assert length(output["audio_tracks"]) == 2
      assert length(output["renditions"]) == 2
      assert length(artifacts) == 2

      assert Enum.any?(output["audio_tracks"], &(&1["hls_playlist"] == "audio_hls/playlist.m3u8"))

      assert Enum.any?(
               output["audio_tracks"],
               &(&1["hls_playlist"] == "track_2_mp3_hls/playlist.m3u8")
             )

      _ = File.rm_rf(tmp_dir)
    end
  end

  test "returns skipped output when source audio step was skipped" do
    step_definition = %{
      "id" => "hls_audio_default",
      "type" => "media.package_hls_audio",
      "params" => %{"source_step_id" => "transcode_audio"}
    }

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye"
      },
      dependency_outputs: %{
        "transcode_audio" => %{
          "step_type" => "media.transcode_audio",
          "status" => "skipped"
        }
      }
    }

    assert {:ok, output, []} = MediaPackageHlsAudioStep.run(step_definition, context)
    assert output["status"] == "skipped"
    assert output["reason"] == "skipped"
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)
end
