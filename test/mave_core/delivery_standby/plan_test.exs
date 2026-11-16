defmodule MaveCore.DeliveryStandby.PlanTest do
  use ExUnit.Case, async: true

  alias MaveCore.DeliveryStandby.Plan

  @md5_a "0cc175b9c0f1b6a831c399e269772661"
  @md5_b "92eb5ffee6ae2fec3ad71c777531578f"

  defp object(key, opts \\ []) do
    %{
      key: key,
      size_bytes: Keyword.get(opts, :size, 10),
      etag: Keyword.get(opts, :etag, @md5_a),
      last_modified: Keyword.get(opts, :at, ~U[2026-01-01 12:00:00Z])
    }
  end

  test "copies only the media of public embeds and shared themes" do
    primary = [
      object("public0001/manifest.json"),
      object("public0001/v1/video.mp4"),
      object("private001/manifest.json"),
      object("themes/player/default.css"),
      object("stray.txt")
    ]

    plan = Plan.build(primary, [], ["public0001"])

    assert Enum.map(plan.copy, fn {reason, object} -> {reason, object.key} end) == [
             {:missing, "public0001/manifest.json"},
             {:missing, "public0001/v1/video.mp4"},
             {:missing, "themes/player/default.css"}
           ]

    assert plan.revoke == []
    assert plan.orphaned == []
  end

  test "revokes standby objects that are not public, even when the primary still has them" do
    primary = [object("public0001/manifest.json"), object("private001/manifest.json")]

    standby = [
      object("public0001/manifest.json"),
      object("private001/manifest.json"),
      object("deleted001/manifest.json"),
      object("status.json")
    ]

    plan = Plan.build(primary, standby, ["public0001"])

    assert plan.copy == []
    assert plan.in_sync == 1
    assert plan.orphaned == []

    assert plan.revoke |> Enum.map(& &1.key) |> Enum.sort() == [
             "deleted001/manifest.json",
             "private001/manifest.json",
             "status.json"
           ]
  end

  test "separates objects that vanished from the primary from revoked ones" do
    standby = [object("public0001/manifest.json"), object("public0001/v1/old.mp4")]
    plan = Plan.build([object("public0001/manifest.json")], standby, ["public0001"])

    assert Enum.map(plan.orphaned, & &1.key) == ["public0001/v1/old.mp4"]
    assert plan.revoke == []
  end

  test "a different size or MD5 ETag marks the standby object as stale" do
    primary = [
      object("public0001/manifest.json", size: 20),
      object("public0001/playlist.m3u8", etag: @md5_b)
    ]

    standby = [object("public0001/manifest.json"), object("public0001/playlist.m3u8")]
    plan = Plan.build(primary, standby, ["public0001"])

    assert Enum.map(plan.copy, fn {reason, object} -> {reason, object.key} end) == [
             {:stale, "public0001/manifest.json"},
             {:stale, "public0001/playlist.m3u8"}
           ]
  end

  test "multipart ETags are compared by size and age instead of content hash" do
    primary = object("public0001/v1/video.mp4", etag: "#{@md5_a}-3", at: ~U[2026-01-02 00:00:00Z])
    newer = object("public0001/v1/video.mp4", etag: "#{@md5_b}-9", at: ~U[2026-01-02 00:05:00Z])
    older = %{newer | last_modified: ~U[2026-01-01 00:00:00Z]}

    assert Plan.current?(primary, newer)
    refute Plan.current?(primary, older)
    refute Plan.current?(primary, %{newer | size_bytes: 11})
  end
end
