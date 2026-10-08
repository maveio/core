defmodule MaveCore.DockerfileSecurityTest do
  use ExUnit.Case, async: true

  @ffmpeg_release_fingerprint "FCF986EA15E6E293A5644F10B4322F04D67658D8"
  @dockerfile_path Path.expand("../../Dockerfile", __DIR__)

  test "FFmpeg release verification is bound to the pinned signer" do
    dockerfile = File.read!(@dockerfile_path)

    assert dockerfile =~
             "gpg --batch --assert-signer #{@ffmpeg_release_fingerprint} " <>
               "\\\n    --verify /tmp/ffmpeg.tar.xz.asc /tmp/ffmpeg.tar.xz"

    refute dockerfile =~
             "gpg --batch --verify /tmp/ffmpeg.tar.xz.asc /tmp/ffmpeg.tar.xz"
  end
end
