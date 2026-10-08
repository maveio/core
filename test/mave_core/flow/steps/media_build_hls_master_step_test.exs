defmodule MaveCore.Flow.Steps.MediaBuildHlsMasterStepTest do
  use ExUnit.Case, async: false

  alias MaveCore.Flow.Steps.MediaBuildHlsMasterStep
  alias MaveCore.TestSupport.FlowStorageAdapterStub

  setup do
    old_storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter)

    Application.put_env(:mave_core, :flow_storage_adapter, FlowStorageAdapterStub)
    FlowStorageAdapterStub.reset!()

    on_exit(fn ->
      FlowStorageAdapterStub.reset!()
      restore_env(:flow_storage_adapter, old_storage_adapter)
    end)

    :ok
  end

  test "builds root hls playlist from packaged variants" do
    step_definition = %{
      "id" => "hls_master",
      "type" => "media.build_hls_master"
    }

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "version" => 0,
        "duration" => 42.5
      },
      dependency_outputs: %{
        "hls_h264_hd" => %{
          "step_type" => "media.package_hls_variant",
          "status" => "ok",
          "codec" => "h264",
          "size" => "hd",
          "playlist_path" => "h264_hd_hls/playlist.m3u8",
          "playlist_uri" => "s3://space-ubg50/LeDE9v86ye/h264_hd_hls/playlist.m3u8"
        },
        "hls_h264_sd" => %{
          "step_type" => "media.package_hls_variant",
          "status" => "ok",
          "codec" => "h264",
          "size" => "sd",
          "playlist_path" => "h264_sd_hls/playlist.m3u8",
          "playlist_uri" => "s3://space-ubg50/LeDE9v86ye/h264_sd_hls/playlist.m3u8",
          "resolution" => "360x640"
        },
        "hls_audio_default" => %{
          "step_type" => "media.package_hls_audio",
          "status" => "ok",
          "track_id" => "default",
          "label" => "Original",
          "language" => "en",
          "default" => true,
          "channels" => "2",
          "bandwidth" => 128_000,
          "playlist_path" => "audio_hls/playlist.m3u8",
          "playlist_uri" => "s3://space-ubg50/LeDE9v86ye/audio_hls/playlist.m3u8"
        },
        "translate_subtitles" => %{
          "step_type" => "ai.translate_subtitles",
          "status" => "ok",
          "subtitles" => [
            %{
              "id" => "nl",
              "label" => "Dutch",
              "language" => "nl",
              "path" => "s3://space-ubg50/LeDE9v86ye/subtitle_nl.vtt"
            }
          ]
        }
      }
    }

    assert {:ok, output, artifacts} = MediaBuildHlsMasterStep.run(step_definition, context)
    assert output["status"] == "ok"
    assert output["step_type"] == "media.build_hls_master"
    assert output["key"] == "LeDE9v86ye/playlist.m3u8"
    assert output["uri"] == "s3://space-ubg50/LeDE9v86ye/playlist.m3u8"
    assert output["variant_count"] == 2
    assert output["audio_track_count"] == 1
    assert output["subtitle_count"] == 1
    assert [%{name: "hls_master"}] = artifacts

    assert {:ok, playlist_body} =
             FlowStorageAdapterStub.get("space-ubg50", "LeDE9v86ye/playlist.m3u8", nil)

    assert String.contains?(playlist_body, "#EXTM3U")
    assert String.contains?(playlist_body, "#EXT-X-MEDIA:TYPE=AUDIO")
    assert String.contains?(playlist_body, "audio_hls/playlist.m3u8")
    assert String.contains?(playlist_body, "AUDIO=\"audio\"")
    assert String.contains?(playlist_body, "TYPE=SUBTITLES")
    assert String.contains?(playlist_body, "SUBTITLES=\"subtitles\"")
    assert String.contains?(playlist_body, "URI=\"subtitle_nl_hls/playlist.m3u8\"")

    assert subtitle_line =
             Enum.find(
               String.split(playlist_body, "\n"),
               &String.contains?(&1, "TYPE=SUBTITLES")
             )

    refute String.contains?(subtitle_line, "AUTOSELECT")
    assert String.contains?(playlist_body, "RESOLUTION=360x640")
    assert length(Regex.scan(~r/CLOSED-CAPTIONS=NONE/, playlist_body)) == 2
    assert String.contains?(playlist_body, "h264_sd_hls/playlist.m3u8")
    assert String.contains?(playlist_body, "h264_hd_hls/playlist.m3u8")

    assert {:ok, subtitle_playlist} =
             FlowStorageAdapterStub.get(
               "space-ubg50",
               "LeDE9v86ye/subtitle_nl_hls/playlist.m3u8",
               nil
             )

    assert subtitle_playlist =~ "#EXT-X-TARGETDURATION:43"
    assert subtitle_playlist =~ "#EXTINF:42.500000,"
    assert subtitle_playlist =~ "../subtitle_nl.vtt"
  end

  test "publishes a waveform rendition only after its master playlist includes audio" do
    rendition = %{"type" => "video", "container" => "hls", "size" => "sd"}
    step = %{"id" => "hls_waveform_master", "params" => %{"strict" => true}}

    context = %{
      run_input: %{"space_hash" => "ubg50", "embed_hash" => "LeDE9v86ye"},
      dependency_outputs: %{
        "hls_waveform_sd" => %{
          "step_type" => "media.package_hls_variant",
          "status" => "ok",
          "size" => "sd",
          "codec" => "h264",
          "playlist_path" => "h264_sd_hls/playlist.m3u8",
          "waveform_rendition" => rendition
        }
      }
    }

    assert {:ok, skipped, []} = MediaBuildHlsMasterStep.run(step, context)
    assert skipped["status"] == "skipped"
    assert skipped["reason"] == "missing_waveform_audio"

    assert {:error, _} =
             FlowStorageAdapterStub.get("space-ubg50", "LeDE9v86ye/playlist.m3u8", nil)

    context =
      put_in(context, [:dependency_outputs, "hls_audio_default"], %{
        "step_type" => "media.package_hls_audio",
        "status" => "ok",
        "default" => true,
        "playlist_path" => "audio_hls/playlist.m3u8"
      })

    FlowStorageAdapterStub.fail_public_put!("space-ubg50", "LeDE9v86ye/playlist.m3u8", nil)
    assert {:error, _} = MediaBuildHlsMasterStep.run(step, context)
    FlowStorageAdapterStub.reset!()

    assert {:ok, output, [_]} = MediaBuildHlsMasterStep.run(step, context)
    assert output["audio_track_count"] == 1
    assert rendition in output["renditions"]

    assert {:ok, playlist} =
             FlowStorageAdapterStub.get("space-ubg50", "LeDE9v86ye/playlist.m3u8", nil)

    assert playlist =~ "AUDIO=\"audio\""
    assert playlist =~ "audio_hls/playlist.m3u8"
  end

  test "builds root hls playlist with multiple audio tracks from one audio step" do
    step_definition = %{
      "id" => "hls_master",
      "type" => "media.build_hls_master"
    }

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "version" => 0
      },
      dependency_outputs: %{
        "hls_h264_sd" => %{
          "step_type" => "media.package_hls_variant",
          "status" => "ok",
          "codec" => "h264",
          "size" => "sd",
          "playlist_path" => "h264_sd_hls/playlist.m3u8",
          "playlist_uri" => "s3://space-ubg50/LeDE9v86ye/h264_sd_hls/playlist.m3u8"
        },
        "hls_audio_default" => %{
          "step_type" => "media.package_hls_audio",
          "status" => "ok",
          "audio_tracks" => [
            %{
              "id" => "default",
              "label" => "Original",
              "language" => "en",
              "default" => true,
              "hls_channels" => "2",
              "hls_bandwidth" => 128_000,
              "hls_playlist" => "audio_hls/playlist.m3u8",
              "hls_src" => "s3://space-ubg50/LeDE9v86ye/audio_hls/playlist.m3u8"
            },
            %{
              "id" => "track_2",
              "label" => "Dutch",
              "language" => "nl",
              "default" => false,
              "hls_channels" => "2",
              "hls_bandwidth" => 128_000,
              "hls_playlist" => "track_2_mp3_hls/playlist.m3u8",
              "hls_src" => "s3://space-ubg50/LeDE9v86ye/track_2_mp3_hls/playlist.m3u8"
            }
          ]
        }
      }
    }

    assert {:ok, output, _artifacts} = MediaBuildHlsMasterStep.run(step_definition, context)
    assert output["status"] == "ok"
    assert output["audio_track_count"] == 2

    assert {:ok, playlist_body} =
             FlowStorageAdapterStub.get("space-ubg50", "LeDE9v86ye/playlist.m3u8", nil)

    assert String.contains?(playlist_body, "NAME=\"Original\"")
    assert String.contains?(playlist_body, "NAME=\"Dutch\"")
    assert String.contains?(playlist_body, "audio_hls/playlist.m3u8")
    assert String.contains?(playlist_body, "track_2_mp3_hls/playlist.m3u8")
  end

  test "user-provided names cannot break out of playlist attributes" do
    context = %{
      run_input: %{"space_hash" => "ubg50", "embed_hash" => "LeDE9v86ye", "version" => 0},
      dependency_outputs: %{
        "hls_h264_sd" => %{
          "step_type" => "media.package_hls_variant",
          "status" => "ok",
          "codec" => "h264",
          "size" => "sd",
          "playlist_path" => "h264_sd_hls/playlist.m3u8",
          "playlist_uri" => "s3://space-ubg50/LeDE9v86ye/h264_sd_hls/playlist.m3u8"
        },
        "hls_audio_default" => %{
          "step_type" => "media.package_hls_audio",
          "status" => "ok",
          "audio_tracks" => [
            %{
              "id" => "default",
              "label" =>
                "Director's \"cut\"\r\n#EXT-X-STREAM-INF:BANDWIDTH=1\nhttps://attacker.example/x.m3u8",
              "language" => "en",
              "default" => true,
              "hls_channels" => "2",
              "hls_bandwidth" => 128_000,
              "hls_playlist" => "audio_hls/playlist.m3u8",
              "hls_src" => "s3://space-ubg50/LeDE9v86ye/audio_hls/playlist.m3u8"
            }
          ]
        }
      }
    }

    assert {:ok, _output, _artifacts} =
             MediaBuildHlsMasterStep.run(
               %{"id" => "hls_master", "type" => "media.build_hls_master"},
               context
             )

    assert {:ok, playlist_body} =
             FlowStorageAdapterStub.get("space-ubg50", "LeDE9v86ye/playlist.m3u8", nil)

    lines = String.split(playlist_body, ["\r\n", "\n"], trim: true)

    assert [media_line] = Enum.filter(lines, &String.starts_with?(&1, "#EXT-X-MEDIA:TYPE=AUDIO"))

    assert media_line =~
             ~s(NAME="Director's 'cut' #EXT-X-STREAM-INF:BANDWIDTH=1 https://attacker.example/x.m3u8")

    assert Enum.count(lines, &String.starts_with?(&1, "#EXT-X-STREAM-INF")) == 1
    refute Enum.any?(lines, &String.starts_with?(&1, "https://"))
  end

  test "progressively refreshes the root playlist from a previous master output" do
    step_definition = %{
      "id" => "hls_master_hd",
      "type" => "media.build_hls_master"
    }

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "version" => 0
      },
      dependency_outputs: %{
        "hls_master_sd" => %{
          "step_type" => "media.build_hls_master",
          "status" => "ok",
          "variants" => [
            %{
              "size" => "sd",
              "codec" => "h264",
              "playlist_path" => "h264_sd_hls/playlist.m3u8",
              "playlist_uri" => "s3://space-ubg50/LeDE9v86ye/h264_sd_hls/playlist.m3u8",
              "bandwidth" => 3_000_000,
              "resolution" => "842x480"
            }
          ],
          "audio_tracks" => [
            %{
              "track_id" => "default",
              "name" => "Original",
              "language" => "en",
              "default" => true,
              "channels" => "2",
              "bandwidth" => 128_000,
              "playlist_path" => "audio_hls/playlist.m3u8",
              "playlist_uri" => "s3://space-ubg50/LeDE9v86ye/audio_hls/playlist.m3u8"
            }
          ],
          "subtitles" => [
            %{
              "id" => "en",
              "name" => "English",
              "language" => "en",
              "default" => false,
              "playlist_path" => "subtitle_en_hls/playlist.m3u8",
              "source_path" => "subtitle_en.vtt"
            }
          ]
        },
        "hls_h264_hd" => %{
          "step_type" => "media.package_hls_variant",
          "status" => "ok",
          "codec" => "h264",
          "size" => "hd",
          "playlist_path" => "h264_hd_hls/playlist.m3u8",
          "playlist_uri" => "s3://space-ubg50/LeDE9v86ye/h264_hd_hls/playlist.m3u8"
        }
      }
    }

    assert {:ok, output, _artifacts} = MediaBuildHlsMasterStep.run(step_definition, context)
    assert output["variant_count"] == 2
    assert output["audio_track_count"] == 1
    assert output["subtitle_count"] == 1

    assert {:ok, playlist_body} =
             FlowStorageAdapterStub.get("space-ubg50", "LeDE9v86ye/playlist.m3u8", nil)

    assert String.contains?(playlist_body, "h264_sd_hls/playlist.m3u8")
    assert String.contains?(playlist_body, "h264_hd_hls/playlist.m3u8")
    assert String.contains?(playlist_body, "audio_hls/playlist.m3u8")
    assert String.contains?(playlist_body, "subtitle_en_hls/playlist.m3u8")
  end

  test "returns skipped output when no variants are available" do
    step_definition = %{
      "id" => "hls_master",
      "type" => "media.build_hls_master"
    }

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye"
      },
      dependency_outputs: %{}
    }

    assert {:ok, output, []} = MediaBuildHlsMasterStep.run(step_definition, context)
    assert output["status"] == "skipped"
    assert output["reason"] == "no_hls_variants"
  end

  test "builds video-only master playlist when no audio hls tracks exist" do
    step_definition = %{
      "id" => "hls_master",
      "type" => "media.build_hls_master"
    }

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "version" => 0
      },
      dependency_outputs: %{
        "hls_h264_sd" => %{
          "step_type" => "media.package_hls_variant",
          "status" => "ok",
          "codec" => "h264",
          "size" => "sd",
          "playlist_path" => "h264_sd_hls/playlist.m3u8",
          "playlist_uri" => "s3://space-ubg50/LeDE9v86ye/h264_sd_hls/playlist.m3u8"
        }
      }
    }

    assert {:ok, output, _artifacts} = MediaBuildHlsMasterStep.run(step_definition, context)
    assert output["status"] == "ok"
    assert output["audio_track_count"] == 0

    assert {:ok, playlist_body} =
             FlowStorageAdapterStub.get("space-ubg50", "LeDE9v86ye/playlist.m3u8", nil)

    refute String.contains?(playlist_body, "#EXT-X-MEDIA:TYPE=AUDIO")
    refute String.contains?(playlist_body, "AUDIO=\"audio\"")
    assert String.contains?(playlist_body, "CLOSED-CAPTIONS=NONE")
    assert String.contains?(playlist_body, "h264_sd_hls/playlist.m3u8")
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)
end
