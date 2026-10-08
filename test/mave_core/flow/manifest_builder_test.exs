defmodule MaveCore.Flow.ManifestBuilderTest do
  use ExUnit.Case, async: true

  alias MaveCore.Embeds.SettingsSerializer
  alias MaveCore.Flow.{ManifestBuilder, ManifestParity}
  alias MaveCore.Media.Storage

  test "builds legacy-compatible manifest payload" do
    run_input = %{
      "space_hash" => "ubg50",
      "embed_hash" => "LeDE9v86ye",
      "version" => 8,
      "name" => "Sample video",
      "metrics_key" => "AAAAAAAAAAAAAAAAAAAAAA==",
      "created_at" => 1_700_000_000,
      "duration" => 10.0,
      "size" => 1_000_000,
      "video_id" => "1111111111111111111111",
      "aspect_ratio" => "16 / 9",
      "filetype" => "mp4"
    }

    dependency_outputs = %{
      "source" => %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "source_url" => "https://example.com/video.mp4",
        "version" => 8
      },
      "ensure_bucket" => %{"bucket" => "space-ubg50"},
      "upload_original" => %{
        "bucket" => "space-ubg50",
        "bytes" => 1_000_000,
        "content_type" => "video/mp4"
      }
    }

    assert {:ok, build} =
             ManifestBuilder.build(%{
               run_input: run_input,
               dependency_outputs: dependency_outputs
             })

    assert build["bucket"] == "space-ubg50"
    assert build["key"] == "LeDE9v86ye/v8/manifest.json"
    assert build["uri"] == "s3://space-ubg50/LeDE9v86ye/v8/manifest.json"
    assert is_binary(build["json"])
    assert is_binary(build["checksum"])
    assert String.length(build["checksum"]) == 64

    legacy_fixture =
      fixture_path("legacy_publish_default_manifest.json")
      |> File.read!()
      |> Jason.decode!()

    assert ManifestParity.equivalent?(legacy_fixture, build["manifest"])
  end

  test "returns missing field error for missing identity inputs" do
    assert {:error, {:missing_field, :space_hash}} = ManifestBuilder.build(%{run_input: %{}})
  end

  test "prefers inspect output for media metadata when run_input fields are absent" do
    run_input = %{
      "space_hash" => "ubg50",
      "embed_hash" => "LeDE9v86ye"
    }

    dependency_outputs = %{
      "source" => %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "source_url" => "https://example.com/video.mp4",
        "version" => 2
      },
      "inspect_media" => %{
        "step_type" => "media.inspect",
        "duration" => 42.5,
        "size_bytes" => 2_048_000,
        "filetype" => "mp4",
        "aspect_ratio" => "16 / 9",
        "video_id" => "video-inspected-1",
        "width" => 1920,
        "height" => 1080,
        "has_audio" => true
      },
      "ensure_bucket" => %{"bucket" => "space-ubg50"},
      "upload_original" => %{"bucket" => "space-ubg50"}
    }

    assert {:ok, build} =
             ManifestBuilder.build(%{
               run_input: run_input,
               dependency_outputs: dependency_outputs
             })

    manifest = build["manifest"]
    video = manifest["video"]

    assert video["duration"] == 42.5
    assert video["size"] == 2_048_000
    assert video["filetype"] == "mp4"
    assert video["aspect_ratio"] == "16 / 9"
    assert video["id"] == "video-inspected-1"
    assert video["version"] == 2
    assert video["max_width"] == 1920
    assert video["max_height"] == 1080
    assert video["audio"] == true
  end

  test "assumes audio is present until media inspection completes" do
    run_input = %{
      "space_hash" => "ubg50",
      "embed_hash" => "LeDE9v86ye"
    }

    dependency_outputs = %{
      "source" => %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "source_url" => "https://example.com/video.mp4",
        "version" => 0
      },
      "ensure_bucket" => %{"bucket" => "space-ubg50"}
    }

    assert {:ok, build} =
             ManifestBuilder.build(%{
               run_input: run_input,
               dependency_outputs: dependency_outputs
             })

    assert get_in(build, ["manifest", "video", "audio"]) == true
  end

  test "uses a completed media inspection to confirm that audio is absent" do
    run_input = %{
      "space_hash" => "ubg50",
      "embed_hash" => "LeDE9v86ye"
    }

    dependency_outputs = %{
      "source" => %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "source_url" => "https://example.com/video.mp4",
        "version" => 0
      },
      "inspect_media" => %{
        "step_type" => "media.inspect",
        "status" => "ok",
        "has_audio" => false,
        "streams" => [%{"codec_type" => "video"}]
      },
      "ensure_bucket" => %{"bucket" => "space-ubg50"}
    }

    assert {:ok, build} =
             ManifestBuilder.build(%{
               run_input: run_input,
               dependency_outputs: dependency_outputs
             })

    assert get_in(build, ["manifest", "video", "audio"]) == false
  end

  test "includes video renditions emitted by media.transcode_video steps" do
    run_input = %{
      "space_hash" => "ubg50",
      "embed_hash" => "LeDE9v86ye"
    }

    dependency_outputs = %{
      "source" => %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "source_url" => "https://example.com/video.mp4",
        "version" => 0
      },
      "video_h264_sd" => %{
        "step_type" => "media.transcode_video",
        "status" => "ok",
        "rendition" => %{
          "type" => "video",
          "size" => "sd",
          "codec" => "h264",
          "container" => "mp4",
          "src" => "s3://space-ubg50/LeDE9v86ye/h264_sd.mp4",
          "file_size" => 100
        }
      },
      "video_h264_hd" => %{
        "step_type" => "media.transcode_video",
        "status" => "ok",
        "rendition" => %{
          "type" => "video",
          "size" => "hd",
          "codec" => "h264",
          "container" => "mp4",
          "src" => "s3://space-ubg50/LeDE9v86ye/h264_hd.mp4",
          "file_size" => 200
        }
      }
    }

    assert {:ok, build} =
             ManifestBuilder.build(%{
               run_input: run_input,
               dependency_outputs: dependency_outputs
             })

    renditions = get_in(build["manifest"], ["video", "renditions"])
    assert length(renditions) == 2

    assert Enum.any?(renditions, fn rendition ->
             rendition["size"] == "sd" and rendition["codec"] == "h264" and
               rendition["src"] ==
                 SettingsSerializer.storage_object_url(
                   "space-ubg50",
                   "LeDE9v86ye/h264_sd.mp4"
                 )
           end)

    assert Enum.any?(renditions, fn rendition ->
             rendition["size"] == "hd" and rendition["codec"] == "h264" and
               rendition["src"] ==
                 SettingsSerializer.storage_object_url(
                   "space-ubg50",
                   "LeDE9v86ye/h264_hd.mp4"
                 )
           end)
  end

  test "includes list-based video renditions emitted by media.transcode_video steps" do
    run_input = %{
      "space_hash" => "ubg50",
      "embed_hash" => "LeDE9v86ye"
    }

    dependency_outputs = %{
      "source" => %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "source_url" => "https://example.com/video.mp4",
        "version" => 0
      },
      "video_h264_multi" => %{
        "step_type" => "media.transcode_video",
        "status" => "ok",
        "renditions" => [
          %{
            "type" => "video",
            "size" => "sd",
            "codec" => "h264",
            "container" => "mp4",
            "src" => "s3://space-ubg50/LeDE9v86ye/h264_sd.mp4",
            "file_size" => 100
          },
          %{
            "type" => "clip",
            "size" => "sd",
            "codec" => "hevc",
            "container" => "mp4",
            "src" => "s3://space-ubg50/LeDE9v86ye/hevc_sd_clip.mp4",
            "file_size" => 75
          },
          %{
            "type" => "audio",
            "codec" => "aac",
            "container" => "m4a",
            "src" => "s3://space-ubg50/LeDE9v86ye/audio_aac.m4a",
            "file_size" => 50
          }
        ]
      }
    }

    assert {:ok, build} =
             ManifestBuilder.build(%{
               run_input: run_input,
               dependency_outputs: dependency_outputs
             })

    renditions = get_in(build["manifest"], ["video", "renditions"])
    assert length(renditions) == 2

    rendition = Enum.find(renditions, &(&1["type"] == "video"))
    assert rendition["type"] == "video"
    assert rendition["size"] == "sd"
    assert rendition["codec"] == "h264"

    clip = Enum.find(renditions, &(&1["type"] == "clip"))
    assert clip["size"] == "sd"
    assert clip["codec"] == "hevc"
  end

  test "includes renditions emitted by split h264 ladder steps" do
    dependency_outputs = %{
      "source" => %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "version" => 0
      },
      "video_h264_sd" => %{
        "step_type" => "media.transcode_h264_ladder",
        "status" => "ok",
        "renditions" => [
          %{
            "type" => "video",
            "size" => "sd",
            "codec" => "h264",
            "container" => "mp4",
            "src" => "s3://space-ubg50/LeDE9v86ye/h264_sd.mp4",
            "file_size" => 256_000,
            "progress" => 100.0
          }
        ]
      }
    }

    assert {:ok, build} =
             ManifestBuilder.build(%{
               run_input: %{
                 "space_hash" => "ubg50",
                 "embed_hash" => "LeDE9v86ye",
                 "version" => 0
               },
               dependency_outputs: dependency_outputs
             })

    assert [rendition] = get_in(build, ["manifest", "video", "renditions"])
    assert rendition["size"] == "sd"
    assert rendition["codec"] == "h264"
    assert rendition["container"] == "mp4"
  end

  test "includes hls variant renditions but omits hls master renditions" do
    run_input = %{
      "space_hash" => "ubg50",
      "embed_hash" => "LeDE9v86ye"
    }

    dependency_outputs = %{
      "source" => %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "source_url" => "https://example.com/video.mp4",
        "version" => 0
      },
      "hls_master" => %{
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
          },
          %{
            "size" => "hd",
            "codec" => "h264",
            "playlist_path" => "h264_hd_hls/playlist.m3u8",
            "playlist_uri" => "s3://space-ubg50/LeDE9v86ye/h264_hd_hls/playlist.m3u8",
            "bandwidth" => 4_000_000,
            "resolution" => "1280x720"
          }
        ],
        "rendition" => %{
          "type" => "video",
          "size" => "master",
          "codec" => "h264",
          "container" => "hls",
          "src" => "s3://space-ubg50/LeDE9v86ye/playlist.m3u8",
          "file_size" => 456
        }
      }
    }

    assert {:ok, build} =
             ManifestBuilder.build(%{
               run_input: run_input,
               dependency_outputs: dependency_outputs
             })

    renditions = get_in(build["manifest"], ["video", "renditions"])

    assert Enum.any?(renditions, fn rendition ->
             rendition["container"] == "hls" and rendition["size"] == "sd"
           end)

    assert Enum.any?(renditions, fn rendition ->
             rendition["container"] == "hls" and rendition["size"] == "hd"
           end)

    refute Enum.any?(renditions, fn rendition ->
             rendition["container"] == "hls" and rendition["size"] == "master"
           end)
  end

  test "uses default player settings when no settings are provided" do
    run_input = %{
      "space_hash" => "ubg50",
      "embed_hash" => "LeDE9v86ye"
    }

    dependency_outputs = %{
      "source" => %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "source_url" => "https://example.com/video.mp4",
        "version" => 0
      }
    }

    assert {:ok, build} =
             ManifestBuilder.build(%{
               run_input: run_input,
               dependency_outputs: dependency_outputs
             })

    assert build["manifest"]["settings"] == %{
             "aspect_ratio" => "16 / 9",
             "width" => nil,
             "height" => nil,
             "loop" => nil,
             "autoplay" => nil,
             "color" => nil,
             "opacity" => nil,
             "controls" => "full",
             "poster" => nil
           }

    refute Map.has_key?(build["manifest"], "metrics_key")
  end

  test "includes audio tracks emitted by media.transcode_audio steps" do
    run_input = %{
      "space_hash" => "ubg50",
      "embed_hash" => "LeDE9v86ye"
    }

    dependency_outputs = %{
      "source" => %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "source_url" => "https://example.com/video.mp4",
        "version" => 0
      },
      "transcode_audio" => %{
        "step_type" => "media.transcode_audio",
        "status" => "ok",
        "audio_track" => %{
          "id" => "default",
          "label" => "Original",
          "language" => nil,
          "default" => true,
          "codec" => "aac",
          "file_size" => 1234,
          "filename" => "audio_aac.m4a",
          "src" => "s3://space-ubg50/LeDE9v86ye/audio_aac.m4a"
        }
      }
    }

    assert {:ok, build} =
             ManifestBuilder.build(%{
               run_input: run_input,
               dependency_outputs: dependency_outputs
             })

    audio_tracks = get_in(build["manifest"], ["audio_tracks"])
    assert length(audio_tracks) == 1

    [track] = audio_tracks
    assert track["id"] == "default"
    assert track["label"] == "Original"
    assert track["codec"] == "aac"
    assert track["filename"] == "audio_aac.m4a"

    assert track["src"] ==
             SettingsSerializer.storage_object_url(
               "space-ubg50",
               "LeDE9v86ye/audio_aac.m4a"
             )

    assert get_in(build["manifest"], ["video", "audio"]) == true
  end

  test "merges hls metadata into audio tracks when package_hls_audio emits same track" do
    run_input = %{
      "space_hash" => "ubg50",
      "embed_hash" => "LeDE9v86ye"
    }

    dependency_outputs = %{
      "source" => %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "source_url" => "https://example.com/video.mp4",
        "version" => 0
      },
      "transcode_audio" => %{
        "step_type" => "media.transcode_audio",
        "status" => "ok",
        "audio_track" => %{
          "id" => "default",
          "label" => "Original",
          "language" => "en",
          "default" => true,
          "codec" => "mp3",
          "file_size" => 111,
          "filename" => "audio.mp3",
          "src" => "s3://space-ubg50/LeDE9v86ye/audio.mp3"
        }
      },
      "hls_audio_default" => %{
        "step_type" => "media.package_hls_audio",
        "status" => "ok",
        "audio_track" => %{
          "id" => "default",
          "label" => "Original",
          "language" => "en",
          "default" => true,
          "codec" => "mp3",
          "file_size" => 111,
          "filename" => "audio.mp3",
          "src" => "s3://space-ubg50/LeDE9v86ye/audio.mp3",
          "hls_playlist" => "audio_hls/playlist.m3u8",
          "hls_group_id" => "audio",
          "hls_codec" => "aac",
          "hls_bandwidth" => 128_000,
          "hls_channels" => "2"
        }
      }
    }

    assert {:ok, build} =
             ManifestBuilder.build(%{
               run_input: run_input,
               dependency_outputs: dependency_outputs
             })

    audio_tracks = get_in(build["manifest"], ["audio_tracks"])
    assert length(audio_tracks) == 1

    [track] = audio_tracks
    assert track["hls_playlist"] == "audio_hls/playlist.m3u8"
    assert track["hls_group_id"] == "audio"
    assert track["hls_codec"] == "aac"
    assert track["hls_bandwidth"] == 128_000
    assert track["hls_channels"] == "2"
  end

  test "prefers poster src emitted by media.extract_frame poster step" do
    run_input = %{
      "space_hash" => "ubg50",
      "embed_hash" => "LeDE9v86ye"
    }

    dependency_outputs = %{
      "source" => %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "source_url" => "https://example.com/video.mp4",
        "version" => 0
      },
      "poster_frame" => %{
        "step_type" => "media.extract_frame",
        "status" => "ok",
        "role" => "poster",
        "src" => "s3://space-ubg50/LeDE9v86ye/poster.jpg"
      }
    }

    assert {:ok, build} =
             ManifestBuilder.build(%{
               run_input: run_input,
               dependency_outputs: dependency_outputs
             })

    assert get_in(build["manifest"], ["poster", "image_src"]) ==
             SettingsSerializer.storage_object_url(
               "space-ubg50",
               "LeDE9v86ye/poster.jpg"
             )

    assert get_in(build["manifest"], ["poster", "initial_frame_src"]) ==
             SettingsSerializer.storage_object_url(
               "space-ubg50",
               "LeDE9v86ye/poster.jpg"
             )
  end

  test "includes subtitles emitted by transcription and translation steps" do
    run_input = %{
      "space_hash" => "ubg50",
      "embed_hash" => "LeDE9v86ye"
    }

    dependency_outputs = %{
      "source" => %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "source_url" => "https://example.com/video.mp4",
        "version" => 0
      },
      "transcribe_audio" => %{
        "step_type" => "ai.transcribe_audio",
        "status" => "ok",
        "subtitle" => %{
          "id" => "nl",
          "language" => "nl",
          "label" => "Dutch",
          "path" => "s3://space-ubg50/LeDE9v86ye/subtitle_nl.vtt",
          "src" => "s3://space-ubg50/LeDE9v86ye/subtitle_nl.vtt"
        }
      },
      "translate_subtitles" => %{
        "step_type" => "ai.translate_subtitles",
        "status" => "ok",
        "subtitles" => [
          %{
            "id" => "en",
            "language" => "en",
            "label" => "English",
            "path" => "s3://space-ubg50/LeDE9v86ye/subtitle_en.vtt",
            "src" => "s3://space-ubg50/LeDE9v86ye/subtitle_en.vtt"
          }
        ]
      }
    }

    assert {:ok, build} =
             ManifestBuilder.build(%{
               run_input: run_input,
               dependency_outputs: dependency_outputs
             })

    subtitles = get_in(build["manifest"], ["subtitles"])
    assert length(subtitles) == 2

    subtitle = Enum.find(subtitles, &(&1["language"] == "en"))

    assert subtitle["path"] ==
             SettingsSerializer.storage_object_url(
               "space-ubg50",
               "LeDE9v86ye/subtitle_en.vtt"
             )

    assert subtitle["src"] ==
             SettingsSerializer.storage_object_url(
               "space-ubg50",
               "LeDE9v86ye/subtitle_en.vtt"
             )

    source_subtitle = Enum.find(subtitles, &(&1["language"] == "nl"))
    assert source_subtitle["label"] == "Dutch"
  end

  test "serializes legacy dashboard settings into manifest settings and timecode poster payload" do
    run_input = %{
      "space_hash" => "ubg50",
      "embed_hash" => "LeDE9v86ye",
      "settings" => %{
        "controls_enabled" => false,
        "aspect_ratio_enabled" => false,
        "width" => "720px",
        "height" => "405px",
        "color" => "ff0000",
        "opacity" => 88,
        "autoplay_enabled" => true,
        "autoplay" => "always",
        "loop_enabled" => true,
        "poster" => "timecode",
        "poster_time_seconds" => 12.5
      }
    }

    dependency_outputs = %{
      "source" => %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "source_url" => "https://example.com/video.mp4",
        "version" => 0
      }
    }

    assert {:ok, build} =
             ManifestBuilder.build(%{
               run_input: run_input,
               dependency_outputs: dependency_outputs
             })

    manifest = build["manifest"]

    assert manifest["id"] == "ubg50LeDE9v86ye"
    assert manifest["settings"]["controls"] == "none"
    assert manifest["settings"]["width"] == "720px"
    assert manifest["settings"]["height"] == "405px"
    assert manifest["settings"]["color"] == "#ff0000"
    assert manifest["settings"]["opacity"] == 88
    assert manifest["settings"]["autoplay"] == "always"
    assert manifest["settings"]["loop"] == true
    assert manifest["settings"]["poster"] == 12.5
    assert manifest["poster"]["type"] == "timecode"

    assert manifest["poster"]["image_src"] ==
             "https://image.mave.io/ubg50LeDE9v86ye.webp?time=12.5"
  end

  test "serializes uploaded poster settings into manifest payload" do
    run_input = %{
      "space_hash" => "ubg50",
      "embed_hash" => "LeDE9v86ye",
      "settings" => %{
        "poster" => "upload",
        "external_poster" => "uploads/posters/custom.jpg"
      }
    }

    dependency_outputs = %{
      "source" => %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "source_url" => "https://example.com/video.mp4",
        "version" => 0
      }
    }

    assert {:ok, build} =
             ManifestBuilder.build(%{
               run_input: run_input,
               dependency_outputs: dependency_outputs
             })

    assert get_in(build["manifest"], ["settings", "poster"]) == "custom"
    assert get_in(build["manifest"], ["poster", "type"]) == "upload"

    upload_source_base_url =
      :mave_core
      |> Application.fetch_env!(:upload)
      |> Keyword.fetch!(:source_base_url)
      |> String.trim_trailing("/")

    assert get_in(build["manifest"], ["poster", "image_src"]) ==
             "#{upload_source_base_url}/mave-upload/uploads/posters/custom.jpg"
  end

  test "keeps processing manifest playable from original source before renditions finish" do
    run_input = %{
      "space_hash" => "ubg50",
      "embed_hash" => "LeDE9v86ye",
      "version" => 0
    }

    dependency_outputs = %{
      "source" => %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "source_url" => "https://example.com/video.mp4",
        "version" => 0
      },
      "upload_original" => %{
        "bucket" => "space-ubg50",
        "original_key" => "LeDE9v86ye/original",
        "content_type" => "application/octet-stream"
      }
    }

    assert {:ok, build} =
             ManifestBuilder.build(%{
               run_input: run_input,
               dependency_outputs: dependency_outputs
             })

    video = build["manifest"]["video"]

    assert video["filetype"] == "mp4"
    assert video["status"] == "playable"
    assert video["ready"] == true

    assert video["src"] ==
             SettingsSerializer.storage_object_url("space-ubg50", "LeDE9v86ye/original")

    assert video["original"] ==
             SettingsSerializer.storage_object_url("space-ubg50", "LeDE9v86ye/original")
  end

  test "removes original playback fallback after a playable rendition finishes" do
    assert {:ok, build} =
             ManifestBuilder.build(%{
               run_input: %{
                 "space_hash" => "ubg50",
                 "embed_hash" => "LeDE9v86ye",
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
                   "original_key" => "LeDE9v86ye/original"
                 },
                 "video_h264_sd" => %{
                   "step_type" => "media.transcode_video",
                   "status" => "ok",
                   "rendition" => %{
                     "type" => "video",
                     "size" => "sd",
                     "codec" => "h264",
                     "container" => "mp4",
                     "src" => "s3://space-ubg50/LeDE9v86ye/h264_sd.mp4",
                     "file_size" => 256_000
                   }
                 }
               }
             })

    assert get_in(build, ["manifest", "video", "original"]) == nil
    assert get_in(build, ["manifest", "video", "src"]) == nil
  end

  test "prefers the durable customer original after the upload object is copied" do
    upload = Application.fetch_env!(:mave_core, :upload)

    source_url =
      "#{Keyword.fetch!(upload, :source_base_url)}/#{Keyword.fetch!(upload, :bucket)}/uploads/public/source.mp4"

    public_url = Storage.upload_public_object_url("uploads/public/browser-source.mp4")

    assert {:ok, build} =
             ManifestBuilder.build(%{
               run_input: %{
                 "space_hash" => "ubg50",
                 "embed_hash" => "LeDE9v86ye",
                 "source_key" => "uploads/public/browser-source.mp4",
                 "version" => 0
               },
               dependency_outputs: %{
                 "source" => %{
                   "space_hash" => "ubg50",
                   "embed_hash" => "LeDE9v86ye",
                   "source_url" => source_url,
                   "version" => 0
                 },
                 "upload_original" => %{
                   "bucket" => "space-ubg50",
                   "original_key" => "LeDE9v86ye/original"
                 }
               }
             })

    durable_original =
      SettingsSerializer.storage_object_url("space-ubg50", "LeDE9v86ye/original")

    refute durable_original == public_url
    assert get_in(build, ["manifest", "video", "original"]) == durable_original
    assert get_in(build, ["manifest", "video", "src"]) == durable_original
  end

  defp fixture_path(filename) do
    Path.join([__DIR__, "..", "..", "fixtures", "manifests", filename])
  end
end
