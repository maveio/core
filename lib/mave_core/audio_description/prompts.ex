defmodule MaveCore.AudioDescription.Prompts do
  @moduledoc """
  Instructions and response schemas for the description and translation models.
  """

  alias MaveCore.Languages

  @cues_schema %{
    "type" => "object",
    "properties" => %{
      "duration_seconds" => %{"type" => "number"},
      "cues" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "shot" => %{
              "type" => "integer",
              "description" => "Number of the scene this describes (S3 -> 3)"
            },
            "pause" => %{
              "type" => "integer",
              "description" =>
                "Number of the pause it is placed in (P2 -> 2), or -1 during speech"
            },
            "max_words" => %{
              "type" => "integer",
              "description" => "Word limit for text: the pause's max words, or 6 during speech"
            },
            "start" => %{"type" => "string", "description" => "HH:MM:SS.mmm"},
            "end" => %{"type" => "string", "description" => "HH:MM:SS.mmm"},
            "text" => %{"type" => "string"}
          },
          "required" => ["shot", "pause", "max_words", "start", "end", "text"]
        }
      }
    },
    "required" => ["duration_seconds", "cues"]
  }

  @translations_schema %{
    "type" => "object",
    "properties" => %{"translations" => %{"type" => "array", "items" => %{"type" => "string"}}},
    "required" => ["translations"]
  }

  def cues_schema, do: @cues_schema
  def translations_schema, do: @translations_schema

  @doc "The describer's instructions, followed by the timing context (`Timeline.timing_prompt/4`)."
  def describe_instruction(duration, timing) do
    [
      "You are a professional audio describer. You write the audio description track for a video,",
      "so that blind and low-vision viewers can follow what happens on screen.",
      "",
      "Rules:",
      "- Write every description in English, regardless of the language spoken in the video.",
      "- Describe what is visible: actions, people (by appearance and role, use names only if shown on screen),",
      "  setting, scene and location changes, facial expressions and on-screen text (read text out; keep brand names,",
      "  logos and URLs exactly as written).",
      "- Do not describe what can be heard (dialogue, narration, music) unless it is needed to understand the image.",
      "- Present tense, objective, concise. No interpretation, no speculation, no 'we see' or 'the camera shows'.",
      "",
      "Sync with the picture (scenes come from cut detection, listed below):",
      "- Every description is about one scene. Set `shot` to that scene's number (S3 -> 3). The description must",
      "  start while that scene is on screen and be timed to the moment the thing it describes is visible.",
      "  Never describe a scene after the video has cut away from it.",
      "- A scene can contain several quick cuts. Then say in one description what the cuts show together, most",
      "  important first (e.g. 'Terrace, garden pond, women with headphones.'), rather than only the first cut.",
      "- Describe what is new or changed. Don't repeat what an earlier description already said; skip a moment",
      "  when nothing new happens.",
      "- At most one description per scene, plus one more for every further 6 seconds of a long scene. More",
      "  descriptions don't fit between the speech and get dropped.",
      "",
      "Timing around the original speech (measured with speech recognition, listed below):",
      "- Put descriptions inside a pause that overlaps their shot, so the original audio stays clear. Set `pause`",
      "  to its number (P2 -> 2); the description must start and end inside that pause.",
      "- First set `max_words`: the pause's 'max words', or at most 6 for a description during speech. Then",
      "  write `text` with no more than `max_words` words. Short beats complete: 'Kitchen, dirty dishes.' is a",
      "  good 3-word description. Never write two sentences for one cue.",
      "- A long pause can hold several descriptions, each at the moment its event happens.",
      "- Skip pauses with a budget under 2 words.",
      "- When a shot has no usable pause but needs a description, place a short one during that shot's speech",
      "  with `pause` = -1; the original audio is then lowered while it plays.",
      "- Each cue lasts 1 to 8 seconds. Cues are chronological and never overlap each other.",
      "- Timestamps are relative to the start of the video, formatted HH:MM:SS.mmm.",
      duration_line(duration),
      "- Also report the total video duration in seconds as duration_seconds.",
      "",
      timing
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp duration_line(duration) when is_number(duration) and duration > 0 do
    "- The video is #{:erlang.float_to_binary(duration * 1.0, decimals: 3)} seconds long; no cue may end after that."
  end

  defp duration_line(_duration), do: ""

  @doc "The closing text of a batch of labelled stills."
  def stills_request(window, previous_texts) do
    previous =
      case previous_texts do
        [] ->
          nil

        texts ->
          "Already described just before this part (don't repeat):\n" <>
            Enum.map_join(texts, "\n", &"- #{&1}")
      end

    [
      "These are stills from #{seconds(window.start)}-#{seconds(window.end)} s of the video (at least one per camera",
      "cut), labelled with their scene and time. Write the audio description cues for this part, in English.",
      previous
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  @doc "Translation instructions and the JSON input list for `cues`."
  def translation_request(cues, language) do
    name = "#{Languages.spoken_language(language) || language} (#{language})"

    input =
      cues
      |> Enum.with_index()
      |> Enum.map(fn {cue, i} ->
        %{"i" => i, "seconds" => Float.round((cue.end - cue.start) * 1.0, 1), "text" => cue.text}
      end)

    instruction =
      Enum.join(
        [
          "You translate an English audio description track for blind and low-vision viewers into #{name}.",
          "Each item is spoken in a time slot of the video, so it must not run longer than its 'seconds'.",
          "Rules:",
          "- Translate every item; return exactly one translation per input item, in the same order, as `translations`.",
          "- Keep the meaning, tone and present tense. Natural, idiomatic, concise spoken language.",
          "- Each translation must be speakable within the item's 'seconds' at about 2.5 words per second;",
          "  shorten the wording rather than exceed it.",
          "- Keep brand names, logos and URLs exactly as written.",
          "- Don't add information, notes, numbering or quotes."
        ],
        "\n"
      )

    {instruction, input}
  end

  @doc "Exactly one non-empty translation per cue, or an error."
  def check_translations(results, count) when is_list(results) do
    if length(results) == count and Enum.all?(results, &(is_binary(&1) and String.trim(&1) != "")) do
      {:ok, Enum.map(results, &String.trim/1)}
    else
      {:error, {:translation_count_mismatch, length(results), count}}
    end
  end

  def check_translations(_results, count), do: {:error, {:translation_count_mismatch, 0, count}}

  defp seconds(value), do: :erlang.float_to_binary(value * 1.0, decimals: 2)
end
