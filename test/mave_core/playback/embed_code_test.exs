defmodule MaveCore.Playback.EmbedCodeTest do
  use ExUnit.Case, async: true
  alias MaveCore.Playback.EmbedCode

  test "browser examples put the token directly in the HTML attribute" do
    html =
      EmbedCode.add_token(
        ~s(<mave-player embed="spacevideo00001"></mave-player>),
        :script,
        "spacevideo00001",
        "mave-player"
      )

    assert html ==
             ~s(<mave-player embed="spacevideo00001" token="YOUR_PLAYBACK_TOKEN"></mave-player>)

    refute html =~ "<script"
  end

  test "framework examples use dynamic token bindings" do
    assert EmbedCode.add_token(~s(<Player embed="video"></Player>), :react, "video", "Player") =~
             ~s(<Player token={playbackToken} embed="video")

    assert EmbedCode.add_token(~s(<Player embed="video"></Player>), :vue, "video", "Player") =~
             ~s(<Player :token="playbackToken" embed="video")
  end
end
