defmodule MaveCore.Flow.Steps.MediaGenerateSegmentsStepTest do
  use ExUnit.Case, async: false

  alias MaveCore.Flow.Steps.MediaGenerateSegmentsStep
  alias MaveCore.TestSupport.FlowStorageAdapterStub

  defmodule EncodingBoosterAdapterStub do
    def encode_many_to_storage(input_url, outputs, options) do
      send(Application.fetch_env!(:mave_core, :encoding_booster_test_pid), {
        :segments_booster_request,
        input_url,
        outputs,
        options
      })

      Enum.each(outputs, fn %{"output_upload" => upload} ->
        {:ok, _body} =
          FlowStorageAdapterStub.put_public(
            upload["test_bucket"],
            upload["test_path"],
            "boosted-segment",
            upload["test_content_type"],
            upload["test_region"]
          )
      end)

      {:ok, %{elapsed_ms: 35, ffmpeg_elapsed_ms: 30, instance_id: "segments-instance"}}
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

  test "streams segment thumbnails from the SD rendition through one CPU booster request" do
    step_definition = %{
      "id" => "segments",
      "type" => "media.generate_segments",
      "params" => %{"codec" => "jpg", "size" => "sd", "count" => 3, "strict" => true}
    }

    context = %{
      run_input: %{
        "space_hash" => "qingb",
        "embed_hash" => "segments123",
        "source_bucket" => "mave-upload",
        "source_key" => "qingb/source.mp4",
        "source_region" => "qingb",
        "region" => "qingb",
        "input_url" => "https://storage.example/mave-upload/qingb/source.mp4",
        "version" => 1
      },
      dependency_outputs: %{
        "inspect_media" => %{"has_video" => true, "duration" => 12.0},
        "video_h264_sd" => %{
          "status" => "ok",
          "step_type" => "media.transcode_video",
          "bucket" => "space-qingb",
          "region" => "qingb",
          "key" => "segments123/v1/h264_sd.mp4",
          "codec" => "h264",
          "size" => "sd",
          "container" => "mp4",
          "uri" => "s3://space-qingb/segments123/v1/h264_sd.mp4"
        }
      },
      encoding_booster_dispatch: :direct
    }

    assert {:ok, output, artifacts} = MediaGenerateSegmentsStep.run(step_definition, context)
    assert output["mode"] == "encoding_booster"
    assert output["count"] == 3
    assert output["encoding_booster_instances"] == ["segments-instance"]
    assert length(artifacts) == 3

    assert_receive {:segments_booster_request, input_url, outputs, options}
    assert input_url =~ "segments123/v1/h264_sd.mp4"

    assert Enum.map(outputs, & &1["name"]) ==
             ~w(thumbnail_0.jpg thumbnail_1.jpg thumbnail_2.jpg)

    assert options[:operation] == "segments"
    assert options[:count] == 3
    assert options[:duration_seconds] == 12.0
  end

  test "produces segment artifacts from source_body copy mode" do
    step_definition = %{
      "id" => "segments",
      "type" => "media.generate_segments",
      "params" => %{"codec" => "jpg", "size" => "sd", "count" => 6}
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

    assert {:ok, output, artifacts} = MediaGenerateSegmentsStep.run(step_definition, context)
    assert output["status"] == "ok"
    assert output["mode"] == "copy"
    assert output["codec"] == "jpg"
    assert output["size"] == "sd"
    assert output["count"] == 6
    assert output["rendition"]["type"] == "segments"
    assert output["rendition"]["progress"] == 100.0
    assert is_list(output["segments"])
    assert length(output["segments"]) == 6

    assert Enum.at(output["segments"], 0)["key"] == "LeDE9v86ye/thumbnail_0.jpg"
    assert Enum.at(output["segments"], 5)["key"] == "LeDE9v86ye/thumbnail_5.jpg"
    assert Enum.at(output["segments"], 0)["uri"] == "s3://space-ubg50/LeDE9v86ye/thumbnail_0.jpg"
    assert Enum.at(output["segments"], 5)["uri"] == "s3://space-ubg50/LeDE9v86ye/thumbnail_5.jpg"

    assert length(artifacts) == 6
    assert Enum.any?(artifacts, &(&1.name == "thumbnail_0"))
    assert Enum.any?(artifacts, &(&1.name == "thumbnail_5"))
  end

  test "returns unavailable output in non-strict mode on missing source" do
    step_definition = %{
      "id" => "segments",
      "type" => "media.generate_segments",
      "params" => %{"codec" => "jpg", "size" => "sd"}
    }

    context = %{
      run_input: %{"space_hash" => "ubg50", "embed_hash" => "LeDE9v86ye"},
      dependency_outputs: %{}
    }

    assert {:ok, output, []} = MediaGenerateSegmentsStep.run(step_definition, context)
    assert output["status"] == "unavailable"
    assert output["step_type"] == "media.generate_segments"
  end

  test "returns error in strict mode on missing source" do
    step_definition = %{
      "id" => "segments",
      "type" => "media.generate_segments",
      "params" => %{"codec" => "jpg", "size" => "sd"}
    }

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "media_generate_segments_strict" => true
      },
      dependency_outputs: %{}
    }

    assert {:error, {:media_generate_segments_failed, {:missing_field, :source_url}}} =
             MediaGenerateSegmentsStep.run(step_definition, context)
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
        "id" => "segments",
        "type" => "media.generate_segments",
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
          "media_generate_segments_mode" => "ffmpeg"
        },
        dependency_outputs: ladder_dependency_outputs()
      }

      assert {:ok, output, artifacts} =
               MediaGenerateSegmentsStep.run(step_definition, context)

      assert output["status"] == "ok"
      assert output["mode"] == "ffmpeg"
      assert output["count"] == 2
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
            "mave_segments_ladder_test_#{System.unique_integer([:positive])}"
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
