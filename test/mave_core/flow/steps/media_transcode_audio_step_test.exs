defmodule MaveCore.Flow.Steps.MediaTranscodeAudioStepTest do
  use ExUnit.Case, async: false

  alias MaveCore.Flow.Steps.MediaTranscodeAudioStep
  alias MaveCore.TestSupport.FlowStorageAdapterStub

  defmodule EncodingBoosterAdapterStub do
    def audio_body do
      frame = <<0xFF, 0xFB, 0x90, 0x64>> <> :binary.copy(<<0>>, 413)
      frame <> frame
    end

    def encode_to_storage(input_url, upload, options) do
      send(Application.fetch_env!(:mave_core, :encoding_booster_test_pid), {
        :audio_booster_request,
        input_url,
        options
      })

      {:ok, _body} =
        FlowStorageAdapterStub.put_public(
          upload["test_bucket"],
          upload["test_path"],
          audio_body(),
          upload["test_content_type"],
          upload["test_region"]
        )

      {:ok,
       %{
         elapsed_ms: 25,
         ffmpeg_elapsed_ms: 20,
         out_time_ms: 10_000_000,
         output_bytes: byte_size(audio_body()),
         instance_id: "audio-instance"
       }}
    end
  end

  defmodule HeaderOnlyEncodingBoosterAdapterStub do
    def encode_to_storage(_input_url, upload, _options) do
      header = <<"ID3", 4, 0, 0, 0, 0, 0, 34>> <> :binary.copy(<<0>>, 34)

      {:ok, _body} =
        FlowStorageAdapterStub.put_public(
          upload["test_bucket"],
          upload["test_path"],
          header,
          upload["test_content_type"],
          upload["test_region"]
        )

      {:ok, %{elapsed_ms: 25, ffmpeg_elapsed_ms: 20, output_bytes: byte_size(header)}}
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

  test "streams audio from object storage through the CPU booster into object storage" do
    step_definition = %{
      "id" => "transcode_audio",
      "type" => "media.transcode_audio",
      "params" => %{"codec" => "mp3", "container" => "mp3", "strict" => true}
    }

    context = %{
      run_input: %{
        "space_hash" => "qingb",
        "embed_hash" => "audio12345",
        "source_bucket" => "mave-upload",
        "source_key" => "qingb/source.mp4",
        "source_region" => "qingb",
        "version" => 1
      },
      dependency_outputs: %{
        "source" => %{
          "space_hash" => "qingb",
          "embed_hash" => "audio12345",
          "source_url" => "https://storage.example/mave-upload/qingb/source.mp4",
          "version" => 1
        },
        "inspect_media" => %{
          "duration" => 10.0,
          "streams" => [%{"codec_type" => "audio", "codec_name" => "aac"}]
        }
      },
      encoding_booster_dispatch: :direct
    }

    assert {:ok, output, [_artifact]} =
             MediaTranscodeAudioStep.run(step_definition, context)

    assert output["mode"] == "encoding_booster"
    assert output["key"] == "audio12345/v1/audio.mp3"
    assert output["file_size"] == byte_size(EncodingBoosterAdapterStub.audio_body())
    assert output["encoding_booster_instances"] == ["audio-instance"]

    assert_receive {:audio_booster_request, input_url, options}
    assert input_url =~ "mave-upload/qingb/source.mp4"
    assert options[:operation] == "audio"
    assert options[:audio_codec] == "mp3"
    assert options[:audio_stream_index] == 0
  end

  test "rejects an ID3-only booster output before marking audio successful" do
    Application.put_env(
      :mave_core,
      :encoding_booster_adapter,
      HeaderOnlyEncodingBoosterAdapterStub
    )

    step_definition = %{
      "id" => "transcode_audio",
      "type" => "media.transcode_audio",
      "params" => %{"codec" => "mp3", "container" => "mp3", "strict" => true}
    }

    context = %{
      run_input: %{
        "space_hash" => "qingb",
        "embed_hash" => "audio12345",
        "source_bucket" => "mave-upload",
        "source_key" => "qingb/source.mp4",
        "source_region" => "qingb",
        "version" => 1
      },
      dependency_outputs: %{
        "source" => %{
          "space_hash" => "qingb",
          "embed_hash" => "audio12345",
          "source_url" => "https://storage.example/mave-upload/qingb/source.mp4",
          "version" => 1
        },
        "inspect_media" => %{
          "duration" => 10.0,
          "streams" => [%{"codec_type" => "audio", "codec_name" => "aac"}]
        }
      },
      encoding_booster_dispatch: :direct
    }

    assert {:error,
            {:encoding_booster_fallback_required, "invalid_output",
             {:audio_upload_verification_failed, :missing_audio_frames}}} =
             MediaTranscodeAudioStep.run(step_definition, context)

    assert {:error, :not_found} =
             FlowStorageAdapterStub.get(
               "space-qingb",
               "audio12345/v1/audio.mp3",
               "qingb"
             )
  end

  test "produces audio track artifact from source_body copy mode" do
    step_definition = %{
      "id" => "transcode_audio",
      "type" => "media.transcode_audio",
      "params" => %{"codec" => "aac", "container" => "m4a", "label" => "Original"}
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

    assert {:ok, output, artifacts} = MediaTranscodeAudioStep.run(step_definition, context)
    assert output["status"] == "ok"
    assert output["mode"] == "copy"
    assert output["codec"] == "aac"
    assert output["container"] == "m4a"
    assert output["key"] == "LeDE9v86ye/audio_aac.m4a"
    assert output["uri"] == "s3://space-ubg50/LeDE9v86ye/audio_aac.m4a"
    assert output["file_size"] == 15
    assert is_map(output["audio_track"])
    assert output["audio_track"]["filename"] == "audio_aac.m4a"
    assert output["audio_track"]["src"] == "s3://space-ubg50/LeDE9v86ye/audio_aac.m4a"
    assert output["rendition"]["type"] == "audio"
    assert output["rendition"]["progress"] == 100.0
    assert output["rendition"]["rendition_key"] == "LeDE9v86ye/audio_aac.m4a"
    assert is_list(output["renditions"])
    assert hd(output["renditions"])["type"] == "audio"

    assert [%{name: "audio_aac", uri: uri}] = artifacts
    assert uri == "s3://space-ubg50/LeDE9v86ye/audio_aac.m4a"
  end

  test "returns unavailable output in non-strict mode on missing source" do
    step_definition = %{
      "id" => "transcode_audio",
      "type" => "media.transcode_audio",
      "params" => %{"codec" => "aac", "container" => "m4a"}
    }

    context = %{
      run_input: %{"space_hash" => "ubg50", "embed_hash" => "LeDE9v86ye"},
      dependency_outputs: %{"source" => %{"space_hash" => "ubg50", "embed_hash" => "LeDE9v86ye"}}
    }

    assert {:ok, output, []} = MediaTranscodeAudioStep.run(step_definition, context)
    assert output["status"] == "unavailable"
    assert output["step_type"] == "media.transcode_audio"
  end

  test "returns error in strict mode on missing source" do
    step_definition = %{
      "id" => "transcode_audio",
      "type" => "media.transcode_audio",
      "params" => %{"codec" => "aac", "container" => "m4a"}
    }

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "media_transcode_audio_strict" => true
      },
      dependency_outputs: %{"source" => %{"space_hash" => "ubg50", "embed_hash" => "LeDE9v86ye"}}
    }

    assert {:error, {:media_transcode_audio_failed, {:missing_field, :source_url}}} =
             MediaTranscodeAudioStep.run(step_definition, context)
  end

  test "returns skipped output in auto mode when input has no audio stream" do
    ffmpeg_bin = System.find_executable("ffmpeg")

    if is_nil(ffmpeg_bin) do
      :ok
    else
      input_path =
        Path.join(
          System.tmp_dir!(),
          "mave_no_audio_#{System.unique_integer([:positive])}.mp4"
        )

      {_, 0} =
        System.cmd(
          ffmpeg_bin,
          [
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-f",
            "lavfi",
            "-i",
            "color=c=black:s=320x240:d=1",
            "-an",
            input_path
          ],
          stderr_to_stdout: true
        )

      step_definition = %{
        "id" => "transcode_audio",
        "type" => "media.transcode_audio",
        "params" => %{"codec" => "mp3", "container" => "mp3"}
      }

      context = %{
        run_input: %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "media_transcode_audio_strict" => true,
          "input_url" => input_path
        },
        dependency_outputs: %{
          "source" => %{
            "space_hash" => "ubg50",
            "embed_hash" => "LeDE9v86ye",
            "source_url" => input_path,
            "version" => 0
          }
        }
      }

      assert {:ok, output, []} = MediaTranscodeAudioStep.run(step_definition, context)
      assert output["status"] == "skipped"
      assert output["mode"] == "skipped"
      assert output["reason"] == "no audio stream"

      File.rm(input_path)
    end
  end

  test "returns skipped output when inspect reports only undecodable audio streams" do
    step_definition = %{
      "id" => "transcode_audio",
      "type" => "media.transcode_audio",
      "params" => %{"codec" => "mp3", "container" => "mp3", "strict" => true}
    }

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "input_url" => "https://example.com/video.mp4"
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
          "step_type" => "media.inspect",
          "has_audio" => true,
          "audio_codec" => "none",
          "streams" => [
            %{
              "codec_type" => "audio",
              "codec_name" => "none",
              "codec_tag_string" => "apac"
            }
          ]
        }
      }
    }

    assert {:ok, output, []} = MediaTranscodeAudioStep.run(step_definition, context)
    assert output["status"] == "skipped"
    assert output["mode"] == "skipped"
    assert output["reason"] == "no decodable audio stream"
  end

  test "ignores undecodable secondary audio stream" do
    ffmpeg_bin = System.find_executable("ffmpeg")

    if is_nil(ffmpeg_bin) do
      :ok
    else
      input_path =
        Path.join(
          System.tmp_dir!(),
          "mave_secondary_undecodable_audio_#{System.unique_integer([:positive])}.mp4"
        )

      {_, 0} =
        System.cmd(
          ffmpeg_bin,
          [
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-f",
            "lavfi",
            "-i",
            "color=c=black:s=320x240:d=1",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=1000:duration=1",
            "-map",
            "0:v:0",
            "-map",
            "1:a:0",
            "-c:v",
            "mpeg4",
            "-c:a",
            "aac",
            "-shortest",
            input_path
          ],
          stderr_to_stdout: true
        )

      step_definition = %{
        "id" => "transcode_audio",
        "type" => "media.transcode_audio",
        "params" => %{"codec" => "mp3", "container" => "mp3", "strict" => true}
      }

      context = %{
        run_input: %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => input_path
        },
        dependency_outputs: %{
          "source" => %{
            "space_hash" => "ubg50",
            "embed_hash" => "LeDE9v86ye",
            "source_url" => input_path,
            "version" => 0
          },
          "inspect_media" => %{
            "status" => "ok",
            "step_type" => "media.inspect",
            "duration" => 1.0,
            "has_audio" => true,
            "audio_codec" => "aac",
            "streams" => [
              %{"codec_type" => "video"},
              %{
                "codec_type" => "audio",
                "codec_name" => "aac",
                "disposition" => %{"default" => 1}
              },
              %{
                "codec_type" => "audio",
                "codec_tag_string" => "apac",
                "codec_tag" => "0x63617061"
              }
            ]
          }
        },
        progress_reporter: self()
      }

      assert {:ok, output, artifacts} = MediaTranscodeAudioStep.run(step_definition, context)
      assert output["status"] == "ok"
      assert length(output["audio_tracks"]) == 1
      assert length(output["renditions"]) == 1
      assert length(artifacts) == 1
      assert output["audio_track"]["filename"] == "audio.mp3"

      assert_receive {:"$gen_cast",
                      {:progress,
                       %{
                         "source" => "ffmpeg",
                         "status" => "completed",
                         "step_id" => "transcode_audio",
                         "codec" => "mp3",
                         "container" => "mp3",
                         "speed_x" => speed_x,
                         "ffmpeg_elapsed_ms" => elapsed_ms
                       }}}

      assert is_number(speed_x) and speed_x > 0
      assert is_integer(elapsed_ms) and elapsed_ms > 0

      File.rm(input_path)
    end
  end

  test "emits one logical audio track per source audio stream" do
    ffmpeg_bin = System.find_executable("ffmpeg")

    if is_nil(ffmpeg_bin) do
      :ok
    else
      input_path =
        Path.join(
          System.tmp_dir!(),
          "mave_multi_audio_#{System.unique_integer([:positive])}.mp4"
        )

      {_, 0} =
        System.cmd(
          ffmpeg_bin,
          [
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-f",
            "lavfi",
            "-i",
            "color=c=black:s=320x240:d=1",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=1000:duration=1",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=500:duration=1",
            "-map",
            "0:v:0",
            "-map",
            "1:a:0",
            "-map",
            "2:a:0",
            "-c:v",
            "mpeg4",
            "-c:a",
            "aac",
            "-shortest",
            input_path
          ],
          stderr_to_stdout: true
        )

      step_definition = %{
        "id" => "transcode_audio",
        "type" => "media.transcode_audio",
        "params" => %{"codec" => "mp3", "container" => "mp3", "label" => "Original"}
      }

      context = %{
        run_input: %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "input_url" => input_path
        },
        dependency_outputs: %{
          "source" => %{
            "space_hash" => "ubg50",
            "embed_hash" => "LeDE9v86ye",
            "source_url" => input_path,
            "version" => 0
          },
          "inspect_media" => %{
            "status" => "ok",
            "step_type" => "media.inspect",
            "has_audio" => true,
            "streams" => [
              %{"codec_type" => "video"},
              %{
                "codec_type" => "audio",
                "codec_name" => "aac",
                "disposition" => %{"default" => 1},
                "tags" => %{"language" => "en"}
              },
              %{"codec_type" => "audio", "codec_name" => "aac", "tags" => %{"language" => "nl"}}
            ]
          }
        }
      }

      assert {:ok, output, artifacts} = MediaTranscodeAudioStep.run(step_definition, context)
      assert length(output["audio_tracks"]) == 2
      assert length(output["renditions"]) == 2
      assert length(artifacts) == 2

      [default_track, second_track] = output["audio_tracks"]
      assert default_track["default"] == true
      assert default_track["language"] == "en"
      assert default_track["filename"] == "audio.mp3"
      assert second_track["default"] == false
      assert second_track["language"] == "nl"
      assert second_track["filename"] == "track_2_mp3.mp3"

      File.rm(input_path)
    end
  end

  test "rejects invalid ffmpeg output before uploading audio" do
    if is_nil(System.find_executable("ffprobe")) do
      :ok
    else
      with_fake_ffmpeg(fn ->
        step_definition = %{
          "id" => "transcode_audio",
          "type" => "media.transcode_audio",
          "params" => %{"codec" => "mp3", "container" => "mp3", "strict" => true}
        }

        context = %{
          run_input: %{
            "space_hash" => "ubg50",
            "embed_hash" => "LeDE9v86ye",
            "input_url" => "/tmp/input.mp4"
          },
          dependency_outputs: %{
            "source" => %{
              "space_hash" => "ubg50",
              "embed_hash" => "LeDE9v86ye",
              "source_url" => "/tmp/input.mp4",
              "version" => 0
            },
            "inspect_media" => %{
              "status" => "ok",
              "has_audio" => true,
              "streams" => [%{"codec_type" => "audio", "codec_name" => "aac"}]
            }
          }
        }

        assert {:error, {:media_transcode_audio_failed, {:invalid_media_output, :audio, _reason}}} =
                 MediaTranscodeAudioStep.run(step_definition, context)

        assert {:error, :not_found} =
                 FlowStorageAdapterStub.get("space-ubg50", "LeDE9v86ye/audio.mp3", nil)
      end)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)

  defp with_fake_ffmpeg(fun) when is_function(fun, 0) do
    old_path = System.get_env("PATH") || ""

    bin_dir =
      Path.join(System.tmp_dir!(), "mave_fake_ffmpeg_#{System.unique_integer([:positive])}")

    script_path = Path.join(bin_dir, "ffmpeg")

    File.mkdir_p!(bin_dir)

    File.write!(script_path, """
    #!/bin/sh
    for last do true; done
    printf 'not-an-mp3' > "$last"
    exit 0
    """)

    File.chmod!(script_path, 0o755)
    System.put_env("PATH", bin_dir <> ":" <> old_path)

    try do
      fun.()
    after
      System.put_env("PATH", old_path)
      File.rm_rf(bin_dir)
    end
  end
end
