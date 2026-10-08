defmodule MaveCore.Flow.Steps.AssetUploadOriginalStepTest do
  use ExUnit.Case, async: false

  alias MaveCore.Flow.Steps.AssetUploadOriginalStep
  alias MaveCore.TestSupport.FlowStorageAdapterStub

  test "original publication strips active content types in inline, remote and storage modes" do
    Req.default_options(plug: {Req.Test, __MODULE__})

    Application.put_env(:mave_core, :public_http_url_resolver, fn _ ->
      {:ok, [{93, 184, 216, 34}]}
    end)

    body = <<0, 0, 0, 24, "ftyp", "isom", 0::128>> <> "<script>not executable</script>"

    for type <- ["text/html", "Image/SVG+XML; charset=utf-8", "application/xhtml+xml"],
        mode <- [:inline, :remote, :storage] do
      FlowStorageAdapterStub.reset!()

      input = %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "source_content_type" => type,
        "region" => "local"
      }

      input =
        case mode do
          :inline ->
            Map.put(input, "source_body", body)

          :remote ->
            Req.Test.expect(__MODULE__, fn conn ->
              conn
              |> Plug.Conn.put_resp_header("content-type", type)
              |> Plug.Conn.send_resp(200, body)
            end)

            Map.put(input, "input_url", "https://media.example/source.mp4")

          :storage ->
            {:ok, _} = FlowStorageAdapterStub.put("source", "input.mp4", body, type, "local")

            Map.merge(input, %{
              "source_bucket" => "source",
              "source_key" => "input.mp4",
              "source_region" => "local"
            })
        end

      assert {:ok, _, _} = AssetUploadOriginalStep.run(%{}, %{run_input: input})

      assert {:ok, %{content_type: "application/octet-stream"}} =
               FlowStorageAdapterStub.object_info("space-ubg50", "LeDE9v86ye/original", "local")

      assert {:ok, ^body} =
               FlowStorageAdapterStub.get("space-ubg50", "LeDE9v86ye/original", "local")

      assert FlowStorageAdapterStub.public?("space-ubg50", "LeDE9v86ye/original", "local")

      assert {:ok, %{content_type: "text/html"}} =
               FlowStorageAdapterStub.object_info(
                 "space-ubg50",
                 "LeDE9v86ye/player.html",
                 "local"
               )
    end
  end

  setup {Req.Test, :verify_on_exit!}

  setup do
    old_storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter)
    old_resolver = Application.get_env(:mave_core, :public_http_url_resolver)
    old_req_defaults = Req.default_options()

    Application.put_env(
      :mave_core,
      :flow_storage_adapter,
      FlowStorageAdapterStub
    )

    FlowStorageAdapterStub.reset!()

    on_exit(fn ->
      FlowStorageAdapterStub.reset!()
      restore_env(:flow_storage_adapter, old_storage_adapter)
      restore_env(:public_http_url_resolver, old_resolver)
      Req.default_options(old_req_defaults)
    end)

    :ok
  end

  test "accepts list content-type values from source headers" do
    step_definition = %{"id" => "upload_original", "type" => "asset.upload_original"}

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "source_body" => "stub-media-body",
        "source_content_type" => ["video/mp4; charset=utf-8"]
      },
      dependency_outputs: %{
        "source" => %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "source_url" => "https://example.com/video.mp4",
          "version" => 0
        },
        "ensure_bucket" => %{"bucket" => "space-ubg50"}
      }
    }

    assert {:ok, output, artifacts} = AssetUploadOriginalStep.run(step_definition, context)
    assert output["content_type"] == "video/mp4"

    assert Enum.any?(artifacts, fn artifact ->
             artifact.name == "original" and artifact.media_type == "video/mp4"
           end)

    assert FlowStorageAdapterStub.public?(
             "space-ubg50",
             "LeDE9v86ye/original",
             nil
           ) == true
  end

  test "accepts charlist content-type values from source headers" do
    step_definition = %{"id" => "upload_original", "type" => "asset.upload_original"}

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "source_body" => "stub-media-body",
        "source_content_type" => ~c"video/mp4"
      },
      dependency_outputs: %{
        "source" => %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "source_url" => "https://example.com/video.mp4",
          "version" => 0
        },
        "ensure_bucket" => %{"bucket" => "space-ubg50"}
      }
    }

    assert {:ok, output, _artifacts} = AssetUploadOriginalStep.run(step_definition, context)
    assert output["content_type"] == "video/mp4"
  end

  test "uploads a player shell with a transparent document background" do
    step_definition = %{"id" => "upload_original", "type" => "asset.upload_original"}

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "source_body" => "stub-media-body",
        "source_content_type" => "video/mp4"
      },
      dependency_outputs: %{
        "source" => %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "source_url" => "https://example.com/video.mp4",
          "version" => 0
        },
        "ensure_bucket" => %{"bucket" => "space-ubg50"}
      }
    }

    assert {:ok, _output, _artifacts} =
             AssetUploadOriginalStep.run(step_definition, context)

    assert {:ok, player_html} =
             FlowStorageAdapterStub.get("space-ubg50", "LeDE9v86ye/player.html", nil)

    assert player_html =~ ~s(<html lang="en" style="background: transparent;">)
    assert player_html =~ ~s(<body style="background: transparent;)
    refute player_html =~ "background: black"
  end

  test "loads source bytes from configured storage reference" do
    assert {:ok, _body} =
             FlowStorageAdapterStub.put(
               "mave-upload",
               "uploads/demo.mp4",
               "stub-from-storage",
               "video/mp4",
               "us-east-1"
             )

    step_definition = %{"id" => "upload_original", "type" => "asset.upload_original"}

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "source_bucket" => "mave-upload",
        "source_key" => "uploads/demo.mp4",
        "region" => "us-east-1",
        "source_region" => "us-east-1",
        "source_content_type" => "video/mp4"
      },
      dependency_outputs: %{
        "source" => %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "source_bucket" => "mave-upload",
          "source_key" => "uploads/demo.mp4",
          "source_region" => "us-east-1",
          "source_content_type" => "video/mp4",
          "version" => 0
        },
        "ensure_bucket" => %{"bucket" => "space-ubg50"}
      }
    }

    assert {:ok, output, artifacts} = AssetUploadOriginalStep.run(step_definition, context)
    assert output["content_type"] == "video/mp4"
    assert output["bytes"] == byte_size("stub-from-storage")

    assert Enum.any?(artifacts, fn artifact ->
             artifact.name == "original" and artifact.media_type == "video/mp4"
           end)

    assert FlowStorageAdapterStub.public?(
             "space-ubg50",
             "LeDE9v86ye/original",
             "us-east-1"
           ) == true
  end

  test "copies storage sources between profiles without temp file fallback" do
    assert {:ok, _body} =
             FlowStorageAdapterStub.put(
               "mave-upload",
               "uploads/large-demo.mp4",
               "stub-from-upload-profile",
               "video/mp4",
               "fr-par"
             )

    step_definition = %{"id" => "upload_original", "type" => "asset.upload_original"}

    context = %{
      run_input: %{
        "space_hash" => "ccmhz",
        "embed_hash" => "NRH03s0Zi0",
        "source_bucket" => "mave-upload",
        "source_key" => "uploads/large-demo.mp4",
        "region" => "eu",
        "source_region" => "fr-par",
        "source_content_type" => "video/mp4"
      },
      dependency_outputs: %{
        "source" => %{
          "space_hash" => "ccmhz",
          "embed_hash" => "NRH03s0Zi0",
          "source_bucket" => "mave-upload",
          "source_key" => "uploads/large-demo.mp4",
          "source_region" => "fr-par",
          "source_content_type" => "video/mp4",
          "version" => 0
        },
        "ensure_bucket" => %{"bucket" => "space-ccmhz"}
      }
    }

    assert {:ok, output, _artifacts} = AssetUploadOriginalStep.run(step_definition, context)

    assert output["bytes"] == byte_size("stub-from-upload-profile")
    assert output["content_type"] == "video/mp4"

    assert FlowStorageAdapterStub.copy_between_profiles_called?(
             "space-ccmhz",
             "NRH03s0Zi0/original",
             "eu"
           )

    assert FlowStorageAdapterStub.public?(
             "space-ccmhz",
             "NRH03s0Zi0/original",
             "eu"
           ) == true
  end

  test "rejects remote source urls that point at internal addresses" do
    step_definition = %{"id" => "upload_original", "type" => "asset.upload_original"}

    context = %{
      run_input: %{
        "space_hash" => "ubg50",
        "embed_hash" => "LeDE9v86ye",
        "source_content_type" => "video/mp4"
      },
      dependency_outputs: %{
        "source" => %{
          "space_hash" => "ubg50",
          "embed_hash" => "LeDE9v86ye",
          "source_url" => "http://169.254.42.42/conf",
          "version" => 0
        },
        "ensure_bucket" => %{"bucket" => "space-ubg50"}
      }
    }

    assert {:error, {:unsafe_source_url, {:blocked_address, {169, 254, 42, 42}}}} =
             AssetUploadOriginalStep.run(step_definition, context)

    assert FlowStorageAdapterStub.get("space-ubg50", "LeDE9v86ye/original", nil) ==
             {:error, :not_found}
  end

  test "downloads durable remote sources through Core instead of the encoding booster" do
    Application.put_env(:mave_core, :public_http_url_resolver, fn _host ->
      {:ok, [{93, 184, 216, 34}]}
    end)

    Req.default_options(plug: {Req.Test, __MODULE__})

    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("video/mp4")
      |> Req.Test.text("remote-media")
    end)

    context = %{
      encoding_booster_dispatch: :direct,
      run_input: %{
        "space_hash" => "qingb",
        "embed_hash" => "remote1234",
        "input_url" => "https://source.example/large.mp4",
        "source_content_type" => "video/mp4",
        "durable_source_required" => true
      },
      dependency_outputs: %{
        "source" => %{
          "space_hash" => "qingb",
          "embed_hash" => "remote1234",
          "source_url" => "https://source.example/large.mp4",
          "version" => 0
        },
        "ensure_bucket" => %{"bucket" => "space-qingb"}
      }
    }

    assert {:ok, output, _artifacts} =
             AssetUploadOriginalStep.run(
               %{"id" => "upload_original", "type" => "asset.upload_original"},
               context
             )

    assert output["content_type"] == "video/mp4"
    assert output["bytes"] == byte_size("remote-media")

    assert {:ok, "remote-media"} =
             FlowStorageAdapterStub.get("space-qingb", "remote1234/original", nil)
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)
end
