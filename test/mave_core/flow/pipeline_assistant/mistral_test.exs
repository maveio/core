defmodule MaveCore.Flow.PipelineAssistant.MistralTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias MaveCore.Flow.PipelineAssistant.Mistral

  @env ~w(MISTRAL_API_KEY MAVE_PIPELINE_ASSISTANT_URL MAVE_PIPELINE_ASSISTANT_API_KEY MAVE_PIPELINE_ASSISTANT_MODEL)

  setup {Req.Test, :verify_on_exit!}

  setup do
    previous_options = Req.default_options()
    previous_env = Map.new(@env, &{&1, System.get_env(&1)})
    Req.default_options(plug: {Req.Test, __MODULE__}, retry: false)
    Enum.each(@env, &System.delete_env/1)

    on_exit(fn ->
      Req.default_options(previous_options)

      for {name, value} <- previous_env do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end
    end)

    :ok
  end

  defp request do
    %{
      message: "Do not generate 4K for this space",
      history: [%{role: :user, text: "Hi"}, %{role: :assistant, text: "Hello"}],
      steps: [%{"id" => "video_h264_uhd", "name" => "Transcode Video H264 UHD", "state" => "on"}]
    }
  end

  defp answer(conn, content) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{"choices" => [%{"message" => %{"content" => content}}]}))
  end

  test "is available once a key or another endpoint is configured" do
    refute Mistral.available?()
    assert Mistral.suggest(request()) == {:error, :not_configured}

    System.put_env("MISTRAL_API_KEY", "test-key")
    assert Mistral.available?()

    System.delete_env("MISTRAL_API_KEY")
    System.put_env("MAVE_PIPELINE_ASSISTANT_URL", "http://localhost:11434/v1/chat/completions")
    assert Mistral.available?()
  end

  test "asks for a proposal as JSON and returns the reply and operations" do
    System.put_env("MISTRAL_API_KEY", "test-key")

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.host == "api.mistral.ai"
      assert conn.request_path == "/v1/chat/completions"
      assert get_req_header(conn, "authorization") == ["Bearer test-key"]

      {:ok, body, conn} = read_body(conn)
      body = Jason.decode!(body)

      assert body["model"] == "mistral-medium-latest"
      assert body["response_format"]["type"] == "json_schema"

      assert get_in(body, ["response_format", "json_schema", "schema", "required"]) ==
               ["reply", "operations"]

      assert [system, %{"role" => "user", "content" => "Hi"}, assistant, last] = body["messages"]
      assert system["role"] == "system"
      assert system["content"] =~ "Steps marked \"required\" cannot be turned off."
      assert system["content"] =~ ~s("id":"video_h264_uhd")
      assert assistant == %{"role" => "assistant", "content" => "Hello"}
      assert last == %{"role" => "user", "content" => "Do not generate 4K for this space"}

      answer(
        conn,
        Jason.encode!(%{
          "reply" => " I propose to stop making 4K. ",
          "operations" => [
            %{"action" => "turn_off", "step_id" => "video_h264_uhd", "setting" => nil},
            "not an operation"
          ]
        })
      )
    end)

    assert Mistral.suggest(request()) ==
             {:ok,
              %{
                reply: "I propose to stop making 4K.",
                operations: [
                  %{"action" => "turn_off", "step_id" => "video_h264_uhd", "setting" => nil}
                ]
              }}
  end

  test "can use another endpoint and model" do
    System.put_env(
      "MAVE_PIPELINE_ASSISTANT_URL",
      "http://models.internal:8000/v1/chat/completions"
    )

    System.put_env("MAVE_PIPELINE_ASSISTANT_MODEL", "local-model")
    System.put_env("MISTRAL_API_KEY", "mistral-key")

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.host == "models.internal"
      assert get_req_header(conn, "authorization") == []
      {:ok, body, conn} = read_body(conn)
      assert Jason.decode!(body)["model"] == "local-model"
      answer(conn, ~s({"reply":"Nothing to change.","operations":[]}))
    end)

    assert Mistral.suggest(request()) == {:ok, %{reply: "Nothing to change.", operations: []}}

    System.put_env("MAVE_PIPELINE_ASSISTANT_API_KEY", "local-key")

    Req.Test.expect(__MODULE__, fn conn ->
      assert get_req_header(conn, "authorization") == ["Bearer local-key"]
      answer(conn, ~s({"reply":"Nothing to change.","operations":[]}))
    end)

    assert {:ok, _suggestion} = Mistral.suggest(request())
  end

  test "reports a failed request and an answer that is not a proposal" do
    System.put_env("MISTRAL_API_KEY", "test-key")

    Req.Test.expect(__MODULE__, fn conn -> send_resp(conn, 401, "no") end)
    assert Mistral.suggest(request()) == {:error, {:http_error, 401}}

    Req.Test.expect(__MODULE__, fn conn -> answer(conn, "Sure, I turned off 4K!") end)
    assert Mistral.suggest(request()) == {:error, :invalid_model_answer}

    Req.Test.expect(__MODULE__, fn conn -> answer(conn, ~s({"operations":[]})) end)
    assert Mistral.suggest(request()) == {:error, :invalid_model_answer}
  end
end
