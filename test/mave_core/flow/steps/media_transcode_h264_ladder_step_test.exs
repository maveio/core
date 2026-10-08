defmodule MaveCore.Flow.Steps.MediaTranscodeH264LadderStepTest do
  use ExUnit.Case, async: false

  alias MaveCore.Flow.StepRegistry
  alias MaveCore.Flow.Steps.MediaTranscodeH264LadderStep
  alias MaveCore.Media.Storage
  alias MaveCore.TestSupport.FlowStorageAdapterStub

  defmodule EncodingBoosterAdapterStub do
    @moduledoc false

    def encode_to_file(input_url, output_path, options) do
      config = Application.fetch_env!(:mave_core, :encoding_booster_adapter_stub)
      fixture_path = Keyword.fetch!(config, :fixture_path)
      owner = Keyword.fetch!(config, :owner)

      send(owner, {:encoding_booster_request, input_url, options})

      if is_function(options[:on_chunk], 1) do
        options[:on_chunk].(2_048)
        options[:on_chunk].(1_024)
      end

      case File.cp(fixture_path, output_path) do
        :ok ->
          {:ok,
           %{
             elapsed_ms: 25,
             ffmpeg_elapsed_ms: 20,
             frames: 24,
             fps: 1_200.0,
             speed_x: 50.0,
             out_time_ms: 1_000,
             output_bytes: File.stat!(output_path).size,
             dup_frames: 0,
             drop_frames: 0,
             size_bytes: File.stat!(output_path).size,
             instance_id: "instance-test"
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end

    def encode_to_storage(input_url, output_upload, options) do
      config = Application.fetch_env!(:mave_core, :encoding_booster_adapter_stub)
      fixture_path = Keyword.fetch!(config, :fixture_path)
      owner = Keyword.fetch!(config, :owner)
      send(owner, {:encoding_booster_request, input_url, options})

      if is_function(options[:on_chunk], 1) do
        options[:on_chunk].(2_048)
        options[:on_chunk].(1_024)
      end

      {:ok, body} = File.read(fixture_path)

      {:ok, _body} =
        FlowStorageAdapterStub.put_public(
          output_upload["test_bucket"],
          output_upload["test_path"],
          body,
          output_upload["test_content_type"],
          output_upload["test_region"]
        )

      {:ok,
       %{
         elapsed_ms: 25,
         ffmpeg_elapsed_ms: 20,
         frames: 24,
         fps: 1_200.0,
         speed_x: 50.0,
         out_time_ms: 1_000,
         output_bytes: byte_size(body),
         dup_frames: 0,
         drop_frames: 0,
         size_bytes: byte_size(body),
         instance_id: "instance-test"
       }}
    end

    def concat_to_storage(input_urls, output_upload, _options) do
      config = Application.fetch_env!(:mave_core, :encoding_booster_adapter_stub)
      fixture_path = Keyword.fetch!(config, :fixture_path)
      owner = Keyword.fetch!(config, :owner)
      send(owner, {:encoding_booster_concat, input_urls})
      {:ok, body} = File.read(fixture_path)

      {:ok, _body} =
        FlowStorageAdapterStub.put_public(
          output_upload["test_bucket"],
          output_upload["test_path"],
          body,
          output_upload["test_content_type"],
          output_upload["test_region"]
        )

      {:ok, %{elapsed_ms: 5, size_bytes: byte_size(body), instance_id: "instance-test"}}
    end
  end

  defmodule BusyEncodingBoosterAdapterStub do
    @moduledoc false

    def encode_to_file(_input_url, _output_path, _options), do: {:error, :encoding_booster_busy}

    def encode_to_storage(_input_url, _output_upload, _options),
      do: {:error, :encoding_booster_busy}
  end

  defmodule RemuxFailedEncodingBoosterAdapterStub do
    @moduledoc false

    def encode_to_file(_input_url, _output_path, _options) do
      {:error, {:encoding_booster_remux_failed, 1}}
    end

    def encode_to_storage(_input_url, _output_upload, _options) do
      {:error, {:encoding_booster_remux_failed, 1}}
    end
  end

  setup do
    old_storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter)
    old_encoder_config = Application.get_env(:mave_core, :media_h264_ladder_encoder)
    old_booster_config = Application.get_env(:mave_core, :encoding_booster)
    old_booster_adapter = Application.get_env(:mave_core, :encoding_booster_adapter)
    old_booster_stub = Application.get_env(:mave_core, :encoding_booster_adapter_stub)

    Application.put_env(:mave_core, :flow_storage_adapter, FlowStorageAdapterStub)
    Application.put_env(:mave_core, :encoding_booster, enabled: false)

    FlowStorageAdapterStub.reset!()

    on_exit(fn ->
      FlowStorageAdapterStub.reset!()
      restore_env(:flow_storage_adapter, old_storage_adapter)
      restore_env(:media_h264_ladder_encoder, old_encoder_config)
      restore_env(:encoding_booster, old_booster_config)
      restore_env(:encoding_booster_adapter, old_booster_adapter)
      restore_env(:encoding_booster_adapter_stub, old_booster_stub)
    end)

    :ok
  end

  test "chunks long CPU booster renditions into bounded requests" do
    ffmpeg_bin = System.find_executable("ffmpeg")

    if is_nil(ffmpeg_bin) do
      assert true
    else
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "mave_h264_chunked_booster_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      fixture_path = Path.join(tmp_dir, "booster-output.mp4")

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
            "-c:v",
            "libx264",
            fixture_path
          ],
          stderr_to_stdout: true
        )

      Application.put_env(:mave_core, :encoding_booster,
        enabled: true,
        fallback_enabled: true,
        chunking_threshold_seconds: 2,
        chunk_duration_seconds: 2
      )

      Application.put_env(
        :mave_core,
        :encoding_booster_adapter,
        EncodingBoosterAdapterStub
      )

      Application.put_env(:mave_core, :encoding_booster_adapter_stub,
        fixture_path: fixture_path,
        owner: self()
      )

      step_definition = %{
        "id" => "video_h264_sd",
        "type" => "media.transcode_h264_ladder",
        "params" => %{"sizes" => ["sd"]}
      }

      context = %{
        run_input: %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "media_transcode_h264_ladder_mode" => "ffmpeg",
          "version" => 0
        },
        dependency_outputs: %{
          "source" => %{
            "space_hash" => "ubg50",
            "embed_hash" => "LeDE9v86ye",
            "source_url" => "https://source.example/video.mp4",
            "version" => 0
          },
          "inspect_media" => %{
            "status" => "ok",
            "duration" => 5.0,
            "width" => 720,
            "height" => 1280,
            "has_audio" => false
          }
        },
        encoding_booster_dispatch: :direct
      }

      assert {:ok, output, _artifacts} =
               MediaTranscodeH264LadderStep.run(step_definition, context)

      assert output["encoding_booster_chunks"] == 3
      assert output["encoding_booster_instances"] == ["instance-test"]

      assert_receive {:encoding_booster_request, _, first_options}
      assert_receive {:encoding_booster_request, _, second_options}
      assert_receive {:encoding_booster_request, _, third_options}

      assert {first_options[:start_seconds], first_options[:duration_seconds]} == {0.0, 2.0}
      assert {second_options[:start_seconds], second_options[:duration_seconds]} == {2.0, 2.0}
      assert {third_options[:start_seconds], third_options[:duration_seconds]} == {4.0, 1.0}

      assert_receive {:encoding_booster_concat, input_paths}
      assert length(input_paths) == 3

      _ = File.rm_rf(tmp_dir)
    end
  end

  test "is registered as a FLAME media step" do
    assert StepRegistry.executor_for("media.transcode_h264_ladder") == :flame
  end

  test "produces multiple H264 variant outputs from source_body copy mode" do
    step_definition = %{
      "id" => "video_h264_ladder",
      "type" => "media.transcode_h264_ladder",
      "params" => %{"sizes" => ["sd", "hd"]}
    }

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "source_body" => "stub-media-body",
        "media_transcode_h264_ladder_mode" => "copy",
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

    assert {:ok, output, artifacts} = MediaTranscodeH264LadderStep.run(step_definition, context)
    assert output["status"] == "ok"
    assert output["step_type"] == "media.transcode_h264_ladder"
    assert output["mode"] == "copy"
    assert output["sizes"] == ["sd", "hd"]

    assert output["variant_outputs"]["sd"]["key"] == "LeDE9v86ye/h264_sd.mp4"
    assert output["variant_outputs"]["hd"]["key"] == "LeDE9v86ye/h264_hd.mp4"
    assert output["variant_outputs"]["sd"]["file_size"] == 15
    assert Enum.map(output["renditions"], & &1["size"]) == ["sd", "hd"]
    assert Enum.all?(output["renditions"], &(&1["progress"] == 100.0))

    assert [
             %{name: "video_h264_sd", media_type: "video/mp4"},
             %{name: "video_h264_hd", media_type: "video/mp4"}
           ] = artifacts

    assert {:ok, "stub-media-body"} =
             FlowStorageAdapterStub.get("space-ubg50", "LeDE9v86ye/h264_sd.mp4", nil)

    assert {:ok, "stub-media-body"} =
             FlowStorageAdapterStub.get("space-ubg50", "LeDE9v86ye/h264_hd.mp4", nil)

    assert FlowStorageAdapterStub.public?("space-ubg50", "LeDE9v86ye/h264_sd.mp4", nil)
    assert FlowStorageAdapterStub.public?("space-ubg50", "LeDE9v86ye/h264_hd.mp4", nil)
  end

  test "skips ladder variants above the inspected source resolution" do
    step_definition = %{
      "id" => "video_h264_ladder",
      "type" => "media.transcode_h264_ladder",
      "params" => %{"sizes" => ["sd", "hd", "fhd", "qhd", "uhd"]}
    }

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "source_body" => "stub-media-body",
        "media_transcode_h264_ladder_mode" => "copy",
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
          "width" => 1920,
          "duration" => 12.5
        }
      }
    }

    assert {:ok, output, artifacts} = MediaTranscodeH264LadderStep.run(step_definition, context)
    assert output["requested_sizes"] == ["sd", "hd", "fhd", "qhd", "uhd"]
    assert output["sizes"] == ["sd", "hd", "fhd"]
    assert Enum.map(output["skipped_variants"], & &1["size"]) == ["qhd", "uhd"]
    assert output["variant_outputs"]["qhd"]["status"] == "skipped"
    assert output["variant_outputs"]["qhd"]["reason"] == "source_resolution_below_variant"
    assert Enum.map(artifacts, & &1.name) == ["video_h264_sd", "video_h264_hd", "video_h264_fhd"]
  end

  test "uses source long edge when filtering portrait ladder variants" do
    step_definition = %{
      "id" => "video_h264_ladder",
      "type" => "media.transcode_h264_ladder",
      "params" => %{"sizes" => ["sd", "hd", "fhd", "qhd", "uhd"]}
    }

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "source_body" => "stub-media-body",
        "media_transcode_h264_ladder_mode" => "copy",
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
          "height" => 1920,
          "duration" => 12.5
        }
      }
    }

    assert {:ok, output, artifacts} = MediaTranscodeH264LadderStep.run(step_definition, context)
    assert output["sizes"] == ["sd", "hd", "fhd"]
    assert output["variant_outputs"]["sd"]["resolution"] == "360x640"
    assert output["variant_outputs"]["hd"]["resolution"] == "720x1280"
    assert output["variant_outputs"]["fhd"]["resolution"] == "1080x1920"
    assert Enum.map(output["skipped_variants"], & &1["size"]) == ["qhd", "uhd"]
    assert output["variant_outputs"]["qhd"]["source_width"] == 1080
    assert output["variant_outputs"]["qhd"]["source_height"] == 1920
    assert output["variant_outputs"]["qhd"]["source_long_edge"] == 1920
    assert Enum.map(artifacts, & &1.name) == ["video_h264_sd", "video_h264_hd", "video_h264_fhd"]
  end

  test "adds a source-capped HD rendition for a 1080 square source" do
    step_definition = %{
      "id" => "video_h264_ladder",
      "type" => "media.transcode_h264_ladder",
      "params" => %{"sizes" => ["sd", "hd", "fhd", "qhd", "uhd"]}
    }

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "source_body" => "stub-media-body",
        "media_transcode_h264_ladder_mode" => "copy",
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
          "height" => 1080,
          "duration" => 12.5
        }
      }
    }

    assert {:ok, output, artifacts} = MediaTranscodeH264LadderStep.run(step_definition, context)
    assert output["sizes"] == ["sd", "hd"]
    assert output["variant_outputs"]["sd"]["resolution"] == "640x640"
    assert output["variant_outputs"]["hd"]["resolution"] == "1080x1080"
    assert Enum.map(output["skipped_variants"], & &1["size"]) == ["fhd", "qhd", "uhd"]
    assert Enum.map(artifacts, & &1.name) == ["video_h264_sd", "video_h264_hd"]
  end

  test "can skip every requested variant when source resolution is required" do
    step_definition = %{
      "id" => "video_h264_ladder_high",
      "type" => "media.transcode_h264_ladder",
      "params" => %{
        "sizes" => ["qhd", "uhd"],
        "require_source_resolution" => true
      }
    }

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "source_body" => "stub-media-body",
        "media_transcode_h264_ladder_mode" => "copy",
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
          "width" => 1920,
          "duration" => 12.5
        }
      }
    }

    assert {:ok, output, []} = MediaTranscodeH264LadderStep.run(step_definition, context)
    assert output["status"] == "skipped"
    assert output["step_id"] == "video_h264_ladder_high"
    assert output["sizes"] == []
    assert output["reason"] == "source_resolution_below_variant"
  end

  test "transcodes configured variants with one ffmpeg ladder command" do
    ffmpeg_bin = System.find_executable("ffmpeg")
    ffprobe_bin = System.find_executable("ffprobe")

    if is_nil(ffmpeg_bin) or is_nil(ffprobe_bin) do
      assert true
    else
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "mave_h264_ladder_test_#{System.unique_integer([:positive])}"
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
            "testsrc=duration=1:size=1280x720:rate=24",
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

      Application.put_env(:mave_core, :encoding_booster,
        enabled: true,
        fallback_enabled: true
      )

      Application.put_env(
        :mave_core,
        :encoding_booster_adapter,
        RemuxFailedEncodingBoosterAdapterStub
      )

      step_definition = %{
        "id" => "video_h264_ladder",
        "type" => "media.transcode_h264_ladder",
        "params" => %{
          "sizes" => ["sd", "hd"],
          "prepackage_frames" => ["poster", "thumbnail", "placeholder"]
        }
      }

      context = %{
        run_input: %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "source_content_type" => "video/mp4",
          "media_transcode_h264_ladder_mode" => "ffmpeg",
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
            "duration" => 1,
            "has_audio" => true,
            "streams" => [
              %{
                "codec_type" => "audio",
                "codec_tag_string" => "apac"
              }
            ]
          }
        }
      }

      assert {:ok, output, artifacts} = MediaTranscodeH264LadderStep.run(step_definition, context)
      assert output["status"] == "ok"
      assert output["mode"] == "ffmpeg"
      assert output["encoding_booster_fallback"] == "remux_failed"
      assert output["encoder"] == %{"preset" => "veryfast"}
      assert output["variant_outputs"]["sd"]["file_size"] > 0
      assert output["variant_outputs"]["hd"]["file_size"] > 0
      assert output["hls_prepackaged_sizes"] == ["hd", "sd"]

      assert output["variant_outputs"]["sd"]["hls"]["playlist_key"] ==
               "LeDE9v86ye/h264_sd_hls/playlist.m3u8"

      assert output["variant_outputs"]["hd"]["hls"]["playlist_key"] ==
               "LeDE9v86ye/h264_hd_hls/playlist.m3u8"

      assert output["variant_outputs"]["sd"]["hls"]["resolution"] == "640x360"
      assert output["variant_outputs"]["hd"]["hls"]["resolution"] == "1280x720"

      assert output["frame_prepackaged"] == ["placeholder:jpg", "poster:jpg", "thumbnail:jpg"]
      assert output["frame_outputs"]["poster:jpg"]["key"] == "LeDE9v86ye/poster.jpg"
      assert output["frame_outputs"]["poster:jpg"]["source_size"] == "hd"
      assert output["frame_outputs"]["thumbnail:jpg"]["key"] == "LeDE9v86ye/thumbnail.jpg"
      assert output["frame_outputs"]["thumbnail:jpg"]["source_size"] == "sd"
      assert output["frame_outputs"]["placeholder:jpg"]["key"] == "LeDE9v86ye/placeholder.jpg"
      assert output["frame_outputs"]["placeholder:jpg"]["source_size"] == "sd"

      assert Enum.map(artifacts, & &1.name) == ["video_h264_sd", "video_h264_hd"]

      assert {:ok, sd_body} =
               FlowStorageAdapterStub.get("space-ubg50", "LeDE9v86ye/h264_sd.mp4", nil)

      assert {:ok, hd_body} =
               FlowStorageAdapterStub.get("space-ubg50", "LeDE9v86ye/h264_hd.mp4", nil)

      assert byte_size(sd_body) > 0
      assert byte_size(hd_body) > 0

      sd_output_path = Path.join(tmp_dir, "h264_sd.mp4")
      File.write!(sd_output_path, sd_body)
      assert_video_only_mp4(ffprobe_bin, sd_output_path)

      assert {:ok, sd_playlist} =
               FlowStorageAdapterStub.get(
                 "space-ubg50",
                 "LeDE9v86ye/h264_sd_hls/playlist.m3u8",
                 nil
               )

      assert {:ok, hd_playlist} =
               FlowStorageAdapterStub.get(
                 "space-ubg50",
                 "LeDE9v86ye/h264_hd_hls/playlist.m3u8",
                 nil
               )

      assert String.contains?(sd_playlist, "#EXTM3U")
      assert String.contains?(hd_playlist, "#EXTM3U")

      assert {:ok, poster_body} =
               FlowStorageAdapterStub.get("space-ubg50", "LeDE9v86ye/poster.jpg", nil)

      assert {:ok, thumbnail_body} =
               FlowStorageAdapterStub.get("space-ubg50", "LeDE9v86ye/thumbnail.jpg", nil)

      assert {:ok, placeholder_body} =
               FlowStorageAdapterStub.get("space-ubg50", "LeDE9v86ye/placeholder.jpg", nil)

      assert byte_size(poster_body) > 0
      assert byte_size(thumbnail_body) > 0
      assert byte_size(placeholder_body) > 0

      _ = File.rm_rf(tmp_dir)
    end
  end

  test "uses the encoding booster for an eligible H264 ladder encode" do
    ffmpeg_bin = System.find_executable("ffmpeg")
    ffprobe_bin = System.find_executable("ffprobe")

    if is_nil(ffmpeg_bin) or is_nil(ffprobe_bin) do
      assert true
    else
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "mave_h264_ladder_booster_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      fixture_path = Path.join(tmp_dir, "booster-output.mp4")

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
            fixture_path
          ],
          stderr_to_stdout: true
        )

      Application.put_env(:mave_core, :encoding_booster,
        enabled: true,
        fallback_enabled: false
      )

      Application.put_env(
        :mave_core,
        :encoding_booster_adapter,
        EncodingBoosterAdapterStub
      )

      Application.put_env(:mave_core, :encoding_booster_adapter_stub,
        fixture_path: fixture_path,
        owner: self()
      )

      assert {:ok, _body} =
               FlowStorageAdapterStub.put_public(
                 "space-ubg50",
                 "LeDE9v86ye/h264_sd.mp4",
                 "stale-rendition",
                 "video/mp4",
                 nil
               )

      old_upload_config = Application.get_env(:mave_core, :upload)

      Application.put_env(:mave_core, :upload, source_base_url: "https://source.example")

      on_exit(fn -> restore_env(:upload, old_upload_config) end)

      step_definition = %{
        "id" => "video_h264_ladder",
        "type" => "media.transcode_h264_ladder",
        "params" => %{"sizes" => ["sd"]}
      }

      context = %{
        run_input: %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "media_transcode_h264_ladder_mode" => "ffmpeg",
          "version" => 0
        },
        dependency_outputs: %{
          "source" => %{
            "space_hash" => "ubg50",
            "embed_hash" => "LeDE9v86ye",
            "source_url" => "https://source.example/video.mp4",
            "version" => 0
          },
          "inspect_media" => %{
            "status" => "ok",
            "duration" => 1,
            "width" => 720,
            "height" => 1280,
            "has_audio" => true
          }
        },
        progress_reporter: self(),
        encoding_booster_dispatch: :direct
      }

      assert {:ok, output, _artifacts} =
               MediaTranscodeH264LadderStep.run(step_definition, context)

      assert output["status"] == "ok"
      assert output["mode"] == "encoding_booster"
      assert output["encoding_booster"] == true
      assert output["encoding_booster_elapsed_ms"] == 25
      assert output["encoding_booster_variants"] == ["sd"]
      assert output["encoding_booster_instances"] == ["instance-test"]
      assert output["variant_outputs"]["sd"]["file_size"] > 0
      assert output["variant_outputs"]["sd"]["resolution"] == "360x640"
      refute Map.has_key?(output, "frame_prepackaged")
      refute Map.has_key?(output, "hls_prepackaged_sizes")
      refute Map.has_key?(output["variant_outputs"]["sd"], "hls")

      assert {:ok, refreshed_rendition} =
               FlowStorageAdapterStub.get(
                 "space-ubg50",
                 "LeDE9v86ye/h264_sd.mp4",
                 nil
               )

      assert refreshed_rendition == File.read!(fixture_path)

      assert FlowStorageAdapterStub.multipart_upload_opts(
               "space-ubg50",
               "LeDE9v86ye/h264_sd.mp4",
               nil
             )[:max_bytes] ==
               round((2_000_000 + 128_000) / 8 * 2.0) + 8 * 1024 * 1024

      assert_receive {:encoding_booster_request, "https://source.example/video.mp4", options}
      assert options[:encoding_profile] == "mave-production-v2"
      assert options[:width] == 640
      assert options[:video_bitrate] == "2M"
      assert options[:audio_bitrate] == "128k"
      assert options[:preset] == "veryfast"
      assert options[:include_audio] == true
      assert options[:keyframe_interval_seconds] == 2
      assert options[:gop_frames] == 250
      refute Keyword.has_key?(options, :package_hls)
      assert options[:input_referer] == Storage.ffmpeg_input_referer()
      assert is_function(options[:on_chunk], 1)

      assert_receive {:"$gen_cast",
                      {:progress,
                       %{
                         "source" => "encoding_booster",
                         "status" => "started",
                         "size" => "sd",
                         "percent" => 1.0,
                         "total_size_bytes" => 0,
                         "force" => true
                       }}}

      assert_receive {:"$gen_cast",
                      {:progress,
                       %{
                         "source" => "encoding_booster",
                         "status" => "executing",
                         "size" => "sd",
                         "percent" => percent,
                         "ratio" => ratio,
                         "out_time_ms" => out_time_ms,
                         "total_size_bytes" => 2_048
                       }}}

      assert percent >= 1.0
      assert ratio > 0.0
      assert out_time_ms > 0

      assert_receive {:"$gen_cast",
                      {:progress,
                       %{
                         "source" => "encoding_booster",
                         "status" => "executing",
                         "size" => "sd",
                         "percent" => ^percent,
                         "ratio" => ^ratio,
                         "total_size_bytes" => 2_048
                       }}}

      assert_receive {:"$gen_cast",
                      {:progress,
                       %{
                         "source" => "ffmpeg",
                         "executor" => "encoding_booster",
                         "status" => "completed",
                         "size" => "sd",
                         "ffmpeg_elapsed_ms" => 20,
                         "fps" => 1_200.0,
                         "speed_x" => 50.0,
                         "frame" => 24
                       }}}

      resumed_context =
        Map.put(context, :execution_metadata, %{
          "progress" => %{
            "source" => "encoding_booster",
            "stage" => "transcode",
            "size" => "sd",
            "percent" => 37.6,
            "total_size_bytes" => 100_000,
            "ffmpeg_elapsed_ms" => 1_000
          }
        })

      assert {:ok, _output, _artifacts} =
               MediaTranscodeH264LadderStep.run(step_definition, resumed_context)

      assert_receive {:encoding_booster_request, "https://source.example/video.mp4", _options}

      assert_receive {:"$gen_cast",
                      {:progress,
                       %{
                         "source" => "encoding_booster",
                         "status" => "executing",
                         "size" => "sd",
                         "percent" => resumed_percent,
                         "total_size_bytes" => 100_000,
                         "ffmpeg_elapsed_ms" => resumed_elapsed_ms,
                         "force" => true
                       }}}

      assert resumed_percent > 30.0
      assert resumed_elapsed_ms >= 1_000

      _ = File.rm_rf(tmp_dir)
    end
  end

  test "direct booster dispatch keeps busy work on the booster retry path" do
    Application.put_env(:mave_core, :encoding_booster,
      enabled: true,
      fallback_enabled: true
    )

    Application.put_env(
      :mave_core,
      :encoding_booster_adapter,
      BusyEncodingBoosterAdapterStub
    )

    step_definition = %{
      "id" => "video_h264_ladder",
      "type" => "media.transcode_h264_ladder",
      "params" => %{"sizes" => ["sd"]}
    }

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "media_transcode_h264_ladder_mode" => "ffmpeg",
        "version" => 0
      },
      dependency_outputs: %{
        "source" => %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "source_url" => "https://source.example/video.mp4",
          "version" => 0
        }
      },
      encoding_booster_dispatch: :direct
    }

    assert {:error, {:media_transcode_h264_ladder_failed, :encoding_booster_busy}} =
             MediaTranscodeH264LadderStep.run(step_definition, context)
  end

  test "direct booster dispatch reports a remux-specific fallback" do
    Application.put_env(:mave_core, :encoding_booster,
      enabled: true,
      fallback_enabled: true
    )

    Application.put_env(
      :mave_core,
      :encoding_booster_adapter,
      RemuxFailedEncodingBoosterAdapterStub
    )

    step_definition = %{
      "id" => "video_h264_ladder",
      "type" => "media.transcode_h264_ladder",
      "params" => %{"sizes" => ["sd"]}
    }

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "media_transcode_h264_ladder_mode" => "ffmpeg",
        "version" => 0
      },
      dependency_outputs: %{
        "source" => %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "source_url" => "https://source.example/video.mp4",
          "version" => 0
        }
      },
      encoding_booster_dispatch: :direct
    }

    assert {:error,
            {:encoding_booster_fallback_required, "remux_failed",
             {:encoding_booster_remux_failed, 1}}} =
             MediaTranscodeH264LadderStep.run(step_definition, context)
  end

  test "honors configured H264 encoder preset and tune" do
    ffmpeg_bin = System.find_executable("ffmpeg")

    if is_nil(ffmpeg_bin) do
      assert true
    else
      Application.put_env(:mave_core, :media_h264_ladder_encoder,
        preset: "ultrafast",
        tune: "fastdecode"
      )

      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "mave_h264_ladder_encoder_config_test_#{System.unique_integer([:positive])}"
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
            "testsrc=duration=1:size=640x360:rate=24",
            "-pix_fmt",
            "yuv420p",
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
        "id" => "video_h264_ladder",
        "type" => "media.transcode_h264_ladder",
        "params" => %{"sizes" => ["sd"]}
      }

      context = %{
        run_input: %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "source_content_type" => "video/mp4",
          "media_transcode_h264_ladder_mode" => "ffmpeg",
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

      assert {:ok, output, _artifacts} =
               MediaTranscodeH264LadderStep.run(step_definition, context)

      assert output["status"] == "ok"
      assert output["encoder"] == %{"preset" => "ultrafast", "tune" => "fastdecode"}

      _ = File.rm_rf(tmp_dir)
    end
  end

  test "returns unavailable output in non-strict mode on unsupported size" do
    step_definition = %{
      "id" => "video_h264_ladder",
      "type" => "media.transcode_h264_ladder",
      "params" => %{"sizes" => ["tiny"]}
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

    assert {:ok, output, []} = MediaTranscodeH264LadderStep.run(step_definition, context)
    assert output["status"] == "unavailable"
    assert output["step_type"] == "media.transcode_h264_ladder"
    assert output["error"] =~ "unsupported_size"
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)

  defp assert_video_only_mp4(ffprobe_bin, output_path) do
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
  end
end
