defmodule MaveCore.Playback.MinioTest do
  use ExUnit.Case, async: true

  alias MaveCore.Playback.Minio, as: Local

  test "local policy permits only public prefixes without granting anonymous writes" do
    {:ok, policy} = Local.bucket_policy("space-test", ["public-video", "public-video"])
    assert policy["Version"] == "2012-10-17"
    assert [statement] = policy["Statement"]
    assert statement["Action"] == "s3:GetObject"

    assert statement["Resource"] == [
             "arn:aws:s3:::space-test/themes/*",
             "arn:aws:s3:::space-test/*/player.html",
             "arn:aws:s3:::space-test/public-video/*"
           ]
  end
end
