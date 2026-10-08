defmodule MaveCore.LogRedactionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  require Logger
  alias MaveCore.LogRedaction

  test "Phoenix filters authentication parameters, including nested secrets" do
    assert Phoenix.Logger.filter_values(%{
             "secret" => "hook-value",
             "user" => %{"password" => "password-value"},
             "source_url" => "https://source.example/?secret=signed-value",
             "name" => "Example"
           }) == %{
             "secret" => "[FILTERED]",
             "user" => %{"password" => "[FILTERED]"},
             "source_url" => "[FILTERED]",
             "name" => "Example"
           }
  end

  test "Logger removes URL credentials and legacy token paths while retaining context" do
    output =
      capture_log(fn ->
        Logger.warning(
          "fetch failed: https://user:password@storage.example/video.mp4?X-Amz-Signature=signed-value " <>
            "GET /api/v1/collection/legacy-token embed:upload-jwt Authorization: Bearer bearer-value",
          request_id: "request-123"
        )
      end)

    assert output =~ "fetch failed"
    assert output =~ "storage.example/video.mp4"

    for secret <- ~w(password signed-value legacy-token upload-jwt bearer-value) do
      refute output =~ secret
    end
  end

  test "structured reports and metadata retain shape and redact case-insensitive secret keys" do
    event = %{
      level: :error,
      msg: {:report, %{error: :failed, headers: [{"AUTHORIZATION", "Bearer value"}]}},
      meta: %{request_id: "123", api_secret: "value"}
    }

    assert %{msg: {:report, report}, meta: metadata} = LogRedaction.filter(event, [])
    assert report == %{error: :failed, headers: [{"AUTHORIZATION", "[FILTERED]"}]}
    assert metadata == %{request_id: "123", api_secret: "[FILTERED]"}
  end

  test "formatted Erlang diagnostics redact credential strings" do
    event = %{msg: {~c"request failed: ~s", [~c"https://user:pass@host.example/?token=value"]}}
    assert %{msg: {:string, message}} = LogRedaction.filter(event, [])
    assert message =~ "request failed: https://host.example/"
    refute message =~ "pass"
    refute message =~ "value"
  end
end
