defmodule MaveCore.AudioDescription.DescriptionDocumentTest do
  use ExUnit.Case, async: true
  alias MaveCore.AudioDescription.DescriptionDocument
  alias MaveCore.Transcription.SubtitleDocument

  setup do
    {:ok, source} =
      SubtitleDocument.parse(
        "WEBVTT\n\n00:02.000 --> 00:03.000\nA plane.\n\n00:04.000 --> 00:05.000\nA woman.\n"
      )

    %{source: source, moments: DescriptionDocument.from_vtt(source)}
  end

  test "descriptions in one speech pause share one budget", %{source: source, moments: moments} do
    assert [%{count: 2, state: "within", available: 6.0}] =
             DescriptionDocument.groups(moments, [%{start: 1.0, end: 7.0}], source, "en")

    longer =
      List.update_at(moments, 1, &Map.put(&1, "text", String.duplicate("A plane flies. ", 30)))

    assert [%{count: 2, state: "over", excess: excess}] =
             DescriptionDocument.groups(longer, [%{start: 1.0, end: 7.0}], source, "en")

    assert excess > 0
  end

  test "an empty new moment keeps the existing group's count and feedback", %{
    source: source,
    moments: moments
  } do
    gaps = [%{start: 1.0, end: 7.0}]
    [before] = DescriptionDocument.groups(moments, gaps, source, "en")
    blank = %{"id" => "new", "start" => 5.0, "text" => ""}
    [after_insert] = DescriptionDocument.groups(moments ++ [blank], gaps, source, "en")
    assert after_insert.count == 2
    assert after_insert.after_id == "new"
    assert after_insert.remaining == before.remaining
    filled = %{blank | "text" => "A new description."}
    [after_typing] = DescriptionDocument.groups(moments ++ [filled], gaps, source, "en")
    assert after_typing.count == 3
    assert after_typing.after_id == after_insert.after_id
  end

  test "saving rejects backward, duplicate and unfinished time labels", %{moments: moments} do
    assert :ok = DescriptionDocument.validate_time_labels(moments)

    for partial <- ["[", "[00", "[00:", "[00:40]"] do
      assert {:error, :invalid_time_labels} =
               DescriptionDocument.validate_time_labels([
                 %{"start" => 2.0, "text" => "Text " <> partial}
               ])
    end

    assert {:error, :invalid_time_labels} =
             DescriptionDocument.validate_time_labels(Enum.reverse(moments))

    assert {:error, :invalid_time_labels} =
             DescriptionDocument.validate_time_labels([hd(moments), hd(moments)])

    assert {:error, :invalid_time_labels} =
             DescriptionDocument.validate_time_labels([
               %{"start" => 2.0, "text" => "Text [00:40"}
             ])
  end

  test "playback windows retain published speech duration and shift the next line after a longer edit",
       %{
         source: source,
         moments: moments
       } do
    assert [%{start: 2.0, end: 3.0}, %{start: 4.0, end: 5.0}] =
             DescriptionDocument.playback_windows(moments, source, "en", 10.0)

    longer =
      List.update_at(moments, 0, &Map.put(&1, "text", String.duplicate("A plane flies. ", 3)))

    assert [%{start: 2.0, end: stop}, %{start: next}] =
             DescriptionDocument.playback_windows(longer, source, "en", 10.0)

    assert stop > 4.0 and next == stop
  end

  test "separate pauses have independent budgets", %{source: source, moments: moments} do
    groups =
      DescriptionDocument.groups(
        moments,
        [%{start: 1.5, end: 3.1}, %{start: 3.5, end: 6.0}],
        source,
        "en"
      )

    assert length(groups) == 2
    assert Enum.all?(groups, &(&1.count == 1))
  end

  test "missing timing, unanchored text and distant pauses are explicit", %{
    source: source,
    moments: moments
  } do
    assert [%{state: "unknown"}] = DescriptionDocument.groups(moments, nil, source, "en")

    assert [%{state: "unplaced"}] =
             DescriptionDocument.groups(moments, [%{start: 20.0, end: 30.0}], source, "en")

    untimed = [%{"id" => "unplaced", "start" => nil, "text" => "Keep this text"}]
    assert {:ok, ^untimed} = DescriptionDocument.validate(untimed, 30.0)
    assert [%{state: "untimed"}] = DescriptionDocument.groups(untimed, [], source, "en")
  end

  test "moments cannot move beyond the video or reuse another identity", %{moments: moments} do
    assert {:error, :invalid_moments} = DescriptionDocument.validate(moments ++ moments, 30.0)

    assert {:error, :invalid_moments} =
             DescriptionDocument.validate(
               [%{"id" => "new", "start" => 30.0, "text" => "Text"}],
               30.0
             )

    assert {:ok, []} = DescriptionDocument.validate([], 30.0)
  end
end
