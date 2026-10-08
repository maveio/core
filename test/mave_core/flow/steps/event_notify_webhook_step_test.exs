defmodule MaveCore.Flow.Steps.EventNotifyWebhookStepTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias MaveCore.Flow.Steps.EventNotifyWebhookStep

  setup {Req.Test, :verify_on_exit!}

  setup do
    previous_options = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__}, retry: false)
    on_exit(fn -> Req.default_options(previous_options) end)
    :ok
  end

  @template_url "https://93.184.216.34/template"
  @override_url "https://93.184.216.34/uploader"

  test "template credentials stay with the template destination" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/template"
      assert get_req_header(conn, "authorization") == ["Bearer template-secret"]
      send_resp(conn, 204, "")
    end)

    assert {:ok, %{"status" => "ok", "response_status" => 204}, []} =
             EventNotifyWebhookStep.run(template(), %{run_input: %{}})
  end

  for url_key <- ["callback_url", "webhook_url", "notify_webhook_url"] do
    test "#{url_key} cannot inherit template credentials, even on the same origin" do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/uploader"
        assert get_req_header(conn, "authorization") == []
        send_resp(conn, 200, "ok")
      end)

      assert {:ok, %{"status" => "ok"}, []} =
               EventNotifyWebhookStep.run(template(), %{
                 run_input: %{unquote(url_key) => @override_url}
               })
    end
  end

  test "explicit run headers and callback alias precedence are retained" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/uploader"
      assert get_req_header(conn, "authorization") == ["Bearer run-secret"]
      send_resp(conn, 200, "ok")
    end)

    input = %{
      "callback_url" => @override_url,
      "webhook_url" => @template_url,
      "notify_webhook_url" => @template_url,
      "notify_webhook_headers" => %{"authorization" => "Bearer run-secret"}
    }

    assert {:ok, %{"status" => "ok"}, []} =
             EventNotifyWebhookStep.run(template(), %{run_input: input})
  end

  test "explicit run headers can also override headers at the template destination" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/template"
      assert get_req_header(conn, "authorization") == ["Bearer run-secret"]
      send_resp(conn, 200, "ok")
    end)

    assert {:ok, %{"status" => "ok"}, []} =
             EventNotifyWebhookStep.run(template(), %{
               run_input: %{"notify_webhook_headers" => [{"authorization", "Bearer run-secret"}]}
             })
  end

  test "an oversized successful response does not fail delivery" do
    Req.Test.expect(__MODULE__, fn conn ->
      conn = send_chunked(conn, 200)
      {:ok, conn} = chunk(conn, String.duplicate("a", 12_000))
      {:ok, conn} = chunk(conn, String.duplicate("b", 12_000))
      conn
    end)

    assert {:ok, %{"status" => "ok"}, []} =
             EventNotifyWebhookStep.run(template(), %{run_input: %{}})
  end

  test "an oversized failure response is bounded before becoming an error" do
    Req.Test.expect(__MODULE__, fn conn ->
      send_resp(conn, 500, String.duplicate("failure", 10_000))
    end)

    assert {:error, {:event_notify_webhook_failed, {:http_error, 500, body}}} =
             EventNotifyWebhookStep.run(template(), %{
               run_input: %{"notify_webhook_strict" => true}
             })

    assert byte_size(body) <= 16 * 1_024
    assert String.ends_with?(body, "[mave: response body truncated]")
  end

  test "compressed callback bodies are not expanded or JSON decoded" do
    compressed = :zlib.gzip(String.duplicate("a", 100_000))

    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> put_resp_header("content-encoding", "gzip")
      |> put_resp_header("content-type", "application/json")
      |> send_resp(400, compressed)
    end)

    assert {:error, {:event_notify_webhook_failed, {:http_error, 400, ^compressed}}} =
             EventNotifyWebhookStep.run(template(), %{
               run_input: %{"notify_webhook_strict" => true}
             })
  end

  test "small failure diagnostics and non-strict behavior are preserved" do
    Req.Test.expect(__MODULE__, fn conn -> send_resp(conn, 400, "invalid event") end)

    assert {:ok, %{"status" => "unavailable", "error" => error}, []} =
             EventNotifyWebhookStep.run(template(), %{run_input: %{}})

    assert error =~ "invalid event"
  end

  defp template do
    %{
      "id" => "notify_webhook",
      "params" => %{
        "url" => @template_url,
        "headers" => %{"authorization" => "Bearer template-secret"}
      }
    }
  end

  test "skips when callback URL is missing in non-strict mode" do
    step_definition = %{
      "id" => "notify_webhook",
      "type" => "event.notify_webhook"
    }

    context = %{
      run_input: %{},
      dependency_outputs: %{
        "manifest" => %{"manifest_key" => "LeDE9v86ye/manifest.json"}
      },
      dependency_artifacts: %{},
      flow_run_id: Ecto.UUID.generate()
    }

    assert {:ok, output, []} = EventNotifyWebhookStep.run(step_definition, context)
    assert output["status"] == "skipped"
    assert output["step_type"] == "event.notify_webhook"
    assert output["reason"] == "missing callback"
  end

  test "returns error when callback URL is missing in strict mode" do
    step_definition = %{
      "id" => "notify_webhook",
      "type" => "event.notify_webhook"
    }

    context = %{
      run_input: %{"notify_webhook_strict" => true},
      dependency_outputs: %{
        "manifest" => %{"manifest_key" => "LeDE9v86ye/manifest.json"}
      },
      dependency_artifacts: %{},
      flow_run_id: Ecto.UUID.generate()
    }

    assert {:error, {:event_notify_webhook_failed, :missing_callback_url}} =
             EventNotifyWebhookStep.run(step_definition, context)
  end

  test "returns unavailable in non-strict mode on delivery failure" do
    step_definition = %{
      "id" => "notify_webhook",
      "type" => "event.notify_webhook"
    }

    context = %{
      run_input: %{
        "callback_url" => "http://127.0.0.1:1/webhook"
      },
      dependency_outputs: %{
        "manifest" => %{"manifest_key" => "LeDE9v86ye/manifest.json"}
      },
      dependency_artifacts: %{},
      flow_run_id: Ecto.UUID.generate()
    }

    assert {:ok, output, []} = EventNotifyWebhookStep.run(step_definition, context)
    assert output["status"] == "unavailable"
    assert output["step_type"] == "event.notify_webhook"
    assert output["callback_url"] == "http://127.0.0.1:1/webhook"
    assert is_binary(output["error"])
    assert output["error"] =~ "unsafe_callback_url"
  end

  test "returns error in strict mode on unsafe callback URL" do
    step_definition = %{
      "id" => "notify_webhook",
      "type" => "event.notify_webhook"
    }

    context = %{
      run_input: %{
        "callback_url" => "http://127.0.0.1:1/webhook",
        "notify_webhook_strict" => true
      },
      dependency_outputs: %{
        "manifest" => %{"manifest_key" => "LeDE9v86ye/manifest.json"}
      },
      dependency_artifacts: %{},
      flow_run_id: Ecto.UUID.generate()
    }

    assert {:error,
            {:event_notify_webhook_failed,
             {:unsafe_callback_url, {:blocked_address, {127, 0, 0, 1}}}}} =
             EventNotifyWebhookStep.run(step_definition, context)
  end
end
