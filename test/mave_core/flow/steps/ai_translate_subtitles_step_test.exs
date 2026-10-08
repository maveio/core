defmodule MaveCore.Flow.Steps.AiTranslateSubtitlesStepTest do
  use ExUnit.Case, async: false

  alias MaveCore.Flow.Steps.AiTranslateSubtitlesStep
  alias MaveCore.TestSupport.FlowStorageAdapterStub

  setup do
    old_storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter)
    old_translation_provider = Application.get_env(:mave_core, :subtitle_translation_provider)

    Application.put_env(:mave_core, :flow_storage_adapter, FlowStorageAdapterStub)
    Application.put_env(:mave_core, :subtitle_translation_provider, __MODULE__.TranslatorStub)

    FlowStorageAdapterStub.reset!()

    on_exit(fn ->
      restore_env(:flow_storage_adapter, old_storage_adapter)
      restore_env(:subtitle_translation_provider, old_translation_provider)
      FlowStorageAdapterStub.reset!()
    end)

    :ok
  end

  test "translates a source subtitle JSON into English subtitle artifacts" do
    bucket = "space-ubg50"

    assert {:ok, _body} =
             FlowStorageAdapterStub.put_public(
               bucket,
               "LeDE9v86ye/subtitle_nl.json",
               Jason.encode!(%{
                 "text" => "Hallo wereld. Nog een zin.",
                 "segments" => [
                   %{"id" => 1, "start" => 0.0, "end" => 1.5, "text" => "Hallo wereld"},
                   %{"id" => 2, "start" => 1.5, "end" => 3.0, "text" => "Nog een zin"}
                 ]
               }),
               "application/json",
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
        "transcribe_audio" => %{
          "status" => "ok",
          "step_type" => "ai.transcribe_audio",
          "language" => "nl",
          "subtitle_json_key" => "LeDE9v86ye/subtitle_nl.json"
        }
      }
    }

    assert {:ok, output, artifacts} =
             AiTranslateSubtitlesStep.run(
               %{"id" => "translate_subtitles", "type" => "ai.translate_subtitles"},
               context
             )

    assert_receive {:translate_called, transcription, opts}
    assert transcription.text == "Hallo wereld. Nog een zin."
    assert length(transcription.segments) == 2
    assert opts[:source_language] == "nl"
    assert opts[:target_language] == "en"

    assert output["status"] == "ok"
    assert output["step_type"] == "ai.translate_subtitles"
    assert output["source_language"] == "nl"
    assert output["language"] == "en"
    assert output["subtitle_key"] == "LeDE9v86ye/subtitle_en.vtt"
    assert output["subtitle_uri"] == "s3://space-ubg50/LeDE9v86ye/subtitle_en.vtt"
    assert output["subtitle_json_key"] == "LeDE9v86ye/subtitle_en.json"
    assert output["subtitle_default_json_key"] == nil
    assert output["subtitle"]["label"] == "English"

    assert [
             %{name: "subtitle_en", uri: "s3://space-ubg50/LeDE9v86ye/subtitle_en.vtt"},
             %{name: "subtitle_en_json", uri: "s3://space-ubg50/LeDE9v86ye/subtitle_en.json"}
           ] = artifacts

    assert {:ok, vtt} = FlowStorageAdapterStub.get(bucket, "LeDE9v86ye/subtitle_en.vtt", nil)
    assert vtt =~ "WEBVTT"
    assert vtt =~ "00:00:00.000 --> 00:00:01.500"
    assert vtt =~ "Hello world"

    assert {:ok, json} = FlowStorageAdapterStub.get(bucket, "LeDE9v86ye/subtitle_en.json", nil)

    assert %{"text" => "Hello world. Another sentence.", "segments" => [first | _]} =
             Jason.decode!(json)

    assert first["text"] == "Hello world"
    assert is_list(first["words"])
  end

  test "skips translation when the transcription is already English" do
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
        "transcribe_audio" => %{
          "status" => "ok",
          "step_type" => "ai.transcribe_audio",
          "language" => "en"
        }
      }
    }

    assert {:ok, output, []} =
             AiTranslateSubtitlesStep.run(
               %{"id" => "translate_subtitles", "type" => "ai.translate_subtitles"},
               context
             )

    assert output["status"] == "skipped"
    assert output["reason"] == "source language already matches target"
    refute_received {:translate_called, _transcription, _opts}
  end

  test "accepts subtitle JSON already decoded by the storage client" do
    Application.put_env(:mave_core, :flow_storage_adapter, __MODULE__.DecodedJsonStorageAdapter)

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
        "transcribe_audio" => %{
          "status" => "ok",
          "step_type" => "ai.transcribe_audio",
          "language" => "nl",
          "subtitle_json_key" => "LeDE9v86ye/subtitle_nl.json"
        }
      }
    }

    assert {:ok, output, _artifacts} =
             AiTranslateSubtitlesStep.run(
               %{"id" => "translate_subtitles", "type" => "ai.translate_subtitles"},
               context
             )

    assert output["status"] == "ok"
    assert output["subtitle_key"] == "LeDE9v86ye/subtitle_en.vtt"
  end

  test "returns unavailable output in non-strict mode when transcription is missing" do
    context = %{
      run_input: %{"space_hash" => "ubg50", "embed_hash" => "LeDE9v86ye"},
      dependency_outputs: %{
        "source" => %{"space_hash" => "ubg50", "embed_hash" => "LeDE9v86ye", "version" => 0}
      }
    }

    assert {:ok, output, []} =
             AiTranslateSubtitlesStep.run(
               %{"id" => "translate_subtitles", "type" => "ai.translate_subtitles"},
               context
             )

    assert output["status"] == "unavailable"
    assert output["step_type"] == "ai.translate_subtitles"
    assert output["error"] =~ "missing_transcription_output"
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)

  defmodule TranslatorStub do
    def translate(transcription, opts) do
      send(self(), {:translate_called, transcription, opts})

      {:ok,
       %{
         text: "Hello world. Another sentence.",
         language: "en",
         segments: [
           %{start: 0.0, end: 1.5, text: "Hello world"},
           %{start: 1.5, end: 3.0, text: "Another sentence."}
         ]
       }}
    end
  end

  defmodule DecodedJsonStorageAdapter do
    alias MaveCore.TestSupport.FlowStorageAdapterStub

    def get("space-ubg50", "LeDE9v86ye/subtitle_nl.json", nil) do
      {:ok,
       %{
         "text" => "Hallo wereld. Nog een zin.",
         "segments" => [
           %{"id" => 1, "start" => 0.0, "end" => 1.5, "text" => "Hallo wereld"},
           %{"id" => 2, "start" => 1.5, "end" => 3.0, "text" => "Nog een zin"}
         ]
       }}
    end

    def get(bucket, key, region), do: FlowStorageAdapterStub.get(bucket, key, region)

    def put_public(bucket, key, body, content_type, region) do
      FlowStorageAdapterStub.put_public(bucket, key, body, content_type, region)
    end
  end
end
