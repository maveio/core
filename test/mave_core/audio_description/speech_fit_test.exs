defmodule MaveCore.AudioDescription.SpeechFitTest do
  use ExUnit.Case, async: true
  alias MaveCore.AudioDescription.SpeechFit

  defp pcm(seconds), do: :binary.copy(<<1, 0>>, round(seconds * 24_000))
  defp cue(text), do: %{text: text, window: %{start: 2.0, end: 4.0}, max_words: 4}

  defp prediction(text, seconds),
    do: %{
      "duration_source" => "heuristic_estimate",
      "attempted_text" => text,
      "estimated_seconds" => seconds,
      "words_per_second" => length(String.split(text)) / seconds
    }

  test "clearly oversized text is shortened before any synthesis request" do
    item = cue("A visitor in a bright red coat opens the heavy door.")
    estimate = fn text -> prediction(text, if(text == "Opens door.", do: 1.0, else: 8.0)) end
    speak = fn "Opens door.", :moderate -> {:ok, pcm(1.2)} end

    rewrite = fn _, _, _, feedback ->
      assert feedback["duration_source"] == "heuristic_estimate"
      assert feedback["estimated_seconds"] == 8.0
      refute Map.has_key?(feedback, "measured_seconds")
      {:ok, "Opens door."}
    end

    assert {:ok, %{text: "Opens door."}, _, "shortened"} =
             SpeechFit.fit(item, speak, rewrite, estimate: estimate)
  end

  test "borderline predictions use real audio rather than unnecessarily rewriting" do
    item = cue("A visitor opens the door.")

    assert {:ok, ^item, _, "original"} =
             SpeechFit.fit(
               item,
               fn _, :moderate -> {:ok, pcm(1.8)} end,
               fn _, _, _, _ -> flunk("uncertain estimate must not force a rewrite") end,
               estimate: &prediction(&1, 2.2)
             )
  end

  test "an inaccurate estimate cannot discard original text after an invalid rewrite" do
    item = cue("Call 112.")

    assert {:ok, ^item, _, "original"} =
             SpeechFit.fit(
               item,
               fn _, :moderate -> {:ok, pcm(1.5)} end,
               fn _, _, _, _ -> {:ok, "Call."} end,
               estimate: &prediction(&1, 8.0)
             )
  end

  test "preflight and measured correction share the same bounded rewrite allowance" do
    original = "A visitor in a bright coat enters through the doorway."
    item = cue(original)
    estimate = fn text -> prediction(text, if(text == original, do: 8.0, else: 1.0)) end

    speak = fn
      "Visitor enters.", _ -> {:ok, pcm(3.5)}
      "Enters.", _ -> {:ok, pcm(1.0)}
    end

    rewrite = fn _, _, _, feedback ->
      send(self(), {:rewrite_source, feedback["duration_source"]})

      if feedback["duration_source"] == "heuristic_estimate",
        do: {:ok, "Visitor enters."},
        else: {:ok, "Enters."}
    end

    assert {:ok, %{text: "Enters."}, _, "shortened"} =
             SpeechFit.fit(item, speak, rewrite, estimate: estimate)

    assert_received {:rewrite_source, "heuristic_estimate"}
    assert_received {:rewrite_source, "measured_audio"}
    refute_received {:rewrite_source, _}
  end

  test "truncated or malformed preflight revisions fall back to measuring the valid original" do
    item = cue("A door opens.")

    for reason <- [
          :model_output_truncated,
          :invalid_model_json,
          :empty_model_answer,
          :invalid_description_rewrite
        ] do
      assert {:ok, ^item, _, "original"} =
               SpeechFit.fit(
                 item,
                 fn _, :moderate -> {:ok, pcm(1.5)} end,
                 fn _, _, _, _ -> {:error, reason} end,
                 estimate: &prediction(&1, 8.0)
               )
    end
  end

  test "a truncated measured revision can recover within the existing two rewrites" do
    original = "A line appears between the two circles."

    rewrite = fn ^original, _, _, feedback ->
      if feedback["previous_rewrite_error"] == "model_output_truncated",
        do: {:ok, "A line connects them."},
        else: {:error, :model_output_truncated}
    end

    speak = fn
      ^original, :moderate -> {:ok, pcm(5)}
      "A line connects them.", :moderate -> {:ok, pcm(1.6)}
    end

    assert {:ok, %{text: "A line connects them."}, _, "shortened"} =
             SpeechFit.fit(cue(original), speak, rewrite)
  end

  test "repeated truncation omits only that cue with an explicit reason" do
    rewrite = fn _, _, _ ->
      send(self(), :truncated_revision)
      {:error, :model_output_truncated}
    end

    assert {:skip, "rewrite_model_output_truncated"} =
             SpeechFit.fit(
               cue("A large door opens."),
               fn _, _ -> {:ok, pcm(4.0)} end,
               rewrite
             )

    assert_received :truncated_revision
    assert_received :truncated_revision
    refute_received :truncated_revision
  end

  test "transient revision failures retain retryable errors" do
    assert {:error, :timeout} =
             SpeechFit.fit(
               cue("A large door opens."),
               fn _, _ -> {:ok, pcm(4.0)} end,
               fn _, _, _ -> {:error, :timeout} end
             )
  end

  test "measured speech takes precedence over a conservative planning word estimate" do
    item = %{text: "A cyclist crosses the bridge.", window: %{start: 0.0, end: 2.0}, max_words: 3}

    assert {:ok, ^item, _, "original"} =
             SpeechFit.fit(item, fn _, :moderate -> {:ok, pcm(1.8)} end, fn _, _, _ ->
               flunk("the complete spoken description already fits")
             end)
  end

  test "naturally quick speech that fits is not rejected by a written word-rate heuristic" do
    item = %{
      text: "A visitor walks outside and towards a door.",
      window: %{start: 4.0, end: 8.0},
      max_words: 9
    }

    assert {:ok, ^item, _, "original"} =
             SpeechFit.fit(item, fn _, :moderate -> {:ok, pcm(2.0)} end, fn _, _, _ ->
               flunk("a complete two-second clip fits in four seconds")
             end)
  end

  test "a grammatical rewrite may exceed the estimated word target when its audio fits" do
    original = "A visitor with a coat goes inside."
    natural = "The visitor goes inside."
    item = %{cue(original) | max_words: 2}

    speak = fn
      ^original, _ -> {:ok, pcm(5.0)}
      ^natural, _ -> {:ok, pcm(1.7)}
    end

    rewrite = fn _, _, target ->
      assert target == 2
      {:ok, natural}
    end

    assert {:ok, %{text: ^natural}, _, "shortened"} = SpeechFit.fit(item, speak, rewrite)
  end

  test "preflight also preserves a complete phrase above the estimated word target" do
    original = "A visitor with a coat goes inside."
    natural = "The visitor goes inside."
    estimate = fn text -> prediction(text, if(text == original, do: 8.0, else: 1.7)) end

    rewrite = fn _, _, target ->
      assert target < 4
      {:ok, natural}
    end

    assert {:ok, %{text: ^natural}, _, "shortened"} =
             SpeechFit.fit(cue(original), fn ^natural, _ -> {:ok, pcm(1.7)} end, rewrite,
               estimate: estimate
             )
  end

  test "a rewrite above the word target still cannot exceed its audio window" do
    item = %{cue("A visitor with a coat goes inside.") | max_words: 2}

    assert {:skip, "speech_too_long"} =
             SpeechFit.fit(item, fn _, _ -> {:ok, pcm(4.0)} end, fn _, _, _ ->
               {:ok, "The visitor goes inside."}
             end)
  end

  test "a useful cue uses its bounded extension before a preflight rewrite" do
    item =
      cue("A cyclist rides across the old bridge.")
      |> Map.merge(%{priority: 2, duck_window: %{start: 2.0, end: 4.6}})

    assert {:ok, fitted, _, "original"} =
             SpeechFit.fit(
               item,
               fn _, :moderate -> {:ok, pcm(2.5)} end,
               fn _, _, _ -> flunk("the natural sentence fits the reserved extension") end,
               estimate: &prediction(&1, 3.0)
             )

    assert fitted.text == item.text
    assert fitted.window == item.duck_window
    assert fitted.allow_ducking
  end

  test "essential text uses its reserved silent extension without changing the message" do
    text = "Read the guide at example.org/accessibility."

    item = %{
      text: text,
      kind: "text",
      priority: 3,
      on_screen_text: text,
      window: %{start: 10.0, end: 15.0},
      duck_window: %{start: 10.0, end: 17.0},
      max_words: 12
    }

    assert {:ok, fitted, _, "original"} =
             SpeechFit.fit(
               item,
               fn ^text, :moderate -> {:ok, pcm(5.8)} end,
               fn _, _, _ -> flunk("the full essential message fits its reserved time") end,
               estimate: &prediction(&1, 6.0)
             )

    assert fitted.text == text
    assert fitted.window == item.duck_window
  end

  test "shortening cannot replace an explicit person with an unintroduced pronoun" do
    for {original, shortened} <- [
          {"A woman stands beside a railing.", "She waits."},
          {"Een vrouw staat bij een leuning.", "Ze wacht."}
        ] do
      assert {:skip, "no_fitting_rewrite"} =
               SpeechFit.fit(
                 cue(original),
                 fn _, _ -> {:ok, pcm(4.0)} end,
                 fn _, _, _ -> {:ok, shortened} end
               )
    end
  end

  test "each rewrite receives measured speech feedback and retains the original event" do
    original = "A person in a bright coat walks through a hall."
    item = %{text: original, window: %{start: 0.0, end: 3.0}, max_words: 8}

    speak = fn
      ^original, _ -> {:ok, pcm(6.0)}
      "Person walks through the hall.", _ -> {:ok, pcm(4.5)}
      "Crosses the hall.", _ -> {:ok, pcm(1.8)}
    end

    rewrite = fn ^original, 3.0, limit, measured ->
      send(self(), {:feedback, limit, measured})

      if measured["attempted_text"] == original,
        do: {:ok, "Person walks through the hall."},
        else: {:ok, "Crosses the hall."}
    end

    assert {:ok, %{text: "Crosses the hall."}, _, "shortened"} =
             SpeechFit.fit(item, speak, rewrite)

    assert_received {:feedback, 5, first}
    assert first["measured_seconds"] == 6.0
    assert first["available_seconds"] == 3.0
    assert_received {:feedback, 3, second}
    assert second["attempted_text"] == "Person walks through the hall."
    assert second["measured_seconds"] == 4.5
    assert second["target_max_words"] == 3
  end

  test "rewriting remains bounded even when the voice never fits" do
    item = %{text: "A rider crosses a bridge.", window: %{start: 0.0, end: 2.0}, max_words: 4}

    rewrite = fn _, _, limit, feedback ->
      send(self(), {:bounded_attempt, feedback["measured_seconds"]})
      if limit >= 2, do: {:ok, "Crosses bridge."}, else: {:ok, "Crosses."}
    end

    assert {:skip, "speech_too_long"} =
             SpeechFit.fit(item, fn _, _ -> {:ok, pcm(4.0)} end, rewrite)

    assert_received {:bounded_attempt, 4.0}
    assert_received {:bounded_attempt, 4.0}
    refute_received {:bounded_attempt, _}
  end

  test "a complete text-card message is measured without framing before a destructive rewrite" do
    required = "Read the article at example.org/news"

    item = %{
      text: "A dark screen says: #{required}. A logo then appears.",
      kind: "text",
      on_screen_text: required,
      window: %{start: 100.0, end: 108.0},
      max_words: 16
    }

    speak = fn text, _ -> {:ok, pcm(if text == required, do: 6.5, else: 12.0)} end

    assert {:ok, fitted, _, "shortened"} =
             SpeechFit.fit(item, speak, fn _, _, _ -> flunk("literal message already fits") end)

    assert fitted.text == required
    assert fitted.on_screen_text == required
  end

  test "literal text cannot silently discard another numeric instruction" do
    item = Map.merge(cue("Press 2, then Call 112."), %{kind: "text", on_screen_text: "Call 112."})
    speak = fn _, _ -> {:ok, pcm(3.0)} end

    assert {:skip, "no_fitting_rewrite"} =
             SpeechFit.fit(item, speak, fn _, _, _ -> {:ok, "Call 112."} end)
  end

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

  test "sentence punctuation does not reject a complete visible message" do
    item =
      Map.merge(cue("The library, www.example.org."), %{
        kind: "text",
        on_screen_text: "The library www.example.org"
      })

    assert {:ok, ^item, _, "original"} =
             SpeechFit.fit(item, fn _, _ -> {:ok, pcm(1.5)} end, fn _, _, _ ->
               flunk("punctuation alone must not force a rewrite")
             end)

    assert SpeechFit.missing_text(["The library www.example.org"], item.text, "") == []
  end

  test "punctuation normalization still distinguishes different URLs and numeric values" do
    for {required, text} <- [
          {"example.org/guide", "Visit example.org/guidebook."},
          {"example.org/guide", "Visit example.org.guide."},
          {"3.14", "The value is 3,14."}
        ] do
      item = Map.put(cue(text), :on_screen_text, required)

      assert {:skip, "missing_on_screen_text"} =
               SpeechFit.fit(item, fn _, _ -> flunk("wrong literal text") end, fn _, _, _ ->
                 flunk("wrong literal text")
               end)

      assert SpeechFit.missing_text([required], text, "") == [required]
    end
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
