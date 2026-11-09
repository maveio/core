defmodule MaveCore.AudioDescription.SpeechFitTest do
  use ExUnit.Case, async: true
  alias MaveCore.AudioDescription.SpeechFit

  defp pcm(seconds), do: :binary.copy(<<1, 0>>, round(seconds * 24_000))
  defp cue(text), do: %{text: text, window: %{start: 2.0, end: 4.0}, max_words: 4}

  test "keeps complete speech that fits without rewriting" do
    assert {:ok, %{text: "Call 112."}, _, "original"} =
             SpeechFit.fit(cue("Call 112."), fn _, :moderate -> {:ok, pcm(1.5)} end, fn _, _, _ ->
               flunk("unneeded rewrite")
             end)
  end

  test "rewrites an oversized phrase, then checks the real duration again" do
    speak = fn text, _ -> {:ok, pcm(if text == "Call 112.", do: 1.5, else: 3.5)} end

    rewrite = fn _, 2.0, limit ->
      assert limit < 4
      {:ok, "Call 112."}
    end

    assert {:ok, %{text: "Call 112."}, _, "shortened"} =
             SpeechFit.fit(cue("In an emergency call 112."), speak, rewrite)
  end

  test "rounding a word estimate does not discard a short phrase that measurably fits" do
    item = %{text: "A person with a headset.", window: %{start: 0.0, end: 1.5}, max_words: 3}
    speak = fn text, _ -> {:ok, pcm(if text == "Wearing a headset.", do: 1.4, else: 3.0)} end

    rewrite = fn _, _, limit ->
      assert limit == 3
      {:ok, "Wearing a headset."}
    end

    assert {:ok, %{text: "Wearing a headset."}, _, "shortened"} =
             SpeechFit.fit(item, speak, rewrite)
  end

  test "a measured overrun gets one shorter rewrite before an important cue is dropped" do
    item = %{
      text: "A visitor walks into the station.",
      window: %{start: 0.0, end: 2.0},
      max_words: 4
    }

    speak = fn
      "Visitor enters.", _ -> {:ok, pcm(1.5)}
      _, _ -> {:ok, pcm(3.0)}
    end

    rewrite = fn _, _, limit ->
      if limit == 4, do: {:ok, "Visitor enters the station."}, else: {:ok, "Visitor enters."}
    end

    assert {:ok, %{text: "Visitor enters."}, _, "shortened"} = SpeechFit.fit(item, speak, rewrite)
  end

  test "only uses a modest speed increase after shortening" do
    speak = fn
      "Call 112.", :moderate -> {:ok, pcm(2.1)}
      "Call 112.", :fast -> {:ok, pcm(1.9)}
      _, _ -> {:ok, pcm(3.5)}
    end

    assert {:ok, _, _, "shortened_faster"} =
             SpeechFit.fit(cue("In an emergency call 112."), speak, fn _, _, _ ->
               {:ok, "Call 112."}
             end)
  end

  test "never accepts a cut sentence, excessive speed, or an unbounded rewrite" do
    speak = fn
      _, :moderate -> {:ok, pcm(2.1)}
      _, :fast -> {:ok, pcm(0.9)}
    end

    assert {:skip, "speech_too_long"} =
             SpeechFit.fit(cue("Call for assistance immediately."), speak, fn _, _, _ ->
               {:ok, "Call."}
             end)

    assert {:skip, "no_fitting_rewrite"} =
             SpeechFit.fit(cue("Call for assistance immediately."), speak, fn _, _, _ ->
               {:ok, "This rewrite is much longer than requested."}
             end)
  end

  test "shortening cannot silently remove or change numbers and required on-screen text" do
    slow = fn _, _ -> {:ok, pcm(3.0)} end

    assert {:skip, "no_fitting_rewrite"} =
             SpeechFit.fit(cue("Call 112 now."), slow, fn _, _, _ -> {:ok, "Call."} end)

    assert {:skip, "no_fitting_rewrite"} =
             SpeechFit.fit(cue("Call 12 now."), slow, fn _, _, _ -> {:ok, "112."} end)

    label = Map.put(cue("Press Save now."), :on_screen_text, "Save")

    assert {:skip, "no_fitting_rewrite"} =
             SpeechFit.fit(label, slow, fn _, _, _ -> {:ok, "Press."} end)

    assert {:skip, "missing_on_screen_text"} =
             SpeechFit.fit(Map.put(label, :text, "Press now."), slow, fn _, _, _ ->
               flunk("invalid cue")
             end)
  end

  test "essential text counts as covered when already spoken, but missing text is reported" do
    assert SpeechFit.missing_text(
             ["Open settings", "Press Save", "Call 112"],
             "Open settings.",
             "The narrator says Press Save."
           ) == ["Call 112"]
  end

  test "tries shortening and faster speech before falling back to ducking" do
    item = %{
      text: "Please call 112 right now.",
      priority: 3,
      max_words: 2,
      window: %{start: 1.0, end: 2.0},
      duck_window: %{start: 2.0, end: 4.0}
    }

    speak = fn
      "Please call 112 right now.", :moderate ->
        send(self(), :original)
        {:ok, pcm(1.8)}

      "Call 112.", :moderate ->
        send(self(), :shortened)
        {:ok, pcm(1.1)}

      "Call 112.", :fast ->
        send(self(), :faster)
        {:ok, pcm(1.01)}
    end

    rewrite = fn _, _, _ ->
      send(self(), :rewrite)
      {:ok, "Call 112."}
    end

    assert {:ok, %{allow_ducking: true, window: %{start: 2.0}}, _, _} =
             SpeechFit.fit(item, speak, rewrite)

    assert_received :rewrite
    assert_received :shortened
    assert_received :faster
  end

  test "does not use ducking when a shorter description fits the pause" do
    item =
      cue("Please call 112 right now.")
      |> Map.merge(%{priority: 3, duck_window: %{start: 4.0, end: 7.0}})

    speak = fn text, _ -> {:ok, pcm(if text == "Call 112.", do: 1.0, else: 3.0)} end

    assert {:ok, fitted, _, "shortened"} =
             SpeechFit.fit(item, speak, fn _, _, _ -> {:ok, "Call 112."} end)

    refute fitted[:allow_ducking]
    assert fitted.window == item.window
  end

  test "optional information cannot opt into ducking" do
    item =
      cue("A blue background.") |> Map.merge(%{priority: 1, duck_window: %{start: 4.0, end: 7.0}})

    assert {:skip, _} =
             SpeechFit.fit(item, fn _, _ -> {:ok, pcm(4.0)} end, fn _, _, _ -> {:ok, ""} end)
  end

  test "provider errors remain retryable rather than becoming omitted content" do
    assert {:error, :timeout} =
             SpeechFit.fit(cue("Call 112."), fn _, _ -> {:error, :timeout} end, fn _, _, _ ->
               flunk("no rewrite")
             end)
  end
end
