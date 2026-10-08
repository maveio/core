defmodule MaveCore.Flow.ManifestParityTest do
  use ExUnit.Case, async: true

  alias MaveCore.Flow.ManifestParity

  test "equivalent? ignores rendition order differences" do
    legacy = %{
      "id" => "ubg50LeDE9v86ye",
      "space_id" => "ubg50",
      "settings" => %{"aspect_ratio" => "16 / 9"},
      "video" => %{
        "id" => "video-id",
        "version" => 1,
        "aspect_ratio" => "16 / 9",
        "renditions" => [
          %{"type" => "video", "size" => "sd", "codec" => "h264", "container" => "mp4"},
          %{"type" => "video", "size" => "hd", "codec" => "h264", "container" => "mp4"}
        ]
      },
      "poster" => %{"renditions" => []},
      "subtitles" => [],
      "audio_tracks" => []
    }

    core = %{
      id: "ubg50LeDE9v86ye",
      space_id: "ubg50",
      settings: %{aspect_ratio: "16 / 9"},
      video: %{
        id: "video-id",
        version: 1,
        aspect_ratio: "16 / 9",
        renditions: [
          %{type: "video", size: "hd", codec: "h264", container: "mp4"},
          %{type: "video", size: "sd", codec: "h264", container: "mp4"}
        ]
      },
      poster: %{renditions: []},
      subtitles: [],
      audio_tracks: []
    }

    assert ManifestParity.equivalent?(legacy, core)
  end

  test "diff returns normalized payload for mismatches" do
    legacy = %{"id" => "legacy", "video" => %{"id" => "v1"}}
    core = %{"id" => "core", "video" => %{"id" => "v1"}}

    assert %{legacy: legacy_norm, core: core_norm} = ManifestParity.diff(legacy, core)
    assert legacy_norm["id"] == "legacy"
    assert core_norm["id"] == "core"
  end
end
