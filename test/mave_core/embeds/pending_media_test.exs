defmodule MaveCore.Embeds.PendingMediaTest do
  use ExUnit.Case, async: true
  alias MaveCore.Embeds.PendingMedia
  alias MaveCore.Flow.{Run, StepRun}

  defp run do
    %Run{
      status: "running",
      input: %{
        "version" => 1,
        "language" => "nl",
        "audio_description" => %{"languages" => ["original"]}
      },
      flow_version: %{
        definition: %{"steps" => [%{"id" => "translate", "params" => %{"language" => "en"}}]}
      },
      step_runs: [
        %StepRun{
          id: "audio",
          step_id: "audio",
          step_type: "media.transcode_audio",
          status: "executing"
        },
        %StepRun{
          id: "ad",
          step_id: "ad",
          step_type: "media.mix_audio_description",
          status: "queued"
        },
        %StepRun{
          id: "sub",
          step_id: "sub",
          step_type: "ai.transcribe_audio",
          status: "scheduled"
        },
        %StepRun{
          id: "translate",
          step_id: "translate",
          step_type: "ai.translate_subtitles",
          status: "queued"
        }
      ]
    }
  end

  test "shows only actual pending work and resolves language from the run" do
    pending = PendingMedia.for_run(run(), 1, %{})
    assert [%{label: "Dutch (original)", state: :processing}] = pending.audio_tracks
    assert [%{label: "Dutch (AD)", state: :queued}] = pending.audio_descriptions
    assert Enum.map(pending.subtitles, & &1.language) == ["nl", "en"]
  end

  test "does not show AD when the run did not request it" do
    run = run()

    assert PendingMedia.for_run(
             %{run | input: Map.delete(run.input, "audio_description")},
             1,
             %{}
           ).audio_descriptions == []
  end

  test "stale, finished, skipped and audio-only runs do not leave placeholders" do
    assert PendingMedia.for_run(run(), 2, %{}) == %{
             audio_tracks: [],
             audio_descriptions: [],
             subtitles: []
           }

    assert PendingMedia.for_run(%{run() | status: "succeeded"}, 1, %{}).audio_descriptions == []
    run = run()

    inspect_step = %StepRun{
      step_id: "inspect_media",
      step_type: "media.inspect",
      status: "succeeded",
      output: %{"has_video" => false}
    }

    assert PendingMedia.for_run(%{run | step_runs: [inspect_step | run.step_runs]}, 1, %{}).audio_descriptions ==
             []

    skipped = %StepRun{
      step_type: "ai.describe_video",
      status: "succeeded",
      output: %{"status" => "skipped"}
    }

    assert PendingMedia.for_run(%{run | step_runs: [skipped | run.step_runs]}, 1, %{}).audio_descriptions ==
             []
  end

  test "a queued translation blocked by a failed transcription is not shown as generating" do
    run = run()

    steps =
      Enum.map(run.step_runs, fn step ->
        if step.step_id == "sub", do: %{step | status: "failed"}, else: step
      end)

    run = %{
      run
      | step_runs: steps,
        flow_version: %{
          definition: %{
            "steps" => [
              %{"id" => "translate", "depends_on" => ["sub"], "params" => %{"language" => "en"}}
            ]
          }
        }
    }

    assert PendingMedia.for_run(run, 1, %{}).subtitles == []
  end

  test "materialized files are not duplicated as pending rows" do
    pending =
      PendingMedia.for_run(run(), 1, %{
        audio_tracks: [%{language: "nl"}],
        subtitles: [%{language: "en"}],
        audio_descriptions: [%{language: "nl"}]
      })

    assert pending.audio_tracks == []
    assert pending.audio_descriptions == []
    assert [%{language: "nl"}] = pending.subtitles
  end

  test "original audio hides the source language while transcription is pending" do
    {run, track} = language_detection_fixture()

    assert [%{label: "Original", language: nil, language_pending: true}] =
             PendingMedia.audio_tracks_for_run([track], run, 1)

    assert PendingMedia.audio_tracks_for_run([track], run, 2) == [track]
    assert PendingMedia.audio_tracks_for_run([track], %{run | status: "succeeded"}, 1) == [track]

    for status <- ["succeeded", "failed", "skipped", "cancelled"] do
      [audio, transcription] = run.step_runs
      run = %{run | step_runs: [audio, %{transcription | status: status}]}
      assert PendingMedia.audio_tracks_for_run([track], run, 1) == [track]
    end
  end

  test "explicit languages, alternate tracks and edited labels keep their language" do
    {run, track} = language_detection_fixture()

    for preserved <- [
          %{track | default: false},
          %{track | label: "Commentary"},
          %{track | language: "fr"}
        ] do
      assert PendingMedia.audio_tracks_for_run([preserved], run, 1) == [preserved]
    end

    [audio, transcription] = run.step_runs
    audio = %{audio | input: %{"params" => %{"language" => "en"}}}
    run = %{run | step_runs: [audio, transcription]}
    assert PendingMedia.audio_tracks_for_run([track], run, 1) == [track]
  end

  defp language_detection_fixture do
    track = %{
      id: "track",
      filename: "audio.mp3",
      label: "English (original)",
      language: "en",
      default: true
    }

    audio = %StepRun{
      step_type: "media.transcode_audio",
      status: "succeeded",
      output: %{
        "audio_tracks" => [
          %{
            "filename" => "audio.mp3",
            "label" => "Original",
            "language" => "en",
            "default" => true
          }
        ]
      }
    }

    transcription = %StepRun{step_type: "ai.transcribe_audio", status: "executing"}
    {%{run() | step_runs: [audio, transcription]}, track}
  end
end
