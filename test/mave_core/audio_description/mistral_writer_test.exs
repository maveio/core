defmodule MaveCore.AudioDescription.MistralWriterTest do
  use ExUnit.Case, async: false
  alias MaveCore.AudioDescription.MistralWriter

  defmodule Adapter do
    def run(request) do
      send(self(), {:body, Jason.decode!(request.body)})

      {request, Req.Response.new(status: 200, body: Process.get(:writer_response))}
    end
  end

  setup do
    old = Application.get_env(:req, :default_options)
    key = System.get_env("MISTRAL_API_KEY")
    System.put_env("MISTRAL_API_KEY", "test-key")
    Req.default_options(adapter: Adapter)

    on_exit(fn ->
      if old,
        do: Application.put_env(:req, :default_options, old),
        else: Application.delete_env(:req, :default_options)

      if key,
        do: System.put_env("MISTRAL_API_KEY", key),
        else: System.delete_env("MISTRAL_API_KEY")
    end)

    :ok
  end

  test "extracts only final text from reasoning responses" do
    Process.put(:writer_response, %{
      "choices" => [
        %{
          "finish_reason" => "stop",
          "message" => %{
            "content" => [
              %{"type" => "thinking", "thinking" => "private reasoning"},
              %{"type" => "text", "text" => ~s({"cues":[]})}
            ]
          }
        }
      ]
    })

    assert {:ok, %{"cues" => []}} = MistralWriter.chat_json("Write.", [], schema: %{})
    assert_received {:body, body}
    assert body["reasoning_effort"] == "medium"
    assert body["response_format"]["type"] == "json_schema"
  end

  test "short revisions can use low reasoning while script generation defaults to medium" do
    Process.put(:writer_response, %{
      "choices" => [
        %{"finish_reason" => "stop", "message" => %{"content" => ~s({"text":"A door opens."})}}
      ]
    })

    assert {:ok, %{"text" => "A door opens."}} =
             MistralWriter.chat_json("Shorten.", [],
               schema: %{},
               max_tokens: 4000,
               reasoning_effort: "low"
             )

    assert_received {:body, body}
    assert body["reasoning_effort"] == "low"
    assert body["max_tokens"] == 4000
  end

  test "incomplete responses never become a partial script" do
    Process.put(:writer_response, %{
      "choices" => [%{"finish_reason" => "length", "message" => %{"content" => "{}"}}]
    })

    assert {:error, :model_output_truncated} = MistralWriter.chat_json("Write.", [], schema: %{})
  end
end
