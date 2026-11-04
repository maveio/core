defmodule MaveCore.Assets.AudioLabelsTest do
  use ExUnit.Case, async: true

  alias MaveCore.Assets.{AudioDescription, AudioTrack}

  test "original audio follows its known language and leaves custom labels unchanged" do
    for {language, name} <- [
          {"nl", "Dutch"},
          {"en", "English"},
          {"fr", "French"},
          {"de-DE", "German"}
        ] do
      assert AudioTrack.display_label(%AudioTrack{
               label: "Original",
               default: true,
               language: language
             }) == "#{name} (original)"
    end

    for language <- [nil, "", "und", "unknown"] do
      assert AudioTrack.display_label(%AudioTrack{
               label: "Original",
               default: true,
               language: language
             }) == "Original"
    end

    assert AudioTrack.display_label(%AudioTrack{
             label: "Studio mix",
             default: true,
             language: "nl"
           }) == "Studio mix"

    assert AudioTrack.display_label(%AudioTrack{
             label: "Original",
             default: false,
             language: "nl"
           }) == "Original"
  end

  test "descriptions use language defaults, including old generated labels, but preserve custom labels" do
    for {language, name} <- [{"nl", "Dutch"}, {"en", "English"}, {"fr", "French"}] do
      for label <- [nil, "", name, "#{name} (audio description)"] do
        assert AudioDescription.display_label(%AudioDescription{language: language, label: label}) ==
                 "#{name} (AD)"
      end
    end

    assert AudioDescription.display_label(%AudioDescription{
             language: "nl",
             label: "Accessible narration",
             user_managed: true
           }) == "Accessible narration"

    assert AudioDescription.display_label(%AudioDescription{
             language: "fr",
             label: "Dutch",
             user_managed: true
           }) == "Dutch"
  end
end
