defmodule MaveCore.Flow.Plugins.VmafQualityCheckTest do
  use ExUnit.Case, async: true

  alias MaveCore.Flow.Plugins.VmafQualityCheck, as: Vmaf
  alias MaveCore.Flow.{Presets, StepPlugin, StepRegistry}

  # Shape of the JSON log libvmaf 3 writes for `log_fmt=json`.
  @log Jason.encode!(%{
         "version" => "3.2.1",
         "fps" => 41.2,
         "frames" => [
           %{"frameNum" => 0, "metrics" => %{"vmaf" => 91.204}},
           %{"frameNum" => 5, "metrics" => %{"vmaf" => 95.731}},
           %{"frameNum" => 10, "metrics" => %{"vmaf" => 93.112}}
         ],
         "pooled_metrics" => %{
           "vmaf" => %{
             "min" => 91.204,
             "max" => 95.731,
             "mean" => 93.349,
             "harmonic_mean" => 93.312
           }
         },
         "aggregate_metrics" => %{}
       })

  defp ladder_output(size) do
    variant = %{
      "status" => "ok",
      "step_id" => "video_h264_#{size}",
      "size" => size,
      "bucket" => "space-test",
      "key" => "embed/h264_#{size}.mp4",
      "uri" => "s3://space-test/embed/h264_#{size}.mp4"
    }

    %{"step_type" => "media.transcode_h264_ladder", "variant_outputs" => %{size => variant}}
  end

  test "is a valid step plugin that Core registers by default" do
    assert {:ok, contract} = StepPlugin.validate(Vmaf)
    assert contract.type == "quality.vmaf"
    assert contract.executor == :flame
    assert StepRegistry.handler_for("quality.vmaf") == Vmaf
    assert "quality" in StepRegistry.stages()

    assert ["threshold", "sample_every"] ==
             Enum.map(StepRegistry.editable_options("quality.vmaf"), & &1["key"])
  end

  test "offers one check per H.264 rendition of a flow" do
    {:ok, preset} = Presets.fetch("publish_default")
    placements = Vmaf.placements(preset["definition"])

    assert Enum.map(placements, & &1["id"]) ==
             ~w(vmaf_h264_sd vmaf_h264_hd vmaf_h264_fhd vmaf_h264_qhd vmaf_h264_uhd)

    assert %{
             "name" => "VMAF Quality Check FHD",
             "depends_on" => ["video_h264_fhd"],
             "params" => %{"size" => "fhd", "source_step_id" => "video_h264_fhd"}
           } = Enum.find(placements, &(&1["id"] == "vmaf_h264_fhd"))

    assert Vmaf.placements(%{"steps" => [%{"id" => "source", "type" => "source.resolve"}]}) == []
  end

  test "reads the pooled score from a libvmaf log" do
    assert {:ok, %{"mean" => 93.35, "min" => 91.2, "max" => 95.73, "frames" => 3} = vmaf} =
             Vmaf.parse_log(@log)

    assert vmaf["harmonic_mean"] == 93.31
    assert Vmaf.parse_log("{}") == {:error, :invalid_vmaf_log}
    assert Vmaf.parse_log("not json") == {:error, :invalid_vmaf_log}
  end

  test "shows the score, verdict and target as results" do
    output = %{
      "vmaf" => %{"mean" => 84.12, "min" => 72.9, "frames" => 60},
      "verdict" => "Meets target",
      "threshold" => 80
    }

    assert [
             %{label: "VMAF score", text: "84.1", primary: true},
             %{label: "Result", text: "Meets target"},
             %{label: "Lowest frame", text: "72.9"},
             %{label: "Target score", text: "80"},
             %{label: "Frames checked", text: "60"}
           ] = StepRegistry.results("quality.vmaf", output)
  end

  test "compares both videos at the same size with libvmaf" do
    args =
      Vmaf.ffmpeg_args("rendition.mp4", "original.mov", "/tmp/vmaf.json", %{
        width: 1920,
        height: 1080,
        sample_every: 5,
        max_duration: 300
      })

    assert ["-i", "rendition.mp4"] == args |> Enum.drop_while(&(&1 != "-i")) |> Enum.take(2)
    graph = Enum.at(args, Enum.find_index(args, &(&1 == "-lavfi")) + 1)
    assert graph =~ "[0:v]scale=1920:1080:flags=bicubic"
    assert graph =~ "[1:v]scale=1920:1080:flags=bicubic"
    assert graph =~ "libvmaf=log_fmt=json:log_path=/tmp/vmaf.json:n_subsample=5"
    assert Enum.take(args, -3) == ["-f", "null", "-"]
  end

  test "skips sources without video and renditions that were not created" do
    step = %{"id" => "vmaf_h264_uhd", "params" => %{"size" => "uhd"}}

    assert {:ok, %{"status" => "skipped", "reason" => "no video stream"}, []} =
             Vmaf.run(step, %{dependency_outputs: %{"inspect_media" => %{"has_video" => false}}})

    outputs = %{
      "inspect_media" => %{"has_video" => true, "width" => 1920, "height" => 1080},
      "video_h264_fhd" => ladder_output("fhd")
    }

    assert {:ok, %{"status" => "skipped", "reason" => "rendition was not created"}, []} =
             Vmaf.run(step, %{dependency_outputs: outputs})

    assert {:ok, %{"status" => "skipped", "reason" => "source dimensions unknown"}, []} =
             Vmaf.run(%{"params" => %{"size" => "fhd"}}, %{
               dependency_outputs: %{"video_h264_fhd" => ladder_output("fhd")}
             })
  end
end
