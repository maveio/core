defmodule MaveCore.Flow.Steps.CdnPurgeStepTest do
  use ExUnit.Case, async: false

  alias MaveCore.Flow.Steps.CdnPurgeStep

  setup do
    original_purger = Application.get_env(:mave_core, :cdn_cache_purger)

    on_exit(fn ->
      if original_purger do
        Application.put_env(:mave_core, :cdn_cache_purger, original_purger)
      else
        Application.delete_env(:mave_core, :cdn_cache_purger)
      end
    end)

    :ok
  end

  test "skips when endpoint is missing in non-strict mode" do
    step_definition = %{
      "id" => "purge_cdn",
      "type" => "cdn.purge"
    }

    context = %{
      run_input: %{},
      dependency_outputs: %{
        "manifest" => %{"manifest_key" => "LeDE9v86ye/manifest.json"}
      },
      dependency_artifacts: %{}
    }

    assert {:ok, output, []} = CdnPurgeStep.run(step_definition, context)
    assert output["status"] == "skipped"
    assert output["step_type"] == "cdn.purge"
    assert output["reason"] == "missing endpoint"
  end

  test "returns error when endpoint is missing in strict mode" do
    step_definition = %{
      "id" => "purge_cdn",
      "type" => "cdn.purge"
    }

    context = %{
      run_input: %{"cdn_purge_strict" => true},
      dependency_outputs: %{
        "manifest" => %{"manifest_key" => "LeDE9v86ye/manifest.json"}
      },
      dependency_artifacts: %{}
    }

    assert {:error, {:cdn_purge_failed, :missing_endpoint}} =
             CdnPurgeStep.run(step_definition, context)
  end

  test "returns unavailable in non-strict mode on purge failure" do
    step_definition = %{
      "id" => "purge_cdn",
      "type" => "cdn.purge"
    }

    context = %{
      run_input: %{
        "cdn_purge_endpoint" => "http://127.0.0.1:1/purge"
      },
      dependency_outputs: %{
        "manifest" => %{"manifest_key" => "LeDE9v86ye/manifest.json"}
      },
      dependency_artifacts: %{}
    }

    assert {:ok, output, []} = CdnPurgeStep.run(step_definition, context)
    assert output["status"] == "unavailable"
    assert output["step_type"] == "cdn.purge"
    assert output["paths"] == ["LeDE9v86ye/manifest.json"]
    assert is_binary(output["error"])
    assert output["error"] =~ "unsafe_cdn_purge_endpoint"
  end

  test "returns error in strict mode on unsafe purge endpoint" do
    step_definition = %{
      "id" => "purge_cdn",
      "type" => "cdn.purge"
    }

    context = %{
      run_input: %{
        "cdn_purge_endpoint" => "http://169.254.42.42/purge",
        "cdn_purge_strict" => true
      },
      dependency_outputs: %{
        "manifest" => %{"manifest_key" => "LeDE9v86ye/manifest.json"}
      },
      dependency_artifacts: %{}
    }

    assert {:error,
            {:cdn_purge_failed,
             {:unsafe_cdn_purge_endpoint, {:blocked_address, {169, 254, 42, 42}}}}} =
             CdnPurgeStep.run(step_definition, context)
  end

  test "uses configured purger with space context and manifest paths" do
    test_pid = self()

    Application.put_env(:mave_core, :cdn_cache_purger, fn space_hash, region, paths ->
      send(test_pid, {:purged, space_hash, region, paths})
      :ok
    end)

    step_definition = %{
      "id" => "purge_cdn",
      "type" => "cdn.purge"
    }

    context = %{
      run_input: %{"region" => "eu_2"},
      dependency_outputs: %{
        "manifest" => %{"manifest_key" => "LeDE9v86ye/manifest.json"}
      },
      dependency_artifacts: %{
        "manifest" => [
          %{
            "name" => "manifest",
            "metadata" => %{"space_hash" => "ubg50", "embed_hash" => "LeDE9v86ye"}
          }
        ]
      }
    }

    assert {:ok, output, []} = CdnPurgeStep.run(step_definition, context)
    assert output["status"] == "ok"
    assert output["backend"] == "configured_purger"
    assert output["space_hash"] == "ubg50"
    assert output["region"] == "eu_2"
    assert output["paths"] == ["LeDE9v86ye/manifest.json"]

    assert_receive {:purged, "ubg50", "eu_2", ["LeDE9v86ye/manifest.json"]}
  end
end
