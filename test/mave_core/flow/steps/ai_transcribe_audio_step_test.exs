defmodule MaveCore.Flow.Steps.AiTranscribeAudioStepTest do
  use ExUnit.Case, async: false

  alias MaveCore.Flow.Steps.AiTranscribeAudioStep
  alias MaveCore.TestSupport.FlowStorageAdapterStub

  setup do
    old_storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter)
    old_transcription_provider = Application.get_env(:mave_core, :transcription_provider)

    Application.put_env(
      :mave_core,
      :flow_storage_adapter,
      FlowStorageAdapterStub
    )

    Application.put_env(
      :mave_core,
      :transcription_provider,
      __MODULE__.TranscriptionProviderStub
    )

    FlowStorageAdapterStub.reset!()

    on_exit(fn ->
      restore_env(:flow_storage_adapter, old_storage_adapter)
      restore_env(:transcription_provider, old_transcription_provider)
    end)

    :ok
  end

  test "produces subtitle artifact from transcription text" do
    step_definition = %{
      "id" => "transcribe_audio",
      "type" => "ai.transcribe_audio"
    }

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "transcription_text" => "Hello world",
        "transcription_language" => "en",
        "version" => 0
      },
      dependency_outputs: %{
        "source" => %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "version" => 0
        }
      }
    }

    assert {:ok, output, artifacts} = AiTranscribeAudioStep.run(step_definition, context)
    assert output["status"] == "ok"
    assert output["step_type"] == "ai.transcribe_audio"
    assert output["mode"] == "input_text"
    assert output["language"] == "en"
    assert output["subtitle_key"] == "LeDE9v86ye/subtitle_en.vtt"
    assert output["subtitle_uri"] == "s3://space-ubg50/LeDE9v86ye/subtitle_en.vtt"
    assert output["subtitle"]["language"] == "en"
    assert output["subtitle"]["label"] == "English"
    assert output["subtitle"]["src"] == "s3://space-ubg50/LeDE9v86ye/subtitle_en.vtt"
    assert is_list(output["subtitles"])
    assert hd(output["subtitles"])["path"] == "s3://space-ubg50/LeDE9v86ye/subtitle_en.vtt"
    assert output["subtitle_json_key"] == nil
    assert output["subtitle_default_json_key"] == nil

    assert [%{name: "subtitle_en", uri: uri, media_type: "text/vtt"}] = artifacts
    assert uri == "s3://space-ubg50/LeDE9v86ye/subtitle_en.vtt"
  end

  test "returns unavailable output in non-strict mode when transcription input is missing" do
    step_definition = %{
      "id" => "transcribe_audio",
      "type" => "ai.transcribe_audio"
    }

    context = %{
      run_input: %{"space_hash" => "ubg50", "embed_hash" => "LeDE9v86ye"},
      dependency_outputs: %{
        "source" => %{"space_hash" => "ubg50", "embed_hash" => "LeDE9v86ye", "version" => 0}
      }
    }

    assert {:ok, output, []} = AiTranscribeAudioStep.run(step_definition, context)
    assert output["status"] == "unavailable"
    assert output["step_type"] == "ai.transcribe_audio"
  end

  test "transcribes the default audio track through the provider when input text is missing" do
    step_definition = %{
      "id" => "transcribe_audio",
      "type" => "ai.transcribe_audio"
    }

    bucket = "space-ubg50"
    audio_key = "LeDE9v86ye/audio.mp3"

    assert {:ok, _body} =
             FlowStorageAdapterStub.put(
               bucket,
               audio_key,
               "mp3-binary",
               "audio/mpeg",
               nil
             )

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "version" => 0
      },
      dependency_outputs: %{
        "source" => %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "version" => 0
        },
        "inspect_media" => %{"duration" => 8.0},
        "transcode_audio" => %{
          "key" => audio_key,
          "uri" => "s3://#{bucket}/#{audio_key}",
          "audio_tracks" => [
            %{"default" => true, "language" => "nl"}
          ]
        }
      }
    }

    assert {:ok, output, artifacts} = AiTranscribeAudioStep.run(step_definition, context)
    assert output["status"] == "ok"
    assert output["mode"] == "mistral"
    assert output["language"] == "nl"
    assert output["subtitle"]["label"] == "Dutch"
    assert output["transcription_segments_count"] == 2
    assert output["subtitle_key"] == "LeDE9v86ye/subtitle_nl.vtt"
    assert output["subtitle_uri"] == "s3://space-ubg50/LeDE9v86ye/subtitle_nl.vtt"
    assert output["subtitle_json_key"] == "LeDE9v86ye/subtitle_nl.json"
    assert output["subtitle_default_json_key"] == "LeDE9v86ye/subtitle.json"

    assert [
             %{name: "subtitle_nl", uri: "s3://space-ubg50/LeDE9v86ye/subtitle_nl.vtt"},
             %{name: "subtitle_nl_json", uri: "s3://space-ubg50/LeDE9v86ye/subtitle_nl.json"},
             %{name: "subtitle_json", uri: "s3://space-ubg50/LeDE9v86ye/subtitle.json"}
           ] =
             artifacts

    assert {:ok, subtitle_body} =
             FlowStorageAdapterStub.get(
               bucket,
               "LeDE9v86ye/subtitle_nl.vtt",
               nil
             )

    assert subtitle_body =~ "WEBVTT"
    assert subtitle_body =~ "00:00:00.000 --> 00:00:01.500"
    assert subtitle_body =~ "Hallo wereld"

    assert {:ok, subtitle_json} =
             FlowStorageAdapterStub.get(
               bucket,
               "LeDE9v86ye/subtitle.json",
               nil
             )

    assert %{"text" => "Hallo wereld. Nog een zin.", "segments" => [first | _]} =
             Jason.decode!(subtitle_json)

    assert first["text"] == "Hallo wereld"
    assert is_list(first["words"])
  end

  test "prefers the public audio URL when the provider supports URL transcription" do
    original_public_cdn_host = Application.get_env(:mave_core, :public_cdn_host)
    original_public_cdn_scheme = Application.get_env(:mave_core, :public_cdn_scheme)
    original_public_cdn_mode = Application.get_env(:mave_core, :public_cdn_mode)

    Application.put_env(
      :mave_core,
      :transcription_provider,
      __MODULE__.UrlTranscriptionProviderStub
    )

    Application.put_env(:mave_core, :public_cdn_host, "video-dns.com")
    Application.put_env(:mave_core, :public_cdn_scheme, "https")
    Application.delete_env(:mave_core, :public_cdn_mode)

    on_exit(fn ->
      restore_env(:public_cdn_host, original_public_cdn_host)
      restore_env(:public_cdn_scheme, original_public_cdn_scheme)
      restore_env(:public_cdn_mode, original_public_cdn_mode)
    end)

    step_definition = %{
      "id" => "transcribe_audio",
      "type" => "ai.transcribe_audio"
    }

    bucket = "space-ubg50"
    audio_key = "LeDE9v86ye/audio.mp3"

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "version" => 0
      },
      dependency_outputs: %{
        "source" => %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "version" => 0
        },
        "inspect_media" => %{"duration" => 8.0},
        "transcode_audio" => %{
          "key" => audio_key,
          "uri" => "s3://#{bucket}/#{audio_key}"
        }
      }
    }

    assert {:ok, output, _artifacts} = AiTranscribeAudioStep.run(step_definition, context)

    assert_receive {:transcribe_url_called,
                    "https://space-ubg50.video-dns.com/LeDE9v86ye/audio.mp3", opts}

    assert opts[:filename] == "audio.mp3"
    assert opts[:content_type] == "audio/mpeg"
    assert output["status"] == "ok"
    assert output["transcription_input"] == "url"
    assert output["subtitle_key"] == "LeDE9v86ye/subtitle_en.vtt"
  end

  test "falls back to the default audio track language when provider omits language" do
    step_definition = %{
      "id" => "transcribe_audio",
      "type" => "ai.transcribe_audio"
    }

    bucket = "space-ubg50"
    audio_key = "LeDE9v86ye/audio.mp3"

    assert {:ok, _body} =
             FlowStorageAdapterStub.put(
               bucket,
               audio_key,
               "mp3-binary-no-language",
               "audio/mpeg",
               nil
             )

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "version" => 0
      },
      dependency_outputs: %{
        "source" => %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "version" => 0
        },
        "inspect_media" => %{"duration" => 8.0},
        "transcode_audio" => %{
          "key" => audio_key,
          "uri" => "s3://#{bucket}/#{audio_key}",
          "audio_tracks" => [
            %{"default" => true, "language" => "nl"}
          ]
        }
      }
    }

    assert {:ok, output, _artifacts} = AiTranscribeAudioStep.run(step_definition, context)
    assert output["status"] == "ok"
    assert output["language"] == "nl"
    assert output["subtitle"]["label"] == "Dutch"
    assert output["transcription_language"] == "nl"
  end

  test "keeps the language unknown when provider and short text are inconclusive" do
    step_definition = %{
      "id" => "transcribe_audio",
      "type" => "ai.transcribe_audio"
    }

    bucket = "space-ubg50"
    audio_key = "LeDE9v86ye/audio.mp3"

    assert {:ok, _body} =
             FlowStorageAdapterStub.put(
               bucket,
               audio_key,
               "mp3-binary-unknown-language",
               "audio/mpeg",
               nil
             )

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "version" => 0
      },
      dependency_outputs: %{
        "source" => %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "version" => 0
        },
        "inspect_media" => %{"duration" => 8.0},
        "transcode_audio" => %{
          "key" => audio_key,
          "uri" => "s3://#{bucket}/#{audio_key}"
        }
      }
    }

    assert {:ok, output, _artifacts} = AiTranscribeAudioStep.run(step_definition, context)
    assert output["status"] == "ok"
    assert output["language"] == "und"
    assert output["subtitle"]["label"] == "Unknown language"
    assert output["transcription_language"] == "und"
    assert output["subtitle_key"] == "LeDE9v86ye/subtitle_und.vtt"
  end

  test "uses transcript language detection when provider language is unknown" do
    Process.put(:language_detection_result, {:ok, "en"})

    step_definition = %{
      "id" => "transcribe_audio",
      "type" => "ai.transcribe_audio"
    }

    bucket = "space-ubg50"
    audio_key = "LeDE9v86ye/audio.mp3"

    assert {:ok, _body} =
             FlowStorageAdapterStub.put(
               bucket,
               audio_key,
               "mp3-binary-unknown-language-english-text",
               "audio/mpeg",
               nil
             )

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "version" => 0
      },
      dependency_outputs: %{
        "source" => %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "version" => 0
        },
        "inspect_media" => %{"duration" => 8.0},
        "transcode_audio" => %{
          "key" => audio_key,
          "uri" => "s3://#{bucket}/#{audio_key}"
        }
      }
    }

    assert {:ok, output, _artifacts} = AiTranscribeAudioStep.run(step_definition, context)
    assert output["status"] == "ok"
    assert output["language"] == "en"
    assert output["subtitle"]["label"] == "English"
    assert output["transcription_language"] == "en"
    assert output["subtitle_key"] == "LeDE9v86ye/subtitle_en.vtt"
  end

  test "detects Italian from the transcript when the provider omits its language" do
    Process.put(:language_detection_result, {:ok, "it"})
    context = language_context(nil, italian_text())

    assert {:ok, output, _artifacts} =
             AiTranscribeAudioStep.run(%{"id" => "transcribe_audio"}, context)

    assert output["language"] == "it"
    assert output["subtitle"]["label"] == "Italian"
    assert output["transcription_language_source"] == "text_detection"
    assert output["transcription_language_detection_attempted"]
    assert_received {:language_detection_called, _}
    assert output["transcription_provider_language"] == nil
  end

  test "uses the provider language before audio tags or text detection" do
    context = language_context("ita", "la de un", audio_language: "es")

    assert {:ok, output, _artifacts} =
             AiTranscribeAudioStep.run(%{"id" => "transcribe_audio"}, context)

    assert output["language"] == "it"
    assert output["transcription_language_source"] == "provider"
    refute output["transcription_language_detection_attempted"]
    refute_received {:language_detection_called, _}
    assert output["transcription_provider_language"] == "it"
  end

  test "an explicit language setting takes precedence over the provider" do
    context = language_context("es", italian_text(), requested_language: "it")

    assert {:ok, output, _artifacts} =
             AiTranscribeAudioStep.run(%{"id" => "transcribe_audio"}, context)

    assert output["language"] == "it"
    assert output["transcription_language_source"] == "requested"
    refute output["transcription_language_detection_attempted"]
    refute_received {:language_detection_called, _}
    assert output["transcription_provider_language"] == "es"
  end

  test "failed language detection does not discard a successful transcription" do
    Process.put(:language_detection_result, {:error, :timeout})
    context = language_context(nil, italian_text())

    assert {:ok, output, _artifacts} =
             AiTranscribeAudioStep.run(%{"id" => "transcribe_audio"}, context)

    assert output["status"] == "ok"
    assert output["language"] == "und"
    assert output["transcription_language_detection_attempted"]
    assert_received {:language_detection_called, _}
    refute_received {:language_detection_called, _}
  end

  test "ambiguous text uses audio metadata or remains unknown" do
    for {audio_language, expected, source} <- [
          {"it", "it", "audio_track"},
          {nil, "und", "unknown"}
        ] do
      context = language_context(nil, "ciao", audio_language: audio_language)

      assert {:ok, output, _artifacts} =
               AiTranscribeAudioStep.run(%{"id" => "transcribe_audio"}, context)

      assert output["language"] == expected
      assert output["transcription_language_source"] == source
    end
  end

  test "returns error in strict mode when transcription input is missing" do
    step_definition = %{
      "id" => "transcribe_audio",
      "type" => "ai.transcribe_audio"
    }

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "ai_transcribe_audio_strict" => true
      },
      dependency_outputs: %{
        "source" => %{"space_hash" => "ubg50", "embed_hash" => "LeDE9v86ye", "version" => 0}
      }
    }

    assert {:error, {:ai_transcribe_audio_failed, :missing_transcription_input}} =
             AiTranscribeAudioStep.run(step_definition, context)
  end

  test "generated long segments use matching readable VTT and JSON cues" do
    text = String.duplicate("A readable sentence with several words. ", 6) |> String.trim()
    context = language_context("en", text)

    Process.put(:language_test_response, %{
      text: text,
      language: "en",
      segments: [%{start: 0.0, end: 18.0, text: text}]
    })

    assert {:ok, output, _} = AiTranscribeAudioStep.run(%{}, context)
    assert {:ok, vtt} = FlowStorageAdapterStub.get("space-abcde", output["subtitle_key"], nil)

    assert {:ok, json} =
             FlowStorageAdapterStub.get("space-abcde", output["subtitle_json_key"], nil)

    segments = Jason.decode!(json)["segments"]
    assert length(segments) > 1
    assert Enum.map_join(segments, " ", & &1["text"]) |> String.replace("\n", " ") == text

    for segment <- segments do
      assert vtt =~ "\n#{segment["text"]}\n\n"
      assert length(String.split(segment["text"], "\n")) <= 2
    end
  end

  test "provider word timings survive grouping and JSON serialization" do
    text = "Hello there. After a pause."

    words = [
      %{word: "Hello", start: 0.125, end: 0.4},
      %{word: "there.", start: 0.5, end: 1.1},
      %{word: "After", start: 2.7, end: 3.0},
      %{word: "a", start: 3.05, end: 3.1},
      %{word: "pause.", start: 3.15, end: 4.2}
    ]

    context = language_context("en", text)

    Process.put(:language_test_response, %{
      text: text,
      language: "en",
      words: words,
      segments: [%{start: 0.0, end: 8.0, text: text}]
    })

    assert {:ok, output, _} = AiTranscribeAudioStep.run(%{}, context)

    assert {:ok, json} =
             FlowStorageAdapterStub.get("space-abcde", output["subtitle_json_key"], nil)

    assert {:ok, vtt} = FlowStorageAdapterStub.get("space-abcde", output["subtitle_key"], nil)
    segments = Jason.decode!(json)["segments"]

    assert Enum.flat_map(segments, & &1["words"]) ==
             Enum.map(words, fn word ->
               %{"word" => word.word, "start" => word.start, "end" => word.end}
             end)

    assert vtt =~ "00:00:00.125 --> 00:00:01.100"
    assert vtt =~ "00:00:02.700 --> 00:00:04.200"
  end

  test "supplied VTT is preserved verbatim" do
    vtt = "WEBVTT\n\n00:00:00.000 --> 00:00:10.000\nFirst\nSecond\nThird\n"

    context = %{
      run_input: %{
        "space_hash" => "abcde",
        "embed_hash" => "SubtitleTest",
        "transcription_language" => "en",
        "transcription_vtt" => vtt
      }
    }

    assert {:ok, output, _} = AiTranscribeAudioStep.run(%{}, context)
    assert {:ok, ^vtt} = FlowStorageAdapterStub.get("space-abcde", output["subtitle_key"], nil)
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)

  defp italian_text do
    "La nostra azienda si occupa di offrire un servizio di qualità per tutte le persone che desiderano imparare qualcosa di nuovo."
  end

  defp language_context(provider_language, text, opts \\ []) do
    Application.put_env(:mave_core, :transcription_provider, __MODULE__.LanguageProviderStub)
    Process.put(:language_test_response, %{text: text, language: provider_language, segments: []})
    key = "LanguageTest/audio.mp3"

    {:ok, _} =
      FlowStorageAdapterStub.put("space-abcde", key, "language-test-audio", "audio/mpeg", nil)

    %{
      run_input: %{
        "space_hash" => "abcde",
        "embed_hash" => "LanguageTest",
        "transcription_language" => Keyword.get(opts, :requested_language)
      },
      dependency_outputs: %{
        "inspect_media" => %{"duration" => 8.0},
        "transcode_audio" => %{
          "key" => key,
          "audio_tracks" => [
            %{"default" => true, "language" => Keyword.get(opts, :audio_language)}
          ]
        }
      }
    }
  end

  defmodule LanguageProviderStub do
    def transcribe("language-test-audio", _opts), do: {:ok, Process.get(:language_test_response)}
  end

  defmodule TranscriptionProviderStub do
    def transcribe("mp3-binary", opts) do
      send(self(), {:transcribe_called, opts})

      {:ok,
       %{
         text: "Hallo wereld. Nog een zin.",
         language: "nl",
         segments: [
           %{start: 0.0, end: 1.5, text: "Hallo wereld"},
           %{start: 1.5, end: 3.0, text: "Nog een zin"}
         ]
       }}
    end

    def transcribe("mp3-binary-no-language", _opts) do
      {:ok,
       %{
         text: "Hallo wereld zonder provider taal.",
         language: nil,
         segments: [
           %{start: 0.0, end: 1.5, text: "Hallo wereld zonder provider taal."}
         ]
       }}
    end

    def transcribe("mp3-binary-unknown-language", _opts) do
      {:ok,
       %{
         text: "Hallo wereld met onbekende taalcode.",
         language: "un",
         segments: [
           %{start: 0.0, end: 1.5, text: "Hallo wereld met onbekende taalcode."}
         ]
       }}
    end

    def transcribe("mp3-binary-unknown-language-english-text", _opts) do
      {:ok,
       %{
         text: "The world is bright and this video is about our team.",
         language: "un",
         segments: [
           %{start: 0.0, end: 1.5, text: "The world is bright and this video is about our team."}
         ]
       }}
    end
  end

  defmodule UrlTranscriptionProviderStub do
    def transcribe_url(url, opts) do
      send(self(), {:transcribe_url_called, url, opts})

      {:ok,
       %{
         text: "Hello from URL transcription.",
         language: "en",
         segments: [
           %{start: 0.0, end: 1.5, text: "Hello from URL transcription."}
         ]
       }}
    end
  end
end
