defmodule MaveCore.Flow.Steps.MediaGenerateStoryboardStepTest do
  use ExUnit.Case, async: false

  alias MaveCore.Flow.Steps.MediaGenerateStoryboardStep
  alias MaveCore.TestSupport.FlowStorageAdapterStub

  defmodule EncodingBoosterAdapterStub do
    def encode_to_storage(input_url, upload, options) do
      send(Application.fetch_env!(:mave_core, :encoding_booster_test_pid), {
        :storyboard_booster_request,
        input_url,
        options
      })

      {:ok, _body} =
        FlowStorageAdapterStub.put_public(
          upload["test_bucket"],
          upload["test_path"],
          "boosted-storyboard",
          upload["test_content_type"],
          upload["test_region"]
        )

      {:ok, %{elapsed_ms: 25, ffmpeg_elapsed_ms: 20, instance_id: "storyboard-instance"}}
    end
  end

  setup do
    old_storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter)
    old_booster_adapter = Application.get_env(:mave_core, :encoding_booster_adapter)
    old_booster_pid = Application.get_env(:mave_core, :encoding_booster_test_pid)

    old_direct_storage_ffmpeg_input =
      Application.get_env(:mave_core, :flow_direct_storage_ffmpeg_input)

    Application.put_env(
      :mave_core,
      :flow_storage_adapter,
      FlowStorageAdapterStub
    )

    Application.put_env(:mave_core, :flow_direct_storage_ffmpeg_input, false)
    Application.put_env(:mave_core, :encoding_booster_adapter, EncodingBoosterAdapterStub)
    Application.put_env(:mave_core, :encoding_booster_test_pid, self())
    FlowStorageAdapterStub.reset!()

    on_exit(fn ->
      FlowStorageAdapterStub.reset!()
      restore_env(:flow_storage_adapter, old_storage_adapter)
      restore_env(:flow_direct_storage_ffmpeg_input, old_direct_storage_ffmpeg_input)
      restore_env(:encoding_booster_adapter, old_booster_adapter)
      restore_env(:encoding_booster_test_pid, old_booster_pid)
    end)

    :ok
  end

  test "streams the storyboard sprite from the SD rendition through the CPU booster" do
    step_definition = %{
      "id" => "storyboard",
      "type" => "media.generate_storyboard",
      "params" => %{"codec" => "jpg", "size" => "sd", "strict" => true}
    }

    context = %{
      run_input: %{
        "space_hash" => "qingb",
        "embed_hash" => "storyboard123",
        "source_bucket" => "mave-upload",
        "source_key" => "qingb/source.mp4",
        "source_region" => "qingb",
        "region" => "qingb",
        "input_url" => "https://storage.example/mave-upload/qingb/source.mp4",
        "version" => 1
      },
      dependency_outputs: %{
        "inspect_media" => %{
          "has_video" => true,
          "duration" => 20.0,
          "width" => 1080,
          "height" => 1920
        },
        "video_h264_sd" => %{
          "status" => "ok",
          "step_type" => "media.transcode_video",
          "bucket" => "space-qingb",
          "region" => "qingb",
          "key" => "storyboard123/v1/h264_sd.mp4",
          "codec" => "h264",
          "size" => "sd",
          "resolution" => "360x640",
          "container" => "mp4",
          "uri" => "s3://space-qingb/storyboard123/v1/h264_sd.mp4"
        }
      },
      encoding_booster_dispatch: :direct
    }

    assert {:ok, output, artifacts} = MediaGenerateStoryboardStep.run(step_definition, context)
    assert output["mode"] == "encoding_booster"
    assert output["file_size"] == byte_size("boosted-storyboard")
    assert output["encoding_booster_instances"] == ["storyboard-instance"]
    assert length(artifacts) == 2

    assert_receive {:storyboard_booster_request, input_url, options}
    assert input_url =~ "storyboard123/v1/h264_sd.mp4"
    assert options[:operation] == "storyboard"
    assert options[:duration_seconds] == 20.0
    assert options[:count] == 20
    assert output["rendition"]["thumbs_count"] == 20
    assert output["rendition"]["rows"] == 2

    assert {:ok, vtt} =
             FlowStorageAdapterStub.get(
               "space-qingb",
               "storyboard123/v1/storyboard.vtt",
               "qingb"
             )

    assert vtt =~ "#xywh=0,0,320,568"
    refute vtt =~ "#xywh=0,0,320,180"
  end

  test "distributes a bounded storyboard across the full duration" do
    duration = 5_126.130736
    inspected_duration = 5_126.131

    step_definition = %{
      "id" => "storyboard",
      "type" => "media.generate_storyboard",
      "params" => %{"codec" => "jpg", "size" => "sd", "strict" => true}
    }

    context = %{
      run_input: %{
        "space_hash" => "trial",
        "embed_hash" => "longstory1",
        "region" => "trial",
        "input_url" => "https://storage.example/trial/source.mp4",
        "version" => 0
      },
      dependency_outputs: %{
        "inspect_media" => %{"has_video" => true, "duration" => duration},
        "video_h264_sd" => %{
          "status" => "ok",
          "step_type" => "media.transcode_video",
          "bucket" => "space-trial",
          "region" => "trial",
          "key" => "longstory1/h264_sd.mp4",
          "codec" => "h264",
          "size" => "sd",
          "container" => "mp4",
          "uri" => "s3://space-trial/longstory1/h264_sd.mp4"
        }
      },
      encoding_booster_dispatch: :direct
    }

    assert {:ok, output, _artifacts} =
             MediaGenerateStoryboardStep.run(step_definition, context)

    assert_receive {:storyboard_booster_request, _input_url, options}
    assert options[:duration_seconds] == inspected_duration
    assert options[:count] == 60
    assert output["rendition"]["thumbs_count"] == 60
    assert output["rendition"]["columns"] == 10
    assert output["rendition"]["rows"] == 6

    assert {:ok, vtt} =
             FlowStorageAdapterStub.get(
               "space-trial",
               "longstory1/storyboard.vtt",
               "trial"
             )

    assert length(Regex.scan(~r/ --> /, vtt)) == 60
    assert vtt =~ "00:00:00.000 --> 00:01:25.435"
    assert vtt =~ "01:24:00.695 --> 01:25:26.131"
  end

  test "produces storyboard artifacts from source_body copy mode" do
    step_definition = %{
      "id" => "storyboard",
      "type" => "media.generate_storyboard",
      "params" => %{"codec" => "jpg", "size" => "sd", "count" => 10}
    }

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "input_url" => "https://example.com/video.mp4",
        "source_body" => "stub-media-body",
        "version" => 0
      },
      dependency_outputs: %{}
    }

    assert {:ok, output, artifacts} = MediaGenerateStoryboardStep.run(step_definition, context)
    assert output["status"] == "ok"
    assert output["mode"] == "copy"
    assert output["codec"] == "jpg"
    assert output["size"] == "sd"
    assert output["image_key"] == "LeDE9v86ye/storyboard.jpg"
    assert output["vtt_key"] == "LeDE9v86ye/storyboard.vtt"
    assert output["image_uri"] == "s3://space-ubg50/LeDE9v86ye/storyboard.jpg"
    assert output["vtt_uri"] == "s3://space-ubg50/LeDE9v86ye/storyboard.vtt"
    assert output["rendition"]["type"] == "storyboard"
    assert output["rendition"]["progress"] == 100.0
    assert output["rendition"]["vtt_src"] == "s3://space-ubg50/LeDE9v86ye/storyboard.vtt"
    assert is_list(output["renditions"])
    assert hd(output["renditions"])["type"] == "storyboard"

    assert length(artifacts) == 2
    assert Enum.any?(artifacts, &(&1.name == "storyboard"))
    assert Enum.any?(artifacts, &(&1.name == "storyboard_vtt"))
  end

  test "returns unavailable output in non-strict mode on missing source" do
    step_definition = %{
      "id" => "storyboard",
      "type" => "media.generate_storyboard",
      "params" => %{"codec" => "jpg", "size" => "sd"}
    }

    context = %{
      run_input: %{"space_hash" => "ubg50", "embed_hash" => "LeDE9v86ye"},
      dependency_outputs: %{}
    }

    assert {:ok, output, []} = MediaGenerateStoryboardStep.run(step_definition, context)
    assert output["status"] == "unavailable"
    assert output["step_type"] == "media.generate_storyboard"
  end

  test "returns error in strict mode on missing source" do
    step_definition = %{
      "id" => "storyboard",
      "type" => "media.generate_storyboard",
      "params" => %{"codec" => "jpg", "size" => "sd"}
    }

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "media_generate_storyboard_strict" => true
      },
      dependency_outputs: %{}
    }

    assert {:error, {:media_generate_storyboard_failed, {:missing_field, :source_url}}} =
             MediaGenerateStoryboardStep.run(step_definition, context)
  end

  test "prefers a completed private SD rendition over the upload URL" do
    with_test_video(fn video_body, input_path ->
      assert {:ok, _body} =
               FlowStorageAdapterStub.put(
                 "space-ubg50",
                 "LeDE9v86ye/h264_sd.mp4",
                 video_body,
                 "video/mp4",
                 "us-east-1"
               )

      step_definition = %{
        "id" => "storyboard",
        "type" => "media.generate_storyboard",
        "params" => %{"codec" => "jpg", "size" => "sd", "count" => 2, "strict" => true}
      }

      context = %{
        run_input: %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "region" => "us-east-1",
          "input_url" => "https://example.invalid/original.mp4",
          "upload_ffmpeg_input_url" =>
            Path.join(Path.dirname(input_path), "missing-original.mp4"),
          "media_generate_storyboard_mode" => "ffmpeg"
        },
        dependency_outputs: ladder_dependency_outputs()
      }

      assert {:ok, output, artifacts} =
               MediaGenerateStoryboardStep.run(step_definition, context)

      assert output["status"] == "ok"
      assert output["mode"] == "ffmpeg"
      assert output["image_key"] == "LeDE9v86ye/storyboard.jpg"
      assert output["vtt_key"] == "LeDE9v86ye/storyboard.vtt"
      assert length(artifacts) == 2
    end)
  end

  defp ladder_dependency_outputs do
    %{
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
  end

  defp with_test_video(fun) when is_function(fun, 2) do
    case System.find_executable("ffmpeg") do
      nil ->
        :ok

      ffmpeg_bin ->
        tmp_dir =
          Path.join(
            System.tmp_dir!(),
            "mave_storyboard_ladder_test_#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(tmp_dir)
        input_path = Path.join(tmp_dir, "input.mp4")

        try do
          {_output, 0} =
            System.cmd(
              ffmpeg_bin,
              [
                "-y",
                "-f",
                "lavfi",
                "-i",
                "testsrc=duration=1:size=320x180:rate=10",
                "-pix_fmt",
                "yuv420p",
                "-c:v",
                "mpeg4",
                input_path
              ],
              stderr_to_stdout: true
            )

          fun.(File.read!(input_path), input_path)
        after
          File.rm_rf!(tmp_dir)
        end
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)
end
