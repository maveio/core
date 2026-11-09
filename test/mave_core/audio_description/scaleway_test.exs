defmodule MaveCore.AudioDescription.ScalewayTest do
  use ExUnit.Case, async: false
  alias MaveCore.AudioDescription.Scaleway

  defmodule Adapter do
    def run(request) do
      send(self(), {:request_body, Jason.decode!(request.body)})
      [response | rest] = Process.get(:ad_responses)
      Process.put(:ad_responses, rest)
      {request, Req.Response.new(status: 200, body: response)}
    end
  end

  setup do
    previous = Application.get_env(:req, :default_options)
    key = System.get_env("SCALEWAY_API_KEY")
    System.put_env("SCALEWAY_API_KEY", "test-key")
    Req.default_options(adapter: Adapter)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:req, :default_options, previous),
        else: Application.delete_env(:req, :default_options)

      if key,
        do: System.put_env("SCALEWAY_API_KEY", key),
        else: System.delete_env("SCALEWAY_API_KEY")
    end)

    :ok
  end

  defp response(text, finish \\ "stop"),
    do: %{"choices" => [%{"finish_reason" => finish, "message" => %{"content" => text}}]}

  defp request do
    Scaleway.chat_json("Describe.", [%{"type" => "text", "text" => "Input"}],
      schema: %{"type" => "object"},
      max_tokens: 1000
    )
  end

  test "retries invalid JSON once with strict output instructions" do
    Process.put(:ad_responses, [response("{invalid}"), response(~s({"cues":[]}))])
    assert {:ok, %{"cues" => []}} = request()
    assert_received {:request_body, original}
    assert_received {:request_body, retry}
    assert length(retry["messages"]) == length(original["messages"]) + 1
    assert retry["temperature"] == 0.1
  end

  test "truncated answers receive a larger bounded output budget" do
    Process.put(:ad_responses, [response("{", "length"), response(~s({"cues":[]}))])
    assert {:ok, _} = request()
    assert_received {:request_body, _}
    assert_received {:request_body, retry}
    assert retry["max_tokens"] == 2000
  end

  test "repeated malformed output remains a failure rather than invented data" do
    Process.put(:ad_responses, [response("{bad}"), response("{still bad}")])
    assert {:error, :invalid_model_json} = request()
    assert Process.get(:ad_responses) == []
  end

  test "content filtering is not retried" do
    Process.put(:ad_responses, [response("", "content_filter")])
    assert {:error, :model_response_filtered} = request()
    assert_received {:request_body, _}
    refute_received {:request_body, _}
  end
end
