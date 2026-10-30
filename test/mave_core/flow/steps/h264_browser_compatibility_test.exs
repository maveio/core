defmodule MaveCore.Flow.Steps.H264BrowserCompatibilityTest do
  use ExUnit.Case, async: false

  alias MaveCore.Flow.Steps.{MediaTranscodeH264LadderStep, MediaTranscodeVideoStep, Support}
  alias MaveCore.TestSupport.FlowStorageAdapterStub

  setup do
    previous = Application.get_env(:mave_core, :flow_storage_adapter)
    Application.put_env(:mave_core, :flow_storage_adapter, FlowStorageAdapterStub)
    FlowStorageAdapterStub.reset!()

    on_exit(fn ->
      FlowStorageAdapterStub.reset!()

      if previous,
        do: Application.put_env(:mave_core, :flow_storage_adapter, previous),
        else: Application.delete_env(:mave_core, :flow_storage_adapter)
    end)

    :ok
  end

  test "only known browser H.264 profiles and 8-bit 4:2:0 are reusable" do
    for profile <- ["Constrained Baseline", "Baseline", "Main", "High"],
        format <- ["yuv420p", "yuvj420p"] do
      assert Support.browser_h264_stream?(%{
               "codec_name" => "h264",
               "profile" => profile,
               "pix_fmt" => format
             })
    end

    for {profile, format} <- [
          {"High 10", "yuv420p10le"},
          {"High 4:2:2", "yuv422p10le"},
          {"High 4:4:4 Predictive", "yuv444p"},
          {"High", "yuv444p"},
          {nil, "yuv420p"},
          {"High", nil}
        ] do
      refute Support.browser_h264_stream?(%{
               "codec_name" => "h264",
               "profile" => profile,
               "pix_fmt" => format
             })
    end

    refute Support.browser_h264_stream?(nil)

    refute Support.browser_h264_stream?(%{
             "codec_name" => "hevc",
             "profile" => "Main",
             "pix_fmt" => "yuv420p"
           })
  end

  test "normalizes real 10-bit and 4:2:2/4:4:4 sources and rejects incompatible output" do
    if ffmpeg = System.find_executable("ffmpeg") do
      for format <- ["yuv420p", "yuv420p10le", "yuv422p10le", "yuv444p10le", "yuv444p"] do
        Support.with_temp_dir("browser_h264", fn dir ->
          path = Path.join(dir, "source.mp4")

          assert {_, 0} =
                   System.cmd(
                     ffmpeg,
                     [
                       "-v",
                       "error",
                       "-f",
                       "lavfi",
                       "-i",
                       "testsrc2=size=160x96:rate=12",
                       "-t",
                       "1",
                       "-vf",
                       "format=#{format}",
                       "-c:v",
                       "libx264",
                       "-threads",
                       "1",
                       "-pix_fmt",
                       format,
                       path
                     ],
                     stderr_to_stdout: true
                   )

          if format == "yuv420p" do
            assert :ok = Support.validate_media_file(path, :h264)
          else
            assert {:error, {:invalid_media_output, :h264, :incompatible_h264_stream}} =
                     Support.validate_media_file(path, :h264)
          end

          context = %{
            run_input: %{
              "space_hash" => "test0",
              "embed_hash" => "synthetic0",
              "version" => 0,
              "source_body" => File.read!(path),
              "source_content_type" => "video/mp4",
              "media_transcode_video_mode" => "auto",
              "media_transcode_h264_ladder_mode" => "auto"
            },
            dependency_outputs: %{
              "source" => %{"source_url" => "https://example.com/source.mp4"},
              "inspect_media" => %{
                "has_video" => true,
                "has_audio" => false,
                "width" => 160,
                "height" => 96,
                "duration" => 1
              }
            }
          }

          for {handler, params, key} <- [
                {MediaTranscodeVideoStep, %{"codec" => "h264", "size" => "sd", "strict" => true},
                 "synthetic0/h264_sd.mp4"},
                {MediaTranscodeVideoStep,
                 %{"codec" => "h264", "size" => "sd", "keyframe_interval" => 2, "strict" => true},
                 "synthetic0/h264_sd_clip_keyframes.mp4"},
                {MediaTranscodeH264LadderStep, %{"sizes" => ["sd"], "strict" => true},
                 "synthetic0/h264_sd.mp4"}
              ] do
            assert {:ok, output, _} =
                     handler.run(%{"id" => "encode", "params" => params}, context)

            assert output["mode"] == "ffmpeg"
            assert {:ok, body} = FlowStorageAdapterStub.get("space-test0", key, nil)
            encoded = Path.join(dir, "encoded.mp4")
            File.write!(encoded, body)
            assert :ok = Support.validate_media_file(encoded, :h264)
          end
        end)
      end
    end
  end
end
