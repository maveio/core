defmodule MaveCore.Flow.Steps.MediaInspectStepTest do
  use ExUnit.Case, async: false

  alias MaveCore.Flow.Steps.MediaInspectStep
  alias MaveCore.TestSupport.FlowStorageAdapterStub

  defmodule PrefixReadFailingStorageAdapter do
    @moduledoc false

    def get_prefix(_bucket, _path, _region, _max_bytes), do: {:error, :range_not_supported}

    defdelegate download_to_file(bucket, path, destination_path, region),
      to: FlowStorageAdapterStub

    defdelegate delete_object(bucket, path, region), to: FlowStorageAdapterStub
  end

  @safe_input_formats "aac,aiff,amr,avi,flac,flv,matroska,webm,mov,mp3,mpeg,mpegts,mpegvideo,ogg,wav"

  setup do
    old_storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter)

    Application.put_env(
      :mave_core,
      :flow_storage_adapter,
      FlowStorageAdapterStub
    )

    FlowStorageAdapterStub.reset!()

    on_exit(fn ->
      FlowStorageAdapterStub.reset!()
      restore_env(:flow_storage_adapter, old_storage_adapter)
    end)

    :ok
  end

  test "uses media_probe override when provided" do
    context = %{
      run_input: %{
        "media_probe" => %{
          "duration" => 10.0,
          "size_bytes" => 1_000_000,
          "filetype" => "mp4",
          "aspect_ratio" => "16 / 9",
          "video_id" => "video-123",
          "streams" => [
            %{"codec_type" => "video", "codec_name" => "h264", "width" => 1280, "height" => 720},
            %{"codec_type" => "audio", "codec_name" => "aac"}
          ]
        }
      },
      dependency_outputs: %{
        "source" => %{"source_url" => "https://example.com/video.mp4"}
      }
    }

    assert {:ok, output, []} = MediaInspectStep.run(%{}, context)

    assert output["status"] == "ok"
    assert output["step_type"] == "media.inspect"
    assert output["duration"] == 10.0
    assert output["size_bytes"] == 1_000_000
    assert output["filetype"] == "mp4"
    assert output["aspect_ratio"] == "16 / 9"
    assert output["video_id"] == "video-123"
    assert output["video_codec"] == "h264"
    assert output["audio_codec"] == "aac"
    assert output["has_audio"] == true
  end

  test "treats audio with attached cover artwork as audio-only" do
    streams = [
      %{"codec_type" => "audio", "codec_name" => "mp3"},
      %{
        "codec_type" => "video",
        "codec_name" => "mjpeg",
        "width" => 600,
        "height" => 600,
        "disposition" => %{"attached_pic" => 1}
      }
    ]

    context = %{
      run_input: %{"media_probe" => %{"duration" => 3193.45, "streams" => streams}}
    }

    assert {:ok, output, []} = MediaInspectStep.run(%{}, context)
    assert output["has_audio"] == true
    assert output["has_video"] == false
    assert output["audio_codec"] == "mp3"
    assert output["video_codec"] == nil
    assert output["width"] == nil
    assert output["height"] == nil
    assert output["duration"] == 3193.45
    assert output["streams"] == streams
  end

  test "uses the real video stream when cover artwork precedes it" do
    context = %{
      run_input: %{
        "media_probe" => %{
          "streams" => [
            %{
              "codec_type" => "video",
              "codec_name" => "mjpeg",
              "width" => 600,
              "height" => 600,
              "disposition" => %{"attached_pic" => 1}
            },
            %{
              "codec_type" => "video",
              "codec_name" => "h264",
              "width" => 1920,
              "height" => 1080,
              "disposition" => %{"attached_pic" => 0}
            }
          ]
        }
      }
    }

    assert {:ok, output, []} = MediaInspectStep.run(%{}, context)
    assert output["has_video"] == true
    assert output["video_codec"] == "h264"
    assert output["width"] == 1920
    assert output["height"] == 1080
    assert output["aspect_ratio"] == "16 / 9"
  end

  test "accepts numeric probe fields without string parsing failures" do
    context = %{
      run_input: %{
        "media_probe" => %{
          "format" => %{"duration" => 0, "size" => 0},
          "streams" => [
            %{"codec_type" => "video", "codec_name" => "h264", "width" => 0, "height" => 0}
          ]
        }
      },
      dependency_outputs: %{
        "source" => %{"source_url" => "https://example.com/video.mp4"}
      }
    }

    assert {:ok, output, []} = MediaInspectStep.run(%{}, context)
    assert output["duration"] == 0.0
    assert output["size_bytes"] == 0
    assert output["width"] == 0
    assert output["height"] == 0
  end

  test "decodes ffprobe json when warnings are emitted before the payload" do
    output = """
    [mov,mp4,m4a,3gp,3g2,mj2 @ 0x5e6798d22d80] Referenced QT chapter track not found
    {
      "streams": [
        {"codec_type": "video", "codec_name": "h264", "width": 1920, "height": 1080}
      ],
      "format": {"duration": "10.0", "size": "1234", "format_name": "mov,mp4,m4a"}
    }
    """

    assert {:ok, payload} = MediaInspectStep.decode_probe_output(output)
    assert get_in(payload, ["format", "duration"]) == "10.0"
    assert [%{"codec_type" => "video"}] = payload["streams"]
  end

  test "returns unavailable output in non-strict mode when source is missing" do
    context = %{
      run_input: %{},
      dependency_outputs: %{}
    }

    assert {:ok, output, []} = MediaInspectStep.run(%{}, context)
    assert output["status"] == "unavailable"
    assert output["step_type"] == "media.inspect"
  end

  test "returns error in strict mode when source is missing" do
    context = %{
      run_input: %{"media_inspect_strict" => true},
      dependency_outputs: %{}
    }

    assert {:error, {:media_inspect_failed, {:missing_field, :source_url}}} =
             MediaInspectStep.run(%{}, context)
  end

  test "durable remote runs fail closed until the uploaded original is available" do
    context = %{
      run_input: %{"durable_source_required" => true, "media_inspect_strict" => true},
      dependency_outputs: %{
        "source" => %{"source_url" => "https://tenant.example/video.mp4"}
      }
    }

    assert {:error, {:media_inspect_failed, :durable_media_source_required}} =
             MediaInspectStep.run(%{}, context)
  end

  test "uses authenticated storage source for uploads when source bucket metadata is present" do
    assert {:ok, _body} =
             FlowStorageAdapterStub.put(
               "example-uploads",
               "uploads/video.mp4",
               "stub-media-body",
               "video/mp4",
               "fr-par"
             )

    context = %{
      run_input: %{
        "source_bucket" => "example-uploads",
        "source_key" => "uploads/video.mp4",
        "source_region" => "fr-par",
        "source_content_type" => "video/mp4",
        "media_probe" => %{
          "duration" => 5.0,
          "size_bytes" => 15,
          "filetype" => "mp4",
          "streams" => [
            %{"codec_type" => "video", "codec_name" => "h264", "width" => 1280, "height" => 720}
          ]
        }
      },
      dependency_outputs: %{
        "source" => %{
          "source_url" => "https://s3.fr-par.scw.cloud/example-uploads/uploads/video.mp4"
        }
      }
    }

    assert {:ok, output, []} = MediaInspectStep.run(%{}, context)
    assert output["status"] == "ok"
    assert output["filetype"] == "mp4"
  end

  test "validates stored bytes before probing the tusd upload URL directly" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mave_direct_ffprobe_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    ffprobe_path = Path.join(tmp_dir, "ffprobe")
    capture_path = Path.join(tmp_dir, "captured_input")
    old_path = System.get_env("PATH") || ""

    File.write!(ffprobe_path, """
    #!/bin/sh
    printf '%s\n' "$@" > "#{capture_path}"
    printf '%s\n' '{"streams":[{"codec_type":"video","codec_name":"h264","width":1280,"height":720}],"format":{"duration":"2.0","size":"1234","format_name":"mov,mp4"}}'
    """)

    File.chmod!(ffprobe_path, 0o755)
    System.put_env("PATH", tmp_dir <> ":" <> old_path)

    on_exit(fn ->
      System.put_env("PATH", old_path)
      _ = File.rm_rf(tmp_dir)
    end)

    upload_url = "https://uploads.test/mave-upload/uploads/video.mp4"

    assert {:ok, _body} =
             FlowStorageAdapterStub.put(
               "missing-upload-bucket",
               "uploads/video.mp4",
               <<0, 0, 0, 24, "ftyp", "isom", 0::128>>,
               "video/mp4",
               nil
             )

    context = %{
      run_input: %{
        "upload_ffmpeg_input_url" => upload_url,
        "source_bucket" => "missing-upload-bucket",
        "source_key" => "uploads/video.mp4",
        "source_content_type" => "video/mp4"
      },
      dependency_outputs: %{
        "source" => %{"source_url" => upload_url}
      }
    }

    assert {:ok, output, []} = MediaInspectStep.run(%{}, context)
    assert output["status"] == "ok"
    assert output["duration"] == 2.0
    assert output["size_bytes"] == 1234

    captured_args = File.read!(capture_path) |> String.split("\n", trim: true)

    assert Enum.chunk_every(captured_args, 2, 1, :discard)
           |> Enum.member?(["-format_whitelist", @safe_input_formats])

    assert List.last(captured_args) == upload_url
  end

  test "prefers uploaded original metadata when upload_original dependency is present" do
    context = %{
      run_input: %{
        "region" => "eu",
        "media_probe" => %{
          "duration" => 5.0,
          "size_bytes" => 15,
          "filetype" => "mp4",
          "streams" => [
            %{"codec_type" => "video", "codec_name" => "h264", "width" => 1280, "height" => 720}
          ]
        }
      },
      dependency_outputs: %{
        "source" => %{
          "source_url" => "https://s3.fr-par.scw.cloud/example-uploads/uploads/video.mp4"
        },
        "upload_original" => %{
          "bucket" => "space-rbp63",
          "original_key" => "NTELefGK6t/original",
          "original_uri" => "s3://space-rbp63/NTELefGK6t/original",
          "content_type" => "video/mp4"
        }
      }
    }

    assert {:ok, output, []} = MediaInspectStep.run(%{}, context)
    assert output["status"] == "ok"
    assert output["source"] == "s3://space-rbp63/NTELefGK6t/original"
    assert output["filetype"] == "mp4"
  end

  test "deletes uploaded original when strict media inspection rejects the file" do
    assert {:ok, _body} =
             FlowStorageAdapterStub.put_public(
               "space-rbp63",
               "NTELefGK6t/original",
               ~s({"metadata":"not media"}),
               "application/json",
               "eu"
             )

    context = %{
      run_input: %{
        "region" => "eu",
        "media_inspect_strict" => true
      },
      dependency_outputs: %{
        "upload_original" => %{
          "bucket" => "space-rbp63",
          "original_key" => "NTELefGK6t/original",
          "original_uri" => "s3://space-rbp63/NTELefGK6t/original",
          "content_type" => "application/json"
        }
      }
    }

    with_failing_ffprobe(fn ->
      assert {:error,
              {:media_inspect_failed,
               {:uploaded_original_get_failed, :unsupported_media_signature}}} =
               MediaInspectStep.run(%{}, context)
    end)

    assert FlowStorageAdapterStub.get("space-rbp63", "NTELefGK6t/original", "eu") ==
             {:error, :not_found}
  end

  test "rejects a remote playlist before ffprobe can follow nested URLs" do
    playlist = "#EXTM3U\n#EXTINF:1,\nhttps://request-bin.invalid/internal.ts\n"

    assert {:ok, _body} =
             FlowStorageAdapterStub.put_public(
               "space-trial",
               "probe123/original",
               playlist,
               "application/vnd.apple.mpegurl",
               "eu"
             )

    context = %{
      run_input: %{
        "region" => "eu",
        "media_inspect_strict" => true,
        "source_content_type" => "application/vnd.apple.mpegurl"
      },
      dependency_outputs: %{
        "upload_original" => %{
          "bucket" => "space-trial",
          "original_key" => "probe123/original",
          "original_uri" => "s3://space-trial/probe123/original",
          "content_type" => "application/vnd.apple.mpegurl"
        }
      }
    }

    with_ffprobe_script(
      "printf '%s' reached > \"$MAVE_TEST_FFPROBE_CAPTURE\"\n" <>
        "printf '%s\\n' '{\"streams\":[{\"codec_type\":\"video\",\"codec_name\":\"h264\"}],\"format\":{\"format_name\":\"hls\"}}'\n",
      fn capture_path ->
        assert {:error,
                {:media_inspect_failed,
                 {:uploaded_original_get_failed, :unsupported_media_signature}}} =
                 MediaInspectStep.run(%{}, context)

        refute File.exists?(capture_path)
      end
    )

    assert FlowStorageAdapterStub.get("space-trial", "probe123/original", "eu") ==
             {:error, :not_found}
  end

  test "falls back to a validated full download when prefix reads are unavailable" do
    Application.put_env(
      :mave_core,
      :flow_storage_adapter,
      PrefixReadFailingStorageAdapter
    )

    assert {:ok, _body} =
             FlowStorageAdapterStub.put_public(
               "space-demo",
               "video123/original",
               <<0, 0, 0, 24, "ftyp", "isom", 0::128>>,
               "video/mp4",
               "eu"
             )

    context = %{
      run_input: %{"region" => "eu", "media_inspect_strict" => true},
      dependency_outputs: %{
        "upload_original" => %{
          "bucket" => "space-demo",
          "original_key" => "video123/original",
          "content_type" => "video/mp4"
        }
      }
    }

    with_ffprobe_script(
      ~S|printf '%s\n' '{"streams":[{"codec_type":"video","codec_name":"h264","width":640,"height":360}],"format":{"duration":"1.0","format_name":"mov,mp4"}}'| <>
        "\n",
      fn _capture_path ->
        assert {:ok, output, []} = MediaInspectStep.run(%{}, context)
        assert output["status"] == "ok"
        assert output["width"] == 640
      end
    )
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)

  defp with_failing_ffprobe(fun) when is_function(fun, 0) do
    with_ffprobe_script("printf '%s\\n' 'invalid media'\nexit 1\n", fn _capture_path ->
      fun.()
    end)
  end

  defp with_ffprobe_script(script, fun) when is_binary(script) and is_function(fun, 1) do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mave_ffprobe_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    ffprobe_path = Path.join(tmp_dir, "ffprobe")
    capture_path = Path.join(tmp_dir, "capture")
    old_path = System.get_env("PATH") || ""

    File.write!(ffprobe_path, "#!/bin/sh\n" <> script)
    File.chmod!(ffprobe_path, 0o755)
    System.put_env("PATH", tmp_dir <> ":" <> old_path)

    try do
      fun.(capture_path)
    after
      System.put_env("PATH", old_path)
      _ = File.rm_rf(tmp_dir)
    end
  end
end
