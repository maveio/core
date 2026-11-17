defmodule MaveCore.Flow.PipelineTest do
  use ExUnit.Case, async: true

  alias MaveCore.Flow.{Definition, Pipeline, Presets}

  defp publish_default do
    {:ok, preset} = Presets.fetch("publish_default")
    preset["definition"]
  end

  defp step_ids(definition), do: Enum.map(Definition.steps(definition), & &1["id"])
  defp step(definition, id), do: Definition.step_by_id(definition, id)

  test "empty overrides leave the definition unchanged" do
    definition = publish_default()

    assert {:ok, ^definition} = Pipeline.apply(definition, Pipeline.empty())

    assert Pipeline.empty?(%{
             "disabled_steps" => [],
             "settings" => %{"transcribe_audio" => %{"context" => " "}}
           })
  end

  test "turning off 4K removes its packaging and clips but keeps the flow valid" do
    definition = publish_default()

    assert {:ok, effective} =
             Pipeline.apply(definition, %{"disabled_steps" => ["video_h264_uhd"]})

    assert :ok = Definition.validate(effective)

    ids = step_ids(effective)

    for removed <- ~w(video_h264_uhd hls_h264_uhd clip_hevc_uhd clip_av1_uhd hls_master_high) do
      refute removed in ids
    end

    for kept <- ~w(video_h264_qhd hls_h264_qhd hls_master_qhd manifest notify_webhook) do
      assert kept in ids
    end

    assert length(ids) == length(step_ids(definition)) - 5
  end

  test "reports which steps follow a step that is turned off" do
    definition = publish_default()

    assert Pipeline.also_disabled(definition, Pipeline.empty(), "video_h264_uhd") ==
             ~w(clip_av1_uhd clip_hevc_uhd hls_h264_uhd hls_master_high)

    resolution = Pipeline.resolve(definition, %{"disabled_steps" => ["video_h264_uhd"]})
    states = Map.new(resolution.steps, &{&1.id, &1})

    assert states["video_h264_uhd"].state == :disabled
    assert states["hls_h264_uhd"].state == :auto_disabled
    assert states["hls_h264_uhd"].disabled_by == ["video_h264_uhd"]
    assert states["video_h264_qhd"].state == :enabled
  end

  test "a later master playlist refresh takes over the chain of one that is turned off" do
    definition = publish_default()

    assert {:ok, effective} =
             Pipeline.apply(definition, %{"disabled_steps" => ["video_h264_qhd"]})

    refute "hls_master_qhd" in step_ids(effective)

    assert step(effective, "hls_master_high")["depends_on"] ==
             ["hls_master_metadata", "hls_h264_uhd"]
  end

  test "steps that work with whatever is left keep running without a disabled dependency" do
    definition = publish_default()

    assert {:ok, effective} =
             Pipeline.apply(definition, %{"disabled_steps" => ["transcribe_audio"]})

    ids = step_ids(effective)
    refute "transcribe_audio" in ids
    refute "translate_subtitles" in ids
    refute "describe_video" in ids

    assert "manifest" in ids
    refute "transcribe_audio" in step(effective, "manifest")["depends_on"]
    assert step(effective, "hls_master_metadata")["depends_on"] == ["hls_master", "inspect_media"]
  end

  test "required steps cannot be turned off" do
    assert {:error, [%{code: :required_step, step_id: "video_h264_sd"}]} =
             Pipeline.apply(publish_default(), %{"disabled_steps" => ["video_h264_sd"]})
  end

  test "rejects a change that would starve a required step" do
    definition = %{
      "steps" => [
        %{"id" => "source", "type" => "source.resolve", "name" => "Resolve Source"},
        %{
          "id" => "inspect",
          "type" => "media.inspect",
          "name" => "Inspect",
          "depends_on" => ["source"],
          "required" => false
        },
        %{
          "id" => "audio",
          "type" => "media.transcode_audio",
          "name" => "Audio",
          "depends_on" => ["inspect"]
        }
      ]
    }

    assert {:error, [%{code: :required_step_blocked, step_id: "audio"}]} =
             Pipeline.apply(definition, %{"disabled_steps" => ["inspect"]})
  end

  test "ignores steps the definition does not have" do
    {:ok, local} = Presets.fetch("publish_local")

    assert {:ok, effective} =
             Pipeline.apply(local["definition"], %{"disabled_steps" => ["video_h264_uhd"]})

    assert effective == local["definition"]
  end

  test "applies editable settings as step params" do
    overrides = %{
      "settings" => %{
        "transcribe_audio" => %{"context" => "  Mave, Hovercraft  "},
        "storyboard" => %{"count" => "24"}
      }
    }

    assert {:ok, effective} = Pipeline.apply(publish_default(), overrides)

    assert step(effective, "transcribe_audio")["params"] == %{"context" => "Mave, Hovercraft"}
    assert step(effective, "storyboard")["params"]["count"] == 24
    assert step(effective, "storyboard")["params"]["strict"] == true
  end

  test "rejects settings a step type does not mark as editable or that are out of range" do
    assert {:error, [%{code: :invalid_setting, step_id: "transcribe_audio"}]} =
             Pipeline.apply(publish_default(), %{
               "settings" => %{"transcribe_audio" => %{"strict" => true}}
             })

    assert {:error, [%{code: :invalid_setting, step_id: "storyboard", message: message}]} =
             Pipeline.apply(publish_default(), %{
               "settings" => %{"storyboard" => %{"count" => 500}}
             })

    assert message =~ "at most 120"
  end

  test "describes editable settings with their base and changed values" do
    resolution =
      Pipeline.resolve(publish_default(), %{"settings" => %{"storyboard" => %{"count" => 24}}})

    storyboard = Enum.find(resolution.steps, &(&1.id == "storyboard"))
    assert [%{key: "count", base: 60, value: 24, changed: true}] = storyboard.settings

    transcribe = Enum.find(resolution.steps, &(&1.id == "transcribe_audio"))
    assert [%{key: "context", base: nil, changed: false}] = transcribe.settings

    assert Pipeline.summary(publish_default(), resolution.overrides) ==
             %{steps_off: 0, steps_added: 0, settings_changed: 1}
  end

  test "normalizes overrides into a stable shape" do
    assert Pipeline.normalize(%{
             disabled_steps: ["b", "a", "b", ""],
             added_steps: ["y", "y"],
             settings: %{"s" => %{"k" => "v", "blank" => ""}, "empty" => %{}},
             other: true
           }) == %{
             "disabled_steps" => ["a", "b"],
             "added_steps" => ["y"],
             "settings" => %{"s" => %{"k" => "v"}}
           }

    overrides = Pipeline.put_step_enabled(Pipeline.empty(), "x", false)
    assert overrides["disabled_steps"] == ["x"]
    assert Pipeline.put_step_enabled(overrides, "x", true) == Pipeline.empty()
    assert Pipeline.put_setting(Pipeline.empty(), "s", "k", nil) == Pipeline.empty()
  end

  describe "add-on steps from step plugins" do
    test "are offered but stay out of the flow until they are added" do
      resolution = Pipeline.resolve(publish_default(), Pipeline.empty())
      addon = Enum.find(resolution.steps, &(&1.id == "vmaf_h264_fhd"))

      assert %{addon: true, state: :disabled, locked: false, available: true} = addon
      assert addon.type == "quality.vmaf"
      assert addon.dependencies == ["video_h264_fhd"]
      assert resolution.issues == []
      assert resolution.definition == publish_default()
      refute Enum.any?(resolution.steps, &(&1.addon and &1.state == :enabled))
    end

    test "adding one appends an optional background step with its settings" do
      overrides =
        Pipeline.empty()
        |> Pipeline.put_step_added("vmaf_h264_fhd", true)
        |> Pipeline.put_setting("vmaf_h264_fhd", "threshold", "90")

      assert {:ok, definition} = Pipeline.apply(publish_default(), overrides)

      assert %{
               "type" => "quality.vmaf",
               "depends_on" => ["video_h264_fhd"],
               "required" => false,
               "lane" => "background",
               "params" => %{"size" => "fhd", "threshold" => 90}
             } = step(definition, "vmaf_h264_fhd")

      refute step(definition, "vmaf_h264_hd")
      refute match?({:error, _message}, Definition.validate(definition))

      assert Pipeline.summary(publish_default(), overrides) ==
               %{steps_off: 0, steps_added: 1, settings_changed: 1}

      assert Pipeline.put_step_added(overrides, "vmaf_h264_fhd", false)["added_steps"] == []
    end

    test "an added step follows the step it checks when that is turned off" do
      overrides =
        Pipeline.empty()
        |> Pipeline.put_step_added("vmaf_h264_uhd", true)
        |> Pipeline.put_step_enabled("video_h264_uhd", false)

      resolution = Pipeline.resolve(publish_default(), overrides)
      addon = Enum.find(resolution.steps, &(&1.id == "vmaf_h264_uhd"))

      assert addon.state == :auto_disabled
      assert addon.disabled_by == ["video_h264_uhd"]
      refute step(resolution.definition, "vmaf_h264_uhd")

      assert "vmaf_h264_uhd" in Pipeline.also_disabled(
               publish_default(),
               Pipeline.put_step_added(Pipeline.empty(), "vmaf_h264_uhd", true),
               "video_h264_uhd"
             )
    end

    test "adding a step type that is unavailable is an issue" do
      overrides = Pipeline.put_step_added(Pipeline.empty(), "vmaf_h264_fhd", true)
      unavailable = %{"quality.vmaf" => "Not included in this plan."}

      assert {:error, [%{code: :step_unavailable, step_id: "vmaf_h264_fhd"} = issue]} =
               Pipeline.apply(publish_default(), overrides, unavailable: unavailable)

      assert issue.message =~ "Not included in this plan."

      resolution = Pipeline.resolve(publish_default(), Pipeline.empty(), unavailable: unavailable)
      addon = Enum.find(resolution.steps, &(&1.id == "vmaf_h264_fhd"))
      assert %{available: false, unavailable_reason: "Not included in this plan."} = addon
      assert resolution.issues == []
    end

    test "add-on ids cannot be used to turn anything off or add unknown steps" do
      overrides = %{"disabled_steps" => ["vmaf_h264_fhd"], "added_steps" => ["missing"]}
      assert {:ok, definition} = Pipeline.apply(publish_default(), overrides)
      assert definition == publish_default()
    end
  end
end
