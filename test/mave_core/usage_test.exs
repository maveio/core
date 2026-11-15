defmodule MaveCore.UsageTest do
  use ExUnit.Case, async: false
  alias MaveCore.Usage

  defmodule Recorder do
    def record(event), do: send(self(), {:usage, event})
  end

  defmodule BrokenRecorder do
    def record(_), do: raise("unavailable")
  end

  defmodule Adapter do
    def run(request) do
      [response | remaining] = Process.get(:usage_responses)
      Process.put(:usage_responses, remaining)
      {request, response}
    end
  end

  setup do
    previous = Application.get_env(:mave_core, :usage_recorder)
    Application.put_env(:mave_core, :usage_recorder, Recorder)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:mave_core, :usage_recorder, previous),
        else: Application.delete_env(:mave_core, :usage_recorder)
    end)

    :ok
  end

  test "each HTTP retry gets a distinct event and retains only usage data" do
    Process.put(:usage_responses, [
      Req.Response.new(status: 429, body: ~s({"error":"secret response"})),
      Req.Response.new(
        status: 200,
        body:
          Jason.encode!(%{
            "usage" => %{
              "prompt_tokens" => 100,
              "completion_tokens" => 30,
              "prompt_tokens_details" => %{"cached_tokens" => 20},
              "completion_tokens_details" => %{"reasoning_tokens" => 15}
            },
            "choices" => [%{"message" => %{"content" => "private text"}}]
          })
      )
    ])

    request =
      Req.new(url: "https://example.com", adapter: Adapter, retry: :transient, retry_delay: 0)
      |> Usage.attach(%{flow_run_id: "run"}, %{
        provider: "mistral",
        model: "model",
        operation: "script"
      })

    assert {:ok, %{status: 200}} = Req.request(request)
    assert_received {:usage, failed}
    assert_received {:usage, success}
    assert failed.status == "failed"
    assert failed.usage_status == "unknown"
    assert failed.quantities == %{}

    assert success.quantities == %{
             "input_tokens" => 100,
             "output_tokens" => 30,
             "cached_input_tokens" => 20,
             "reasoning_tokens" => 15
           }

    refute failed.event_id == success.event_id
    refute inspect(success) =~ "private text"
    refute inspect(failed) =~ "secret response"
  end

  test "transport failures are unknown consumption rather than zero cost" do
    Process.put(:usage_responses, [%Req.TransportError{reason: :timeout}])

    request =
      Req.new(url: "https://example.com", adapter: Adapter, retry: false)
      |> Usage.attach(%{flow_run_id: "run"}, %{quantities: %{"input_characters" => 100}})

    assert {:error, _} = Req.request(request)
    assert_received {:usage, %{status: "failed", usage_status: "unknown", quantities: %{}}}
  end

  test "compressed provider responses retain their usage without changing the response" do
    json = Jason.encode!(%{"usage" => %{"prompt_tokens" => 12, "completion_tokens" => 4}})

    response =
      Req.Response.new(
        status: 200,
        headers: [{"content-encoding", "gzip"}, {"content-type", "application/json"}],
        body: :zlib.gzip(json)
      )

    Process.put(:usage_responses, [response])

    request =
      Req.new(url: "https://example.com", adapter: Adapter, compressed: true)
      |> Usage.attach(%{flow_run_id: "run"}, %{})

    assert {:ok, %{body: %{"usage" => _}}} = Req.request(request)
    assert_received {:usage, %{quantities: %{"input_tokens" => 12, "output_tokens" => 4}}}
  end

  test "recording failures do not break media processing" do
    Application.put_env(:mave_core, :usage_recorder, BrokenRecorder)
    assert :ok = Usage.record(%{}, %{})
    Application.delete_env(:mave_core, :usage_recorder)
    assert :ok = Usage.record(%{}, %{})
  end
end
