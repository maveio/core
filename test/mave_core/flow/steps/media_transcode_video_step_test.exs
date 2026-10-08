defmodule MaveCore.Flow.Steps.MediaTranscodeVideoStepTest do
  use ExUnit.Case, async: false

  alias MaveCore.Flow.Steps.MediaTranscodeVideoStep
  alias MaveCore.TestSupport.FlowStorageAdapterStub

  defmodule EncodingBoosterAdapterStub do
    def encode_to_storage(input_url, upload, options) do
      send(Application.fetch_env!(:mave_core, :encoding_booster_test_pid), {
        :video_booster_request,
        input_url,
        options
      })

      if is_function(options[:on_chunk], 1), do: options[:on_chunk].(2_048)

      {:ok, _body} =
        FlowStorageAdapterStub.put_public(
          upload["test_bucket"],
          upload["test_path"],
          "boosted-video",
          upload["test_content_type"],
          upload["test_region"]
        )

      {:ok,
       %{
         elapsed_ms: 25,
         ffmpeg_elapsed_ms: 20,
         output_bytes: byte_size("boosted-video"),
         instance_id: "video-instance"
       }}
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

  test "streams a rendition from object storage through the CPU booster into object storage" do
    step_definition = %{
      "id" => "video_h264_sd",
      "type" => "media.transcode_video",
      "params" => %{"codec" => "h264", "size" => "sd", "strict" => true}
    }

    context = %{
      run_input: %{
        "space_hash" => "qingb",
        "embed_hash" => "video12345",
        "source_bucket" => "mave-upload",
        "source_key" => "qingb/source.mp4",
        "source_region" => "qingb",
        "version" => 1
      },
      dependency_outputs: %{
        "source" => %{
          "space_hash" => "qingb",
          "embed_hash" => "video12345",
          "source_url" => "https://storage.example/mave-upload/qingb/source.mp4",
          "version" => 1
        },
        "inspect_media" => %{"duration" => 10.0, "width" => 1920, "height" => 1080}
      },
      encoding_booster_dispatch: :direct,
      progress_reporter: self()
    }

    assert {:ok, output, [_artifact]} = MediaTranscodeVideoStep.run(step_definition, context)

    assert output["mode"] == "encoding_booster"
    assert output["key"] == "video12345/v1/h264_sd.mp4"
    assert output["file_size"] == byte_size("boosted-video")
    assert output["encoding_booster_storage_direct"] == true
    assert output["encoding_booster_instances"] == ["video-instance"]

    assert FlowStorageAdapterStub.multipart_upload_opts(
             "space-qingb",
             "video12345/v1/h264_sd.mp4",
             nil
           )[:max_bytes] ==
             round((2_000_000 + 128_000) * 10_000 / 8_000 * 2.0) + 8 * 1024 * 1024

    assert_receive {:video_booster_request, input_url, options}
    assert input_url =~ "mave-upload/qingb/source.mp4"
    assert options[:encoding_profile] == "mave-production-v2"
    assert options[:codec] == "h264"
    assert options[:width] == 640
    assert options[:video_bitrate] == "2M"
  end

  test "normalizes an odd source-capped UHD long edge for the booster" do
    step_definition = %{
      "id" => "video_h264_uhd",
      "type" => "media.transcode_video",
      "params" => %{
        "codec" => "h264",
        "size" => "uhd",
        "require_source_resolution" => true,
        "strict" => true
      }
    }

    context = %{
      run_input: %{
        "space_hash" => "qingb",
        "embed_hash" => "video12345",
        "source_bucket" => "mave-upload",
        "source_key" => "qingb/source.mp4",
        "source_region" => "qingb",
        "version" => 1
      },
      dependency_outputs: %{
        "source" => %{
          "space_hash" => "qingb",
          "embed_hash" => "video12345",
          "source_url" => "https://storage.example/mave-upload/qingb/source.mp4",
          "version" => 1
        },
        "inspect_media" => %{"duration" => 10.0, "width" => 3098, "height" => 3397}
      },
      encoding_booster_dispatch: :direct,
      progress_reporter: self()
    }

    assert {:ok, output, [_artifact]} = MediaTranscodeVideoStep.run(step_definition, context)
    assert output["resolution"] == "3096x3396"

    assert_receive {:video_booster_request, _input_url, options}
    assert options[:width] == 3396
    assert options[:video_bitrate] == "16M"
  end

  test "streams H264 keyframe clips from the canonical source through the CPU booster" do
    step_definition = %{
      "id" => "clip_h264_hd_keyframes",
      "type" => "media.transcode_video",
      "params" => %{
        "codec" => "h264",
        "size" => "hd",
        "source_step_id" => "video_h264_hd",
        "keyframe_interval" => 2,
        "strict" => true
      }
    }

    context = %{
      run_input: %{
        "space_hash" => "qingb",
        "embed_hash" => "video12345",
        "source_bucket" => "mave-upload",
        "source_key" => "qingb/source.mp4",
        "source_region" => "qingb",
        "version" => 1
      },
      dependency_outputs: %{
        "source" => %{
          "space_hash" => "qingb",
          "embed_hash" => "video12345",
          "source_url" => "https://storage.example/mave-upload/qingb/source.mp4",
          "version" => 1
        },
        "inspect_media" => %{"duration" => 10.0, "width" => 1920, "height" => 1080},
        "video_h264_hd" => %{
          "status" => "ok",
          "step_type" => "media.transcode_h264_ladder",
          "bucket" => "space-qingb",
          "region" => "qingb",
          "variant_outputs" => %{
            "hd" => %{
              "status" => "ok",
              "bucket" => "space-qingb",
              "key" => "video12345/v1/h264_hd.mp4",
              "codec" => "h264",
              "size" => "hd",
              "container" => "mp4"
            }
          }
        }
      },
      encoding_booster_dispatch: :direct,
      progress_reporter: self()
    }

    assert {:ok, output, [_artifact]} = MediaTranscodeVideoStep.run(step_definition, context)
    assert output["mode"] == "encoding_booster"

    assert_receive {:video_booster_request, input_url, options}
    assert input_url =~ "mave-upload/qingb/source.mp4"
    refute input_url =~ "space-qingb/video12345/v1/h264_hd.mp4"
    assert options[:encoding_profile] == "mave-production-v2"
    assert options[:video_bitrate] == "4M"
    assert options[:video_crf] == 23
    assert options[:preset] == "medium"
    assert options[:gop_frames] == 2
    assert options[:max_duration_seconds] == 10
    assert options[:include_audio] == false
    refute Keyword.has_key?(options, :keyframe_interval_seconds)
    refute Keyword.has_key?(options, :tune)

    assert FlowStorageAdapterStub.multipart_upload_opts(
             "space-qingb",
             "video12345/v1/h264_hd_clip_keyframes.mp4",
             nil
           )[:max_bytes] == 512 * 1024 * 1024
  end

  test "scales dense keyframe multipart capacity with the output pixel count" do
    context = %{
      run_input: %{
        "space_hash" => "qingb",
        "embed_hash" => "video12345",
        "source_bucket" => "mave-upload",
        "source_key" => "qingb/source.mp4",
        "source_region" => "qingb",
        "version" => 1
      },
      dependency_outputs: %{
        "source" => %{
          "space_hash" => "qingb",
          "embed_hash" => "video12345",
          "source_url" => "https://storage.example/mave-upload/qingb/source.mp4",
          "version" => 1
        },
        "inspect_media" => %{"duration" => 35.0, "width" => 4000, "height" => 5000}
      },
      encoding_booster_dispatch: :direct,
      progress_reporter: self()
    }

    for {size, expected_capacity} <- [
          {"sd", 128 * 1024 * 1024},
          {"hd", 512 * 1024 * 1024},
          {"fhd", 1_152 * 1024 * 1024}
        ] do
      step_definition = %{
        "id" => "clip_h264_#{size}_keyframes",
        "type" => "media.transcode_video",
        "params" => %{
          "codec" => "h264",
          "size" => size,
          "keyframe_interval" => 2,
          "strict" => true
        }
      }

      assert {:ok, _output, [_artifact]} =
               MediaTranscodeVideoStep.run(step_definition, context)

      assert FlowStorageAdapterStub.multipart_upload_opts(
               "space-qingb",
               "video12345/v1/h264_#{size}_clip_keyframes.mp4",
               nil
             )[:max_bytes] == expected_capacity
    end
  end

  test "streams HEVC and AV1 clips from the canonical source through the CPU booster" do
    context = %{
      run_input: %{
        "space_hash" => "qingb",
        "embed_hash" => "video12345",
        "source_bucket" => "mave-upload",
        "source_key" => "qingb/source.mp4",
        "source_region" => "qingb",
        "version" => 1
      },
      dependency_outputs: %{
        "source" => %{
          "space_hash" => "qingb",
          "embed_hash" => "video12345",
          "source_url" => "https://storage.example/mave-upload/qingb/source.mp4",
          "version" => 1
        },
        "inspect_media" => %{"duration" => 10.0, "width" => 1920, "height" => 1080},
        "video_h264_hd" => %{
          "status" => "ok",
          "step_type" => "media.transcode_h264_ladder",
          "bucket" => "space-qingb",
          "region" => "qingb",
          "variant_outputs" => %{
            "hd" => %{
              "status" => "ok",
              "bucket" => "space-qingb",
              "key" => "video12345/v1/h264_hd.mp4",
              "codec" => "h264",
              "size" => "hd",
              "container" => "mp4"
            }
          }
        }
      },
      encoding_booster_dispatch: :direct,
      progress_reporter: self()
    }

    for {codec, expected_options} <- [
          {"hevc", [video_crf: 24, preset: "medium", tune: "grain"]},
          {"av1", [video_crf: 26, preset: "slow"]}
        ] do
      step_definition = %{
        "id" => "clip_#{codec}_hd",
        "type" => "media.transcode_video",
        "params" => %{
          "codec" => codec,
          "size" => "hd",
          "source_step_id" => "video_h264_hd",
          "keyframe_interval" => 250,
          "strict" => true
        }
      }

      assert {:ok, output, [_artifact]} = MediaTranscodeVideoStep.run(step_definition, context)
      assert output["mode"] == "encoding_booster"

      assert_receive {:video_booster_request, input_url, options}
      assert input_url =~ "mave-upload/qingb/source.mp4"
      refute input_url =~ "space-qingb/video12345/v1/h264_hd.mp4"
      assert options[:encoding_profile] == "mave-production-v2"
      assert options[:include_audio] == false
      refute Keyword.has_key?(options, :video_bitrate)

      for {key, value} <- expected_options do
        assert options[key] == value
      end
    end
  end

  test "produces rendition artifact from source_body copy mode" do
    step_definition = %{
      "id" => "video_h264_sd",
      "type" => "media.transcode_video",
      "params" => %{"codec" => "h264", "size" => "sd"}
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

    assert {:ok, output, artifacts} = MediaTranscodeVideoStep.run(step_definition, context)
    assert output["status"] == "ok"
    assert output["mode"] == "copy"
    assert output["codec"] == "h264"
    assert output["size"] == "sd"
    assert output["key"] == "LeDE9v86ye/h264_sd.mp4"
    assert output["uri"] == "s3://space-ubg50/LeDE9v86ye/h264_sd.mp4"
    assert output["file_size"] == 15
    assert output["rendition"]["type"] == "video"
    assert output["rendition"]["progress"] == 100.0
    assert output["rendition"]["rendition_key"] == "LeDE9v86ye/h264_sd.mp4"
    assert is_list(output["renditions"])
    assert hd(output["renditions"])["type"] == "video"

    assert [%{name: "video_h264_sd", uri: uri, media_type: "video/mp4"}] = artifacts
    assert uri == "s3://space-ubg50/LeDE9v86ye/h264_sd.mp4"
  end

  test "copy mode keeps the completed upload object as its source" do
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

    step_definition = %{
      "id" => "video_h264_sd",
      "type" => "media.transcode_video",
      "params" => %{"codec" => "h264", "size" => "sd"}
    }

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "source_bucket" => "mave-upload",
        "source_key" => "uploads/demo.mp4",
        "source_region" => "us-east-1",
        "source_content_type" => "video/mp4",
        "media_transcode_video_mode" => "copy",
        "region" => "us-east-1",
        "version" => 0
      },
      dependency_outputs: %{
        "source" => %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "source_url" => "https://example.com/video.mp4",
          "version" => 0
        },
        "upload_original" => %{
          "bucket" => "space-ubg50",
          "original_key" => "LeDE9v86ye/original",
          "content_type" => "video/mp4"
        }
      }
    }

    assert {:ok, output, _artifacts} = MediaTranscodeVideoStep.run(step_definition, context)
    assert output["file_size"] == byte_size("external-source")

    assert {:ok, "external-source"} =
             FlowStorageAdapterStub.get("space-ubg50", output["key"], "us-east-1")
  end

  test "auto mode copies compatible uploaded h264 mp4 source for hd rendition" do
    original_body = "already-compatible-h264-mp4"

    assert {:ok, _body} =
             FlowStorageAdapterStub.put_public(
               "space-ubg50",
               "LeDE9v86ye/original",
               original_body,
               "video/mp4",
               "us-east-1"
             )

    step_definition = %{
      "id" => "video_h264_hd",
      "type" => "media.transcode_video",
      "params" => %{"codec" => "h264", "size" => "hd"}
    }

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "source_content_type" => "video/mp4",
        "region" => "us-east-1",
        "version" => 0
      },
      dependency_outputs: %{
        "source" => %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "source_url" => "https://example.com/video.mp4",
          "version" => 0
        },
        "upload_original" => %{
          "bucket" => "space-ubg50",
          "original_key" => "LeDE9v86ye/original",
          "content_type" => "video/mp4"
        },
        "inspect_media" => %{
          "status" => "ok",
          "step_type" => "media.inspect",
          "filetype" => "mp4",
          "video_codec" => "h264",
          "audio_codec" => "aac",
          "width" => 1280,
          "height" => 720,
          "size_bytes" => byte_size(original_body)
        }
      }
    }

    assert {:ok, output, _artifacts} = MediaTranscodeVideoStep.run(step_definition, context)
    assert output["mode"] == "source_copy"
    assert output["source_copy"] == true
    assert output["key"] == "LeDE9v86ye/h264_hd.mp4"
    assert output["file_size"] == byte_size(original_body)

    assert {:ok, ^original_body} =
             FlowStorageAdapterStub.get("space-ubg50", "LeDE9v86ye/h264_hd.mp4", "us-east-1")

    assert FlowStorageAdapterStub.public?("space-ubg50", "LeDE9v86ye/h264_hd.mp4", "us-east-1")
  end

  test "returns unavailable output in non-strict mode on missing source" do
    step_definition = %{
      "id" => "video_h264_sd",
      "type" => "media.transcode_video",
      "params" => %{"codec" => "h264", "size" => "sd"}
    }

    context = %{
      run_input: %{"space_hash" => "ubg50", "embed_hash" => "LeDE9v86ye"},
      dependency_outputs: %{"source" => %{"space_hash" => "ubg50", "embed_hash" => "LeDE9v86ye"}}
    }

    assert {:ok, output, []} = MediaTranscodeVideoStep.run(step_definition, context)
    assert output["status"] == "unavailable"
    assert output["step_type"] == "media.transcode_video"
  end

  test "returns error in strict mode on missing source" do
    step_definition = %{
      "id" => "video_h264_sd",
      "type" => "media.transcode_video",
      "params" => %{"codec" => "h264", "size" => "sd"}
    }

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "media_transcode_video_strict" => true
      },
      dependency_outputs: %{"source" => %{"space_hash" => "ubg50", "embed_hash" => "LeDE9v86ye"}}
    }

    assert {:error, {:media_transcode_video_failed, {:missing_field, :source_url}}} =
             MediaTranscodeVideoStep.run(step_definition, context)
  end

  test "skips configured variants above the inspected source resolution" do
    step_definition = %{
      "id" => "clip_h264_fhd_keyframes",
      "type" => "media.transcode_video",
      "params" => %{"codec" => "h264", "size" => "fhd", "keyframe_interval" => 2}
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
        },
        "inspect_media" => %{
          "status" => "ok",
          "width" => 1280,
          "height" => 720
        }
      }
    }

    assert {:ok, output, []} = MediaTranscodeVideoStep.run(step_definition, context)
    assert output["status"] == "skipped"
    assert output["reason"] == "source_resolution_below_variant"
    assert output["step_id"] == "clip_h264_fhd_keyframes"
  end

  test "uses source long edge when filtering portrait transcode variants" do
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
        },
        "inspect_media" => %{
          "status" => "ok",
          "width" => 1080,
          "height" => 1920
        }
      }
    }

    fhd_definition = %{
      "id" => "clip_h264_fhd_keyframes",
      "type" => "media.transcode_video",
      "params" => %{"codec" => "h264", "size" => "fhd", "keyframe_interval" => 2}
    }

    qhd_definition = %{
      "id" => "clip_hevc_qhd",
      "type" => "media.transcode_video",
      "params" => %{"codec" => "hevc", "size" => "qhd"}
    }

    assert {:ok, fhd_output, _artifacts} = MediaTranscodeVideoStep.run(fhd_definition, context)
    assert fhd_output["status"] == "ok"
    assert fhd_output["resolution"] == "1080x1920"

    assert {:ok, qhd_output, []} = MediaTranscodeVideoStep.run(qhd_definition, context)
    assert qhd_output["status"] == "skipped"
    assert qhd_output["reason"] == "source_resolution_below_variant"
  end

  test "ffmpeg clip keyframes omit audio streams" do
    ffmpeg_bin = System.find_executable("ffmpeg")
    ffprobe_bin = System.find_executable("ffprobe")

    if is_nil(ffmpeg_bin) or is_nil(ffprobe_bin) do
      assert true
    else
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "mave_transcode_video_clip_audio_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)

      try do
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
              "-f",
              "lavfi",
              "-i",
              "sine=frequency=1000:duration=1",
              "-shortest",
              "-pix_fmt",
              "yuv420p",
              "-c:v",
              "libx264",
              "-c:a",
              "aac",
              input_path
            ],
            stderr_to_stdout: true
          )

        assert {:ok, _} =
                 FlowStorageAdapterStub.put(
                   "space-ubg50",
                   "LeDE9v86ye/original",
                   File.read!(input_path),
                   "video/mp4",
                   nil
                 )

        step_definition = %{
          "id" => "clip_h264_sd_keyframes",
          "type" => "media.transcode_video",
          "params" => %{"codec" => "h264", "size" => "sd", "keyframe_interval" => 2}
        }

        context = %{
          run_input: %{
            "space_hash" => "ubg50",
            "embed_hash" => "LeDE9v86ye",
            "source_content_type" => "video/mp4",
            "media_transcode_video_mode" => "ffmpeg",
            "version" => 0
          },
          dependency_outputs: %{
            "source" => %{
              "space_hash" => "ubg50",
              "embed_hash" => "LeDE9v86ye",
              "source_url" => "https://example.com/video.mp4",
              "version" => 0
            },
            "upload_original" => %{
              "bucket" => "space-ubg50",
              "original_key" => "LeDE9v86ye/original",
              "content_type" => "video/mp4"
            },
            "inspect_media" => %{
              "status" => "ok",
              "duration" => 1
            }
          }
        }

        assert {:ok, output, _artifacts} = MediaTranscodeVideoStep.run(step_definition, context)
        assert output["status"] == "ok"
        assert output["rendition"]["type"] == "clip_keyframes"

        assert {:ok, clip_body} =
                 FlowStorageAdapterStub.get(
                   "space-ubg50",
                   "LeDE9v86ye/h264_sd_clip_keyframes.mp4",
                   nil
                 )

        output_path = Path.join(tmp_dir, "clip_keyframes.mp4")
        File.write!(output_path, clip_body)

        {video_streams, 0} =
          System.cmd(
            ffprobe_bin,
            [
              "-v",
              "error",
              "-select_streams",
              "v",
              "-show_entries",
              "stream=codec_type",
              "-of",
              "csv=p=0",
              output_path
            ],
            stderr_to_stdout: true
          )

        {audio_streams, 0} =
          System.cmd(
            ffprobe_bin,
            [
              "-v",
              "error",
              "-select_streams",
              "a",
              "-show_entries",
              "stream=codec_type",
              "-of",
              "csv=p=0",
              output_path
            ],
            stderr_to_stdout: true
          )

        assert String.trim(video_streams) == "video"
        assert String.trim(audio_streams) == ""
      after
        _ = File.rm_rf(tmp_dir)
      end
    end
  end

  test "emits clip-specific rendition types for clips and keyframes" do
    clip_definition = %{
      "id" => "clip_hevc_sd",
      "type" => "media.transcode_video",
      "params" => %{"codec" => "hevc", "size" => "sd"}
    }

    keyframe_definition = %{
      "id" => "clip_h264_sd_keyframes",
      "type" => "media.transcode_video",
      "params" => %{"codec" => "h264", "size" => "sd", "keyframe_interval" => 2}
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

    assert {:ok, clip_output, _artifacts} = MediaTranscodeVideoStep.run(clip_definition, context)
    assert clip_output["rendition"]["type"] == "clip"
    assert hd(clip_output["renditions"])["type"] == "clip"

    assert {:ok, keyframe_output, _artifacts} =
             MediaTranscodeVideoStep.run(keyframe_definition, context)

    assert keyframe_output["rendition"]["type"] == "clip_keyframes"
    assert hd(keyframe_output["renditions"])["type"] == "clip_keyframes"
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)
end
