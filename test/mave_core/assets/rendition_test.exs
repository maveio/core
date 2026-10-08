defmodule MaveCore.Assets.RenditionTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset

  alias MaveCore.Assets.Rendition

  test "changeset accepts legacy-compatible rendition values" do
    changeset =
      Rendition.changeset(%Rendition{}, %{
        "video_id" => Ecto.UUID.generate(),
        "rendition_key" => "LeDE9v86ye/h264_sd.mp4",
        "type" => "video",
        "codec" => "h264",
        "container" => "mp4",
        "size" => "sd",
        "progress" => 100.0,
        "file_size" => 1_234_567
      })

    assert changeset.valid?
    assert get_change(changeset, :type) == :video
    assert get_change(changeset, :codec) == :h264
    assert get_change(changeset, :container) == :mp4
    assert get_change(changeset, :size) == :sd
  end

  test "changeset requires video id, key, and type" do
    changeset = Rendition.changeset(%Rendition{}, %{})

    refute changeset.valid?
    assert Keyword.has_key?(changeset.errors, :video_id)
    assert Keyword.has_key?(changeset.errors, :rendition_key)
    assert Keyword.has_key?(changeset.errors, :type)
  end
end
