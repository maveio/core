defmodule MaveCore.AudioDescription.BackendTest do
  use ExUnit.Case, async: false
  alias MaveCore.Flow.Steps.{AiDescribeVideoStep, AudioDescriptionSupport}

  defmodule HostBackend do
    def describe(_, _, _) do
      send(self(), :host_described)

      {:ok,
       %{
         observations_key: nil,
         observations_reused: false,
         metadata: %{"analysis_provider" => "host"},
         script: %{
           "category" => "story",
           "summary" => "A door opens.",
           "essential_text" => [],
           "alignment_report" => %{"repaired_count" => 0, "rejected" => []},
           "cues" => [
             %{
               "start" => "00:00:01.000",
               "end" => "00:00:04.000",
               "text" => "A door opens.",
               "priority" => 2,
               "kind" => "action",
               "visual_window" => %{"start" => 1.0, "end" => 4.0}
             }
           ]
         }
       }}
    end

    def writer_provider(_), do: __MODULE__
  end

  defmodule Storage do
    def get(_, "scenes.json", _) do
      {:ok, %{"duration" => 5.0, "scenes" => [%{"start" => 0, "end" => 5}]}}
    end

    def get(_, "transcript.json", _), do: {:ok, %{"segments" => []}}
    def get(_, key, _), do: raise("Unexpected image/cache read: #{key}")

    def put(_, key, body, _, _) do
      send(self(), {:stored, key, Jason.decode!(body)})
      {:ok, %{}}
    end
  end

  setup do
    config = Application.get_env(:mave_core, :audio_description, [])
    storage = Application.get_env(:mave_core, :flow_storage_adapter)

    Application.put_env(
      :mave_core,
      :audio_description,
      Keyword.put(config, :backend, HostBackend)
    )

    Application.put_env(:mave_core, :flow_storage_adapter, Storage)

    on_exit(fn ->
      Application.put_env(:mave_core, :audio_description, config)

      if storage,
        do: Application.put_env(:mave_core, :flow_storage_adapter, storage),
        else: Application.delete_env(:mave_core, :flow_storage_adapter)
    end)

    :ok
  end

  test "host video scripts use the shared scheduler without invoking the image pipeline" do
    context = %{
      run_input: %{
        "space_hash" => "abcde",
        "embed_hash" => "example",
        "region" => "eu_3",
        "audio_description" => %{"languages" => ["original"]}
      },
      dependency_outputs: %{
        "detect_scenes" => %{"status" => "ok", "scenes_key" => "scenes.json"},
        "transcribe_audio" => %{
          "status" => "ok",
          "subtitle_json_key" => "transcript.json",
          "language" => "en"
        }
      }
    }

    assert {:ok, result, []} = AiDescribeVideoStep.run(%{"id" => "describe_video"}, context)
    assert result["analysis_provider"] == "host"
    assert result["cue_count"] == 1
    assert_received :host_described
    assert AudioDescriptionSupport.writer_provider(%{run_input: context.run_input}) == HostBackend
  end
end
