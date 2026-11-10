defmodule MaveCore.Flow.Steps.AudioDescriptionStepsTest do
  use ExUnit.Case, async: false

  alias MaveCore.Flow.{Definition, Presets, StepRegistry}

  alias MaveCore.Flow.Steps.{
    AiDescribeVideoStep,
    AiSpeakDescriptionsStep,
    AiTranslateDescriptionsStep,
    AudioDescriptionSupport,
    MediaBuildHlsMasterStep,
    MediaDetectScenesStep,
    MediaMixAudioDescriptionStep
  }

  alias MaveCore.TestSupport.FlowStorageAdapterStub, as: Storage

  @space "ubg50"
  @embed "LeDE9v86ye"
  @bucket "space-ubg50"
  @requested %{"languages" => ["en", "nl"]}

  defmodule DecodedJsonStorage do
    def get(_bucket, "object.json", _region), do: {:ok, %{"duration" => 12}}
    def get(_bucket, "array.json", _region), do: {:ok, [%{"text" => "A red square."}]}
  end

  test "working JSON accepts bodies already decoded by the HTTP storage adapter" do
    ctx = %{storage: DecodedJsonStorage, bucket: "test", region: nil}

    assert {:ok, %{"duration" => 12}} =
             AudioDescriptionSupport.get_json(ctx, "object.json")

    assert {:ok, [%{"text" => "A red square."}]} =
             AudioDescriptionSupport.get_json(ctx, "array.json")
  end

  defmodule ChatStub do
    alias MaveCore.AudioDescription.Cues
    @moduledoc false

    # Describes every batch of stills with one cue per scene and translates by prefixing.
    def chat_json(system, content, opts) do
      send(Process.get(:ad_test_pid) || self(), {:chat, system, content})

      case opts[:schema]["required"] do
        ["observations"] ->
          rows =
            for %{"type" => "text", "text" => label} <- content do
              [_, index] = Regex.run(~r/Frame (\d+);/, label)

              %{
                "frame" => String.to_integer(index),
                "setting" => "A room",
                "people_and_objects" => [],
                "actions" => ["Screen changes color"],
                "visible_text" => [],
                "changes" => [],
                "uncertainties" => []
              }
            end

          {:ok, %{"observations" => rows}}

        ["duration_seconds", "cues", "category", "summary", "essential_text"] ->
          {:ok,
           %{
             "duration_seconds" => 8,
             "category" => "montage",
             "summary" => "A color change",
             "essential_text" => [],
             "cues" =>
               Process.get(:ad_cues, [
                 cue(0, 0, "00:00:00.200", "00:00:01.000", "A red screen."),
                 cue(1, -1, "00:00:05.500", "00:00:06.500", "It turns blue.")
               ])
               |> Enum.with_index()
               |> Enum.filter(fn {_, i} -> i in Process.get(:ad_keep, [0, 1]) end)
               |> Enum.map(fn {c, _} ->
                 observations = Jason.decode!(List.last(content)["text"])["observations"]
                 start = Cues.parse_timestamp(c["start"])
                 closest = Enum.min_by(observations, &abs(&1["time"] - start))
                 Map.put(c, "observation_ids", [closest["id"]])
               end)
           }}

        ["category", "summary", "essential_text", "guidance"] ->
          {:ok,
           %{
             "category" => "montage",
             "summary" => "A screen changes color.",
             "essential_text" => [],
             "guidance" => "Describe changes only."
           }}

        ["keep"] ->
          [%{"text" => json}] = content
          candidates = Jason.decode!(json)["candidates"]
          {:ok, %{"keep" => Process.get(:ad_keep, Enum.map(candidates, & &1["index"]))}}

        ["text"] ->
          {:ok, %{"text" => "Red."}}

        ["translations"] ->
          [%{"text" => json}] = content
          {:ok, %{"translations" => json |> Jason.decode!() |> Enum.map(&"NL #{&1["text"]}")}}
      end
    end

    defp cue(shot, pause, start, stop, text),
      do: %{
        "shot" => shot,
        "pause" => pause,
        "max_words" => 4,
        "start" => start,
        "end" => stop,
        "text" => text
      }
  end

  defmodule RewriteWriter do
    def chat_json(_system, [%{"text" => json}], opts) do
      pid = List.last(Process.get(:"$callers", [self()]))

      send(
        pid,
        {:writer_rewrite, Jason.decode!(json), opts[:max_tokens], opts[:reasoning_effort]}
      )

      {:ok, %{"text" => "Red."}}
    end
  end

  defmodule TruncatedRewriteWriter do
    def chat_json(_, _, _), do: {:error, :model_output_truncated}
  end

  defmodule NoRewriteVision do
    def chat_json(_, _, _), do: raise("vision must not rewrite narration")
  end

  defmodule SpeechStub do
    @moduledoc false

    # One second of a 440 Hz tone as a 24 kHz WAV.
    def speak(text, language) do
      send(test_pid(), {:speak, language})

      samples = max(1, round(length(String.split(text)) / 2.5 * 24_000))

      pcm =
        for i <- 0..(samples - 1), into: <<>> do
          <<round(8000 * :math.sin(i * 2 * :math.pi() * 440 / 24_000))::little-signed-16>>
        end

      size = byte_size(pcm)

      {:ok,
       <<"RIFF", size + 36::little-32, "WAVEfmt ", 16::little-32, 1::little-16, 1::little-16,
         24_000::little-32, 48_000::little-32, 2::little-16, 16::little-16, "data",
         size::little-32, pcm::binary>>}
    end

    # Speech runs in tasks; report to the test process that started them.
    defp test_pid, do: Process.get(:ad_test_pid) || List.last(Process.get(:"$callers", [self()]))
  end

  setup do
    old = %{
      storage: Application.get_env(:mave_core, :flow_storage_adapter),
      direct: Application.get_env(:mave_core, :flow_direct_storage_ffmpeg_input),
      ad: Application.get_env(:mave_core, :audio_description)
    }

    Application.put_env(:mave_core, :flow_storage_adapter, Storage)
    Application.put_env(:mave_core, :flow_direct_storage_ffmpeg_input, false)

    Application.put_env(:mave_core, :audio_description,
      chat_provider: ChatStub,
      writer_provider: ChatStub,
      speech_provider: SpeechStub
    )

    Storage.reset!()

    on_exit(fn ->
      restore(:flow_storage_adapter, old.storage)
      restore(:flow_direct_storage_ffmpeg_input, old.direct)
      restore(:audio_description, old.ad)
    end)

    :ok
  end

  test "the publishing presets contain optional background steps that nothing waits for" do
    for slug <- ["publish_default", "publish_local", "publish_remote", "publish_remote_local"] do
      {:ok, preset} = Presets.fetch(slug)
      definition = preset["definition"]
      assert :ok = Definition.validate(definition)
      steps = definition["steps"]

      ids =
        ~w(detect_scenes describe_video speak_descriptions_original mix_audio_description_original)

      refute Enum.any?(steps, &(&1["type"] == "ai.translate_descriptions"))
      assert Enum.count(steps, &(&1["type"] == "media.mix_audio_description")) == 1

      for id <- ids do
        step = Enum.find(steps, &(&1["id"] == id))
        assert %{"required" => false, "lane" => "background"} = step
        assert StepRegistry.known_type?(step["type"])
        refute Enum.any?(steps, &(id in Map.get(&1, "depends_on", []) and &1["id"] not in ids))
      end
    end

    assert StepRegistry.executor_for("media.detect_scenes") == :flame
    assert StepRegistry.executor_for("media.mix_audio_description") == :flame
    assert StepRegistry.executor_for("ai.describe_video") == :inline
  end

  test "every step skips itself when the run didn't ask for audio description" do
    context = %{run_input: base_input(), dependency_outputs: %{}}

    for {module, params} <- [
          {MediaDetectScenesStep, %{}},
          {AiDescribeVideoStep, %{}},
          {AiTranslateDescriptionsStep, %{"language" => "nl"}},
          {AiSpeakDescriptionsStep, %{"language" => "en"}},
          {MediaMixAudioDescriptionStep, %{"language" => "en"}}
        ] do
      assert {:ok, %{"status" => "skipped", "reason" => "not_requested"}, []} =
               module.run(%{"id" => "step", "params" => params}, context)
    end
  end

  test "videos over the limit are skipped with their length" do
    context = %{
      run_input: Map.put(base_input(), "audio_description", @requested),
      dependency_outputs: %{"inspect_media" => %{"duration" => 601.0, "has_video" => true}}
    }

    assert {:ok, output, []} = MediaDetectScenesStep.run(%{"id" => "detect_scenes"}, context)

    assert %{
             "status" => "skipped",
             "reason" => "video_too_long",
             "video_duration_seconds" => 601.0,
             "max_duration_seconds" => 600
           } = output
  end

  test "the HLS master marks audio descriptions for assistive technology" do
    outputs = %{
      "hls_sd" => %{
        "step_type" => "media.package_hls_variant",
        "status" => "ok",
        "codec" => "h264",
        "size" => "sd",
        "playlist_path" => "h264_sd_hls/playlist.m3u8"
      },
      "hls_audio" => %{
        "step_type" => "media.package_hls_audio",
        "status" => "ok",
        "audio_tracks" => [
          %{
            "id" => "default",
            "label" => "Original",
            "language" => "en",
            "default" => true,
            "hls_playlist" => "audio_hls/playlist.m3u8"
          }
        ]
      },
      "mix_audio_description_nl" => %{
        "step_type" => "media.mix_audio_description",
        "status" => "ok",
        "audio_track" => %{
          "id" => "audio_description_nl",
          "label" => "Dutch (audio description)",
          "language" => "nl",
          "default" => false,
          "hls_playlist" => "audio_description_nl_hls/playlist.m3u8",
          "characteristics" => "public.accessibility.describes-video"
        }
      }
    }

    assert {:ok, %{"key" => key}, _} =
             MediaBuildHlsMasterStep.run(%{"id" => "hls_master"}, %{
               run_input: base_input(),
               dependency_outputs: outputs
             })

    {:ok, playlist} = Storage.get(@bucket, key, nil)

    assert playlist =~
             ~s|#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Dutch (audio description)",LANGUAGE="nl",DEFAULT=NO,AUTOSELECT=YES,CHARACTERISTICS="public.accessibility.describes-video",CHANNELS="2",URI="audio_description_nl_hls/playlist.m3u8"|

    assert playlist =~
             ~s|NAME="English (original)",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="2"|
  end

  test "speech revisions use the configured script writer rather than the vision provider" do
    Application.put_env(:mave_core, :audio_description,
      chat_provider: NoRewriteVision,
      writer_provider: RewriteWriter,
      speech_provider: SpeechStub
    )

    key = "#{@embed}/audio_description/en/cues.json"

    cue = %{
      "start" => 1,
      "end" => 3,
      "text" => "A large screen slowly changes into a bright red color.",
      "window" => %{"start" => 1, "end" => 3},
      "priority" => 2,
      "kind" => "action",
      "max_words" => 4
    }

    Storage.put(@bucket, key, Jason.encode!([cue]), "application/json", nil)

    context = %{
      run_input: Map.put(base_input(), "audio_description", @requested),
      dependency_outputs: %{
        "describe_video" => %{
          "status" => "ok",
          "cues_key" => key,
          "speech_key" => "speech.json",
          "duration" => 8
        }
      }
    }

    assert {:ok, %{"status" => "ok"}, []} =
             AiSpeakDescriptionsStep.run(
               %{"id" => "speak_descriptions_en", "params" => %{"language" => "en"}},
               context
             )

    assert_received {:writer_rewrite, input, 4000, "low"}
    assert input["original_event_text"] == cue["text"]
  end

  test "one truncated revision cannot discard other successfully spoken descriptions" do
    Application.put_env(:mave_core, :audio_description,
      chat_provider: NoRewriteVision,
      writer_provider: TruncatedRewriteWriter,
      speech_provider: SpeechStub
    )

    key = "#{@embed}/audio_description/en/cues.json"

    cues = [
      %{
        "start" => 1,
        "end" => 3,
        "text" => "A large screen slowly changes into a bright red color.",
        "window" => %{"start" => 1, "end" => 3},
        "priority" => 2,
        "kind" => "action",
        "max_words" => 4
      },
      %{
        "start" => 4,
        "end" => 6,
        "text" => "Blue.",
        "window" => %{"start" => 4, "end" => 6},
        "priority" => 2,
        "kind" => "action",
        "max_words" => 4
      }
    ]

    Storage.put(@bucket, key, Jason.encode!(cues), "application/json", nil)

    context = %{
      run_input: Map.put(base_input(), "audio_description", @requested),
      dependency_outputs: %{
        "describe_video" => %{
          "status" => "ok",
          "cues_key" => key,
          "speech_key" => "speech.json",
          "duration" => 8
        }
      }
    }

    assert {:ok, output, []} =
             AiSpeakDescriptionsStep.run(
               %{"id" => "speak_descriptions_en", "params" => %{"language" => "en"}},
               context
             )

    assert output["status"] == "ok"
    assert length(output["clips"]) == 1
    assert output["unplaced_cue_count"] == 1
    assert output["review_required"]
    assert {:ok, fitted} = Storage.get(@bucket, output["cues_key"], nil)
    assert [%{"text" => "Blue."}] = Jason.decode!(fitted)

    assert {:ok, rejected} =
             Storage.get(@bucket, "#{@embed}/audio_description/en/unfitted-cues.json", nil)

    assert [%{"reason" => "rewrite_model_output_truncated"}] = Jason.decode!(rejected)
  end

  test "speech retries reuse unchanged cues but regenerate changed text" do
    key = "#{@embed}/audio_description/en/cues.json"
    step = %{"id" => "speak_descriptions_en", "params" => %{"language" => "en"}}

    context = %{
      run_input: Map.put(base_input(), "audio_description", @requested),
      dependency_outputs: %{
        "describe_video" => %{
          "status" => "ok",
          "cues_key" => key,
          "speech_key" => "speech.json",
          "duration" => 8
        }
      }
    }

    put_cue = fn text ->
      Storage.put(
        @bucket,
        key,
        Jason.encode!([%{"start" => 0, "end" => 1, "text" => text}]),
        "application/json",
        nil
      )
    end

    put_cue.("A red screen.")
    assert {:ok, first, []} = AiSpeakDescriptionsStep.run(step, context)
    assert_received {:speak, "en"}
    assert {:ok, retry, []} = AiSpeakDescriptionsStep.run(step, context)
    assert retry["clips"] == first["clips"]
    refute_received {:speak, "en"}

    put_cue.("A blue screen.")
    assert {:ok, changed, []} = AiSpeakDescriptionsStep.run(step, context)
    assert_received {:speak, "en"}
    refute changed["clips"] == first["clips"]
  end

  test "visible instructions survive a wrong kind label while spoken captions are omitted" do
    document = %{
      "duration" => 20,
      "scenes" => [%{"start" => 0, "end" => 20}],
      "stills" => [%{"scene" => 0, "time" => 10, "key" => "still.jpg"}]
    }

    Storage.put(@bucket, "scenes.json", Jason.encode!(document), "application/json", nil)
    Storage.put(@bucket, "still.jpg", "image", "image/jpeg", nil)

    Storage.put(
      @bucket,
      "transcript.json",
      Jason.encode!(%{
        "segments" => [
          %{"start" => 0, "end" => 12, "text" => "My name is Alex."}
        ]
      }),
      "application/json",
      nil
    )

    Process.put(:ad_cues, [
      %{
        "start" => 2,
        "end" => 5,
        "shot" => 0,
        "text" => "My name is Alex.",
        "kind" => "text",
        "priority" => 3,
        "on_screen_text" => "My name is Alex."
      },
      %{
        "start" => 9,
        "end" => 20,
        "shot" => 0,
        "text" => "A card reads: Read the guide at example.org.",
        "kind" => "action",
        "priority" => 3,
        "on_screen_text" => "Read the guide at example.org."
      },
      %{
        "start" => 14,
        "end" => 15,
        "shot" => 0,
        "text" => "Close-up of the same speaker.",
        "priority" => 1
      }
    ])

    Process.put(:ad_keep, [0, 1])

    context = %{
      run_input: Map.put(base_input(), "audio_description", @requested),
      dependency_outputs: %{
        "detect_scenes" => %{"status" => "ok", "scenes_key" => "scenes.json"},
        "transcribe_audio" => %{"status" => "ok", "subtitle_json_key" => "transcript.json"}
      }
    }

    assert {:ok, output, []} = AiDescribeVideoStep.run(%{"id" => "describe_video"}, context)
    assert {:ok, json} = Storage.get(@bucket, output["cues_key"], nil)
    assert [instruction] = Jason.decode!(json)
    assert instruction["kind"] == "text"
    assert instruction["text"] == "A card reads: Read the guide at example.org."
    assert instruction["on_screen_text"] == "Read the guide at example.org."
    assert instruction["window"]["start"] >= 12

    # Literal text is not automatically essential: incidental labels keep their priority.
    Process.put(:ad_cues, [
      %{
        "start" => 14,
        "end" => 18,
        "shot" => 0,
        "text" => "23 matches",
        "on_screen_text" => "23 matches",
        "kind" => "text",
        "priority" => 1
      }
    ])

    Process.put(:ad_keep, [0])
    assert {:ok, label_output, []} = AiDescribeVideoStep.run(%{"id" => "describe_video"}, context)
    assert {:ok, label_json} = Storage.get(@bucket, label_output["cues_key"], nil)
    assert [%{"priority" => 1, "on_screen_text" => "23 matches"}] = Jason.decode!(label_json)

    Process.put(:ad_cues, [
      %{
        "start" => 1,
        "end" => 8,
        "shot" => 0,
        "text" => "An illustrated poster about Alex.",
        "on_screen_text" => "Alex",
        "kind" => "setting",
        "priority" => 2
      }
    ])

    Process.put(:ad_keep, [0])

    quiet_context =
      put_in(context, [:dependency_outputs, "transcribe_audio"], %{
        "status" => "ok",
        "subtitle_json_key" => "earlier-speech.json"
      })

    Storage.put(
      @bucket,
      "earlier-speech.json",
      Jason.encode!(%{"segments" => [%{"start" => 0, "end" => 0.1, "text" => "Alex"}]}),
      "application/json",
      nil
    )

    assert {:ok, poster_output, []} =
             AiDescribeVideoStep.run(%{"id" => "describe_video"}, quiet_context)

    assert {:ok, poster_json} = Storage.get(@bucket, poster_output["cues_key"], nil)

    assert [%{"text" => "An illustrated poster about Alex.", "on_screen_text" => ""}] =
             Jason.decode!(poster_json)
  end

  @tag :integration
  test "original-language preset describes and packages just the detected language" do
    Process.put(:ad_test_pid, self())
    {video, audio} = media_fixtures()

    input =
      Map.merge(base_input(), %{
        "audio_description" => %{"languages" => ["original"]},
        "source_body" => video,
        "source_content_type" => "video/mp4"
      })

    Storage.put_public(@bucket, "#{@embed}/audio.mp3", audio, "audio/mpeg", nil)

    Storage.put(
      @bucket,
      "#{@embed}/subtitle.json",
      Jason.encode!(%{"segments" => []}),
      "application/json",
      nil
    )

    outputs = %{
      "source" => %{"space_hash" => @space, "embed_hash" => @embed, "version" => 0},
      "inspect_media" => %{"duration" => 8.0, "has_video" => true, "has_audio" => true},
      "transcribe_audio" => %{
        "status" => "ok",
        "language" => "nl",
        "subtitle_json_key" => "#{@embed}/subtitle.json"
      },
      "transcode_audio" => %{
        "status" => "ok",
        "bucket" => @bucket,
        "key" => "#{@embed}/audio.mp3",
        "uri" => "s3://#{@bucket}/#{@embed}/audio.mp3"
      }
    }

    {:ok, preset} = Presets.fetch("publish_local")

    steps =
      Enum.filter(
        preset["definition"]["steps"],
        &(&1["id"] in ~w(detect_scenes describe_video speak_descriptions_original mix_audio_description_original))
      )

    outputs =
      Enum.reduce(steps, outputs, fn step, acc ->
        assert {:ok, %{"status" => "ok"} = output, _artifacts} =
                 Map.fetch!(
                   %{
                     "media.detect_scenes" => MediaDetectScenesStep,
                     "ai.describe_video" => AiDescribeVideoStep,
                     "ai.speak_descriptions" => AiSpeakDescriptionsStep,
                     "media.mix_audio_description" => MediaMixAudioDescriptionStep
                   },
                   step["type"]
                 ).run(step, %{run_input: input, dependency_outputs: acc})

        Map.put(acc, step["id"], output)
      end)

    assert outputs["describe_video"]["language"] == "nl"
    assert outputs["speak_descriptions_original"]["language"] == "nl"
    assert outputs["mix_audio_description_original"]["audio_description"]["language"] == "nl"
    assert_received {:chat, overview_instruction, overview_content}
    assert Enum.count(overview_content, &(&1["type"] == "image_url")) >= 4
    assert overview_instruction =~ "Dutch (nl)"
    assert_received {:chat, instruction, content}
    refute Enum.any?(content, &(&1["type"] == "image_url"))
    assert instruction =~ "Dutch (nl)"
    request = Jason.decode!(List.last(content)["text"])
    assert request["language"] == "nl"
    assert length(request["observations"]) >= 4
    assert {:ok, _} = Storage.get(@bucket, outputs["describe_video"]["observations_key"], nil)
    assert_received {:speak, "nl"}
    refute_received {:speak, "en"}
    assert {:ok, _} = Storage.get(@bucket, "#{@embed}/audio_description_nl.mp3", nil)
    assert {:error, _} = Storage.get(@bucket, "#{@embed}/audio_description_en.mp3", nil)
  end

  @tag :integration
  test "fits descriptions to real speech pauses and packages a full mix per language" do
    if System.find_executable("ffmpeg") == nil, do: flunk("ffmpeg is required")
    Process.put(:ad_test_pid, self())

    {video, audio} = media_fixtures()
    input = Map.put(base_input(), "audio_description", @requested)
    Storage.put_public(@bucket, "#{@embed}/audio.mp3", audio, "audio/mpeg", nil)

    transcript = %{
      "segments" => [%{"start" => 1.5, "end" => 3.0}, %{"start" => 4.5, "end" => 7.5}]
    }

    Storage.put_public(
      @bucket,
      "#{@embed}/subtitle.json",
      Jason.encode!(transcript),
      "application/json",
      nil
    )

    base_outputs = %{
      "source" => %{"space_hash" => @space, "embed_hash" => @embed, "version" => 0},
      "inspect_media" => %{"duration" => 8.0, "has_video" => true, "has_audio" => true},
      "transcribe_audio" => %{"status" => "ok", "subtitle_json_key" => "#{@embed}/subtitle.json"},
      "transcode_audio" => %{
        "status" => "ok",
        "bucket" => @bucket,
        "key" => "#{@embed}/audio.mp3",
        "uri" => "s3://#{@bucket}/#{@embed}/audio.mp3"
      }
    }

    # 1. Scenes and stills from the video itself.
    assert {:ok, scenes, []} =
             MediaDetectScenesStep.run(%{"id" => "detect_scenes"}, %{
               run_input:
                 Map.merge(input, %{"source_body" => video, "source_content_type" => "video/mp4"}),
               dependency_outputs: base_outputs
             })

    assert %{"status" => "ok", "scene_count" => 2, "cut_count" => 1} = scenes
    assert scenes["still_count"] >= 4

    # 2. English cues, pinned to their scenes around the measured speech.
    outputs = Map.put(base_outputs, "detect_scenes", scenes)

    assert {:ok, english, []} =
             AiDescribeVideoStep.run(%{"id" => "describe_video"}, %{
               run_input: input,
               dependency_outputs: outputs
             })

    assert %{"status" => "ok", "cue_count" => 1, "language" => "en", "unplaced_cue_count" => 1} =
             english

    assert_received {:chat, _overview, _images}
    assert_received {:chat, _system, [%{"text" => json}]}

    assert Jason.decode!(json)["protected_speech"] == [
             %{"start" => 1.35, "end" => 3.15},
             %{"start" => 4.35, "end" => 7.65}
           ]

    # 3. Dutch from the English cues.
    outputs = Map.put(outputs, "describe_video", english)

    assert {:ok, dutch, []} =
             AiTranslateDescriptionsStep.run(
               %{"id" => "translate_descriptions_nl", "params" => %{"language" => "nl"}},
               %{run_input: input, dependency_outputs: outputs}
             )

    assert %{"status" => "ok", "language" => "nl", "cue_count" => 1} = dutch

    # 4. Speech per language, then the mix.
    outputs = Map.put(outputs, "translate_descriptions_nl", dutch)

    for {language, cues_step} <- [{"en", "describe_video"}, {"nl", "translate_descriptions_nl"}] do
      assert {:ok, speech, []} =
               AiSpeakDescriptionsStep.run(
                 %{
                   "id" => "speak_descriptions_#{language}",
                   "params" => %{"language" => language, "source_step_id" => cues_step}
                 },
                 %{run_input: input, dependency_outputs: outputs}
               )

      assert %{"status" => "ok", "clips" => [_], "adjusted_cue_count" => 1} = speech

      assert {:ok, mix, [mp3_artifact, vtt_artifact]} =
               MediaMixAudioDescriptionStep.run(
                 %{
                   "id" => "mix_audio_description_#{language}",
                   "params" => %{"language" => language}
                 },
                 %{
                   run_input: input,
                   dependency_outputs: Map.put(outputs, "speak_descriptions_#{language}", speech)
                 }
               )

      assert %{"status" => "ok", "cue_count" => 1, "ducked_cue_count" => 0} = mix
      assert mix["audio_track"]["characteristics"] == "public.accessibility.describes-video"

      assert mix["audio_track"]["hls_playlist"] ==
               "audio_description_#{language}_hls/playlist.m3u8"

      assert mp3_artifact.uri == "s3://#{@bucket}/#{@embed}/audio_description_#{language}.mp3"
      assert vtt_artifact.uri == "s3://#{@bucket}/#{@embed}/descriptions_#{language}.vtt"

      {:ok, mp3} = Storage.get(@bucket, "#{@embed}/audio_description_#{language}.mp3", nil)
      assert Storage.public?(@bucket, "#{@embed}/audio_description_#{language}.mp3", nil)
      assert duration(mp3) > 7.5

      {:ok, vtt} = Storage.get(@bucket, "#{@embed}/descriptions_#{language}.vtt", nil)
      assert vtt =~ "WEBVTT\nKind: descriptions\nLanguage: #{language}\n"
      assert vtt =~ "Red."

      assert {:ok, _} =
               Storage.get(
                 @bucket,
                 "#{@embed}/audio_description_#{language}_hls/playlist.m3u8",
                 nil
               )
    end

    # A retry reuses the clips it already spoke.
    assert_received {:speak, "en"}

    {:ok, _, []} =
      AiSpeakDescriptionsStep.run(
        %{"id" => "speak_descriptions_en", "params" => %{"language" => "en"}},
        %{run_input: input, dependency_outputs: outputs}
      )

    flush_speak()
    refute_received {:speak, _}
  end

  defp flush_speak do
    receive do
      {:speak, _} -> flush_speak()
    after
      0 -> :ok
    end
  end

  @tag :integration
  test "essential descriptions with no pause survive storage and use ducking in the final mix" do
    {_video, audio} = media_fixtures()
    input = Map.put(base_input(), "audio_description", %{"languages" => ["original"]})
    audio_key = "#{@embed}/audio.mp3"
    cues_key = "#{@embed}/audio_description/en/cues.json"
    speech_key = "#{@embed}/audio_description/speech.json"
    Storage.put_public(@bucket, audio_key, audio, "audio/mpeg", nil)

    Storage.put(
      @bucket,
      cues_key,
      Jason.encode!([
        %{
          "start" => 1.0,
          "end" => 3.0,
          "text" => "Call 112.",
          "priority" => 3,
          "on_screen_text" => "112",
          "window" => nil,
          "duck_window" => %{"start" => 1.0, "end" => 3.0}
        }
      ]),
      "application/json",
      nil
    )

    Storage.put(
      @bucket,
      speech_key,
      Jason.encode!([%{"start" => 0.0, "end" => 8.0}]),
      "application/json",
      nil
    )

    outputs = %{
      "source" => %{"space_hash" => @space, "embed_hash" => @embed, "version" => 0},
      "transcode_audio" => %{"status" => "ok", "key" => audio_key},
      "describe_video" => %{
        "status" => "ok",
        "cues_key" => cues_key,
        "speech_key" => speech_key,
        "duration" => 8.0
      }
    }

    assert {:ok, speech, []} =
             AiSpeakDescriptionsStep.run(
               %{
                 "id" => "speak_descriptions_original",
                 "params" => %{"language" => "original", "source_step_id" => "describe_video"}
               },
               %{run_input: input, dependency_outputs: outputs}
             )

    assert {:ok, mix, _} =
             MediaMixAudioDescriptionStep.run(
               %{
                 "id" => "mix_audio_description_original",
                 "params" => %{
                   "language" => "original",
                   "source_step_id" => "speak_descriptions_original"
                 }
               },
               %{
                 run_input: input,
                 dependency_outputs: Map.put(outputs, "speak_descriptions_original", speech)
               }
             )

    assert mix["cue_count"] == 1
    assert mix["ducked_cue_count"] == 1
    assert mix["speech_overlap_seconds"] > 0
    assert mix["ending_room_seconds"] >= 0.3
  end

  # An 8 s video that cuts from red to blue at 4 s, with a tone, and its audio as MP3.
  defp media_fixtures do
    dir = Path.join(System.tmp_dir!(), "ad-fixture-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    video = Path.join(dir, "video.mp4")
    audio = Path.join(dir, "audio.mp3")

    {_, 0} =
      System.cmd("ffmpeg", [
        "-v",
        "error",
        "-y",
        "-f",
        "lavfi",
        "-i",
        "color=c=red:s=320x240:d=4:r=25",
        "-f",
        "lavfi",
        "-i",
        "color=c=blue:s=320x240:d=4:r=25",
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=330:duration=8",
        "-filter_complex",
        "[0:v][1:v]concat=n=2:v=1:a=0[v]",
        "-map",
        "[v]",
        "-map",
        "2:a",
        "-c:v",
        "libx264",
        "-pix_fmt",
        "yuv420p",
        "-c:a",
        "aac",
        video
      ])

    {_, 0} =
      System.cmd("ffmpeg", ["-v", "error", "-y", "-i", video, "-vn", "-c:a", "libmp3lame", audio])

    {File.read!(video), File.read!(audio)}
  end

  defp duration(mp3) do
    path = Path.join(System.tmp_dir!(), "ad-check-#{System.unique_integer([:positive])}.mp3")
    File.write!(path, mp3)

    {out, 0} =
      System.cmd("ffprobe", [
        "-v",
        "error",
        "-show_entries",
        "format=duration",
        "-of",
        "csv=p=0",
        path
      ])

    File.rm(path)
    out |> String.trim() |> String.to_float()
  end

  defp base_input do
    %{"space_hash" => @space, "embed_hash" => @embed, "version" => 0, "region" => nil}
  end

  defp restore(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore(key, value), do: Application.put_env(:mave_core, key, value)
end
