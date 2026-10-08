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

  test "falls back to english when provider returns an unknown language code" do
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
    assert output["language"] == "nl"
    assert output["subtitle"]["label"] == "Dutch"
    assert output["transcription_language"] == "nl"
    assert output["subtitle_key"] == "LeDE9v86ye/subtitle_nl.vtt"
  end

  test "falls back to english when language is unknown and transcript text does not detect another language" do
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

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)

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
