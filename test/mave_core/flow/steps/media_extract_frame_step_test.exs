defmodule MaveCore.Flow.Steps.MediaExtractFrameStepTest do
  use ExUnit.Case, async: false

  alias MaveCore.Flow.Steps.MediaExtractFrameStep
  alias MaveCore.TestSupport.FlowStorageAdapterStub

  defmodule EncodingBoosterAdapterStub do
    def encode_to_storage(input_url, upload, options) do
      send(Application.fetch_env!(:mave_core, :encoding_booster_test_pid), {
        :frame_booster_request,
        input_url,
        options
      })

      {:ok, _body} =
        FlowStorageAdapterStub.put_public(
          upload["test_bucket"],
          upload["test_path"],
          "boosted-frame",
          upload["test_content_type"],
          upload["test_region"]
        )

      {:ok, %{elapsed_ms: 15, ffmpeg_elapsed_ms: 10, instance_id: "frame-instance"}}
    end
  end

  setup do
    old_storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter)
    old_booster_adapter = Application.get_env(:mave_core, :encoding_booster_adapter)
    old_booster_pid = Application.get_env(:mave_core, :encoding_booster_test_pid)

    Application.put_env(
      :mave_core,
      :flow_storage_adapter,
      FlowStorageAdapterStub
    )

    FlowStorageAdapterStub.reset!()
    Application.put_env(:mave_core, :encoding_booster_adapter, EncodingBoosterAdapterStub)
    Application.put_env(:mave_core, :encoding_booster_test_pid, self())

    on_exit(fn ->
      FlowStorageAdapterStub.reset!()
      restore_env(:flow_storage_adapter, old_storage_adapter)
      restore_env(:encoding_booster_adapter, old_booster_adapter)
      restore_env(:encoding_booster_test_pid, old_booster_pid)
    end)

    :ok
  end

  test "streams required frame extraction through the CPU booster into object storage" do
    step_definition = %{
      "id" => "thumbnail_frame",
      "type" => "media.extract_frame",
      "params" => %{"role" => "thumbnail", "codec" => "jpg", "strict" => true}
    }

    context = %{
      run_input: %{
        "space_hash" => "qingb",
        "embed_hash" => "frame12345",
        "source_bucket" => "mave-upload",
        "source_key" => "qingb/source.mp4",
        "source_region" => "qingb",
        "version" => 1
      },
      dependency_outputs: %{
        "source" => %{
          "space_hash" => "qingb",
          "embed_hash" => "frame12345",
          "source_url" => "https://storage.example/mave-upload/qingb/source.mp4",
          "version" => 1
        }
      },
      encoding_booster_dispatch: :direct
    }

    assert {:ok, output, [_artifact]} = MediaExtractFrameStep.run(step_definition, context)
    assert output["mode"] == "encoding_booster"
    assert output["key"] == "frame12345/v1/thumbnail.jpg"
    assert output["file_size"] == byte_size("boosted-frame")
    assert output["encoding_booster_instances"] == ["frame-instance"]

    assert_receive {:frame_booster_request, input_url, options}
    assert input_url =~ "mave-upload/qingb/source.mp4"
    assert options[:operation] == "frame"
    assert options[:frame_role] == "thumbnail"
    assert options[:start_seconds] == 0.0
    assert options[:frame_codec] == "jpg"
  end

  test "waveform frame selection stays within subsecond audio and honors an explicit time" do
    context =
      put_in(audio_waveform_context(), [:dependency_outputs, "inspect_media", "duration"], 0.2)

    assert {:ok, _, _} = MediaExtractFrameStep.run(audio_thumbnail_step(), context)
    assert_receive {:frame_booster_request, _, options}
    assert options[:start_seconds] == 0.1

    step = put_in(audio_thumbnail_step(), ["params", "at_seconds"], 0.05)
    assert {:ok, _, _} = MediaExtractFrameStep.run(step, context)
    assert_receive {:frame_booster_request, _, options}
    assert options[:start_seconds] == 0.05
    assert options[:frame_codec] == "jpg"
  end

  test "streams a background frame conversion from its completed JPEG through the CPU booster" do
    step_definition = %{
      "id" => "poster_frame_webp",
      "type" => "media.extract_frame",
      "params" => %{
        "role" => "poster",
        "codec" => "webp",
        "source_step_id" => "poster_frame",
        "strict" => true
      }
    }

    context = %{
      run_input: %{
        "space_hash" => "qingb",
        "embed_hash" => "frame12345",
        "source_bucket" => "mave-upload",
        "source_key" => "qingb/source.mp4",
        "source_region" => "qingb",
        "version" => 1
      },
      dependency_outputs: %{
        "source" => %{
          "space_hash" => "qingb",
          "embed_hash" => "frame12345",
          "source_url" => "https://storage.example/mave-upload/qingb/source.mp4",
          "version" => 1
        },
        "inspect_media" => %{"has_video" => true},
        "poster_frame" => %{
          "status" => "ok",
          "step_type" => "media.extract_frame",
          "bucket" => "space-qingb",
          "region" => "qingb",
          "key" => "frame12345/v1/poster.jpg",
          "uri" => "s3://space-qingb/frame12345/v1/poster.jpg"
        }
      },
      encoding_booster_dispatch: :direct
    }

    assert {:ok, output, [_artifact]} = MediaExtractFrameStep.run(step_definition, context)
    assert output["mode"] == "encoding_booster"
    assert output["key"] == "frame12345/v1/poster.webp"

    assert_receive {:frame_booster_request, input_url, options}
    assert input_url =~ "space-qingb/frame12345/v1/poster.jpg"
    refute input_url =~ "mave-upload"
    assert options[:frame_codec] == "webp"
  end

  test "produces frame artifact from source_body copy mode" do
    step_definition = %{
      "id" => "poster_frame",
      "type" => "media.extract_frame",
      "params" => %{"role" => "poster", "codec" => "jpg"}
    }

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "source_body" => "stub-media-body",
        "version" => 0
      },
      dependency_outputs: %{
        "source" => %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "source_url" => "https://example.com/video.mp4",
          "version" => 0
        }
      }
    }

    assert {:ok, output, artifacts} = MediaExtractFrameStep.run(step_definition, context)
    assert output["status"] == "ok"
    assert output["mode"] == "copy"
    assert output["role"] == "poster"
    assert output["codec"] == "jpg"
    assert output["key"] == "LeDE9v86ye/poster.jpg"
    assert output["uri"] == "s3://space-ubg50/LeDE9v86ye/poster.jpg"
    assert output["src"] == "s3://space-ubg50/LeDE9v86ye/poster.jpg"
    assert output["poster_image_src"] == "s3://space-ubg50/LeDE9v86ye/poster.jpg"
    assert output["file_size"] == 15
    assert output["rendition"]["type"] == "image"
    assert output["rendition"]["role"] == "poster"
    assert output["rendition"]["progress"] == 100.0
    assert output["rendition"]["rendition_key"] == "LeDE9v86ye/poster.jpg"
    assert is_list(output["renditions"])
    assert hd(output["renditions"])["type"] == "image"

    assert [%{name: "poster_frame", uri: uri, media_type: "image/jpeg"}] = artifacts
    assert uri == "s3://space-ubg50/LeDE9v86ye/poster.jpg"
  end

  test "extracts audio thumbnails from the completed waveform through the booster" do
    step = audio_thumbnail_step()
    context = audio_waveform_context()

    assert {:ok, output, [_artifact]} = MediaExtractFrameStep.run(step, context)
    assert output["key"] == "frame12345/v1/thumbnail.jpg"
    assert output["mode"] == "encoding_booster"

    assert_receive {:frame_booster_request, input_url, options}
    assert input_url =~ "space-qingb/frame12345/v1/waveform_sd.mp4"
    refute input_url =~ "mave-upload"
    assert options[:operation] == "frame"
    assert options[:frame_role] == "thumbnail"
    assert options[:start_seconds] == 5.0
  end

  test "skips audio thumbnails when waveform generation did not produce a source" do
    for waveform <- [nil, %{"status" => "skipped"}, %{"status" => "unavailable"}] do
      context =
        put_in(audio_waveform_context(), [:dependency_outputs, "transcode_waveform"], waveform)

      assert {:ok, %{"status" => "skipped"}, []} =
               MediaExtractFrameStep.run(audio_thumbnail_step(), context)

      refute_receive {:frame_booster_request, _, _}
    end
  end

  test "audio waveform images do not replace normal video thumbnails" do
    context =
      put_in(audio_waveform_context(), [:dependency_outputs, "inspect_media", "has_video"], true)

    assert {:ok, %{"status" => "skipped", "reason" => "source has video"}, []} =
             MediaExtractFrameStep.run(audio_thumbnail_step(), context)

    refute_receive {:frame_booster_request, _, _}
  end

  defp audio_thumbnail_step do
    %{
      "id" => "audio_thumbnail_frame",
      "type" => "media.extract_frame",
      "params" => %{
        "role" => "thumbnail",
        "codec" => "jpg",
        "source_step_id" => "transcode_waveform",
        "audio_only" => true,
        "at_fraction" => 0.5,
        "strict" => true
      }
    }
  end

  defp audio_waveform_context do
    %{
      run_input: %{
        "space_hash" => "qingb",
        "embed_hash" => "frame12345",
        "input_url" => "https://storage.example/mave-upload/audio.mp3",
        "source_bucket" => "mave-upload",
        "source_key" => "audio.mp3",
        "version" => 1
      },
      dependency_outputs: %{
        "inspect_media" => %{"has_video" => false, "has_audio" => true, "duration" => 10.0},
        "transcode_waveform" => %{
          "status" => "ok",
          "step_type" => "media.transcode_waveform",
          "bucket" => "space-qingb",
          "key" => "frame12345/v1/waveform_sd.mp4",
          "uri" => "s3://space-qingb/frame12345/v1/waveform_sd.mp4"
        }
      },
      encoding_booster_dispatch: :direct
    }
  end

  test "the native custom thumbnail decoder refuses nested-fetch formats" do
    if System.find_executable("ffmpeg") do
      step = %{
        "id" => "custom_thumbnail_jpg",
        "type" => "media.extract_frame",
        "params" => %{"role" => "custom_thumbnail", "codec" => "jpg", "strict" => true}
      }

      for {extension, body} <- [
            {"ffconcat", "ffconcat version 1.0\nfile 'http://127.0.0.1:9/never-fetch'\n"},
            {"m3u8",
             "#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nhttp://127.0.0.1:9/never-fetch.ts\n#EXT-X-ENDLIST\n"}
          ] do
        context = %{
          run_input: %{
            "space_hash" => "ubg50",
            "embed_hash" => "LeDE9v86ye",
            "source_body" => body,
            "source_url" => "https://storage.example/custom-thumbnail.#{extension}",
            "media_extract_frame_mode" => "ffmpeg"
          },
          dependency_outputs: %{}
        }

        assert {:error, {:media_extract_frame_failed, {:ffmpeg_exit, _, message}}} =
                 MediaExtractFrameStep.run(step, context)

        assert message =~ "not on whitelist"
      end
    end
  end

  test "extracts avif poster from odd-dimension video frames" do
    ffmpeg_bin = System.find_executable("ffmpeg")

    if is_nil(ffmpeg_bin) or not ffmpeg_encoder_available?(ffmpeg_bin, "libsvtav1") do
      assert true
    else
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "mave_extract_frame_avif_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)

      try do
        input_path = Path.join(tmp_dir, "odd.mkv")

        {output, 0} =
          System.cmd(
            ffmpeg_bin,
            [
              "-y",
              "-f",
              "lavfi",
              "-i",
              "testsrc=duration=1:size=641x359:rate=1",
              "-frames:v",
              "1",
              "-c:v",
              "ffv1",
              input_path
            ],
            stderr_to_stdout: true
          )

        assert is_binary(output)

        step_definition = %{
          "id" => "poster_frame_avif",
          "type" => "media.extract_frame",
          "params" => %{"role" => "poster", "codec" => "avif", "strict" => true}
        }

        context = %{
          run_input: %{
            "space_hash" => "ubg50",
            "embed_hash" => "LeDE9v86ye",
            "source_body" => File.read!(input_path),
            "source_content_type" => "video/x-matroska",
            "media_extract_frame_mode" => "ffmpeg",
            "version" => 0
          },
          dependency_outputs: %{
            "source" => %{
              "space_hash" => "ubg50",
              "embed_hash" => "LeDE9v86ye",
              "source_url" => "https://example.com/odd.mkv",
              "version" => 0
            }
          }
        }

        assert {:ok, output, artifacts} = MediaExtractFrameStep.run(step_definition, context)
        assert output["status"] == "ok"
        assert output["key"] == "LeDE9v86ye/poster.avif"
        assert [%{media_type: "image/avif"}] = artifacts

        assert {:ok, body} =
                 FlowStorageAdapterStub.get("space-ubg50", "LeDE9v86ye/poster.avif", nil)

        assert byte_size(body) > 0
      after
        File.rm_rf(tmp_dir)
      end
    end
  end

  test "returns unavailable output in non-strict mode on missing source" do
    step_definition = %{
      "id" => "poster_frame",
      "type" => "media.extract_frame",
      "params" => %{"role" => "poster", "codec" => "jpg"}
    }

    context = %{
      run_input: %{"space_hash" => "ubg50", "embed_hash" => "LeDE9v86ye"},
      dependency_outputs: %{"source" => %{"space_hash" => "ubg50", "embed_hash" => "LeDE9v86ye"}}
    }

    assert {:ok, output, []} = MediaExtractFrameStep.run(step_definition, context)
    assert output["status"] == "unavailable"
    assert output["step_type"] == "media.extract_frame"
  end

  test "returns error in strict mode on missing source" do
    step_definition = %{
      "id" => "poster_frame",
      "type" => "media.extract_frame",
      "params" => %{"role" => "poster", "codec" => "jpg"}
    }

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "media_extract_frame_strict" => true
      },
      dependency_outputs: %{"source" => %{"space_hash" => "ubg50", "embed_hash" => "LeDE9v86ye"}}
    }

    assert {:error, {:media_extract_frame_failed, {:missing_field, :source_url}}} =
             MediaExtractFrameStep.run(step_definition, context)
  end

  defp ffmpeg_encoder_available?(ffmpeg_bin, encoder) do
    case System.cmd(ffmpeg_bin, ["-hide_banner", "-encoders"], stderr_to_stdout: true) do
      {output, 0} -> String.contains?(output, encoder)
      _ -> false
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)
end
