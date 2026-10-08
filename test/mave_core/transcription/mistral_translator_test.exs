defmodule MaveCore.Transcription.MistralTranslatorTest do
  use ExUnit.Case, async: false

  alias MaveCore.Transcription.MistralTranslator

  defmodule RequestAdapter do
    def run(request) do
      send(self(), {:mistral_translation_request, request})

      response = %Finch.Response{
        status: 200,
        headers: [{"content-type", "application/json"}],
        body:
          Jason.encode!(%{
            "choices" => [
              %{
                "message" => %{
                  "content" =>
                    Jason.encode!([
                      %{"id" => 0, "text" => "Hello world"},
                      %{"id" => 1, "text" => "Another sentence"}
                    ])
                }
              }
            ]
          })
      }

      {request, Req.Response.new(response)}
    end
  end

  defmodule RetryAdapter do
    def run(request) do
      case Process.get(:mistral_responses, []) do
        [] ->
          RequestAdapter.run(request)

        [response | rest] ->
          Process.put(:mistral_responses, rest)
          send(self(), {:retry_request, request})

          case response do
            status when is_integer(status) ->
              {request, Req.Response.new(status: status, body: %{"error" => "provider failure"})}

            exception ->
              {request, exception}
          end
      end
    end
  end

  setup do
    previous_req_options = Application.get_env(:req, :default_options)
    previous_api_key = System.get_env("MISTRAL_API_KEY")

    System.put_env("MISTRAL_API_KEY", "test-key")

    on_exit(fn ->
      restore_env(:req, :default_options, previous_req_options)
      restore_system_env("MISTRAL_API_KEY", previous_api_key)
    end)

    :ok
  end

  test "translate sends subtitle segment batches to the Mistral chat API" do
    Req.default_options(adapter: RequestAdapter)

    assert {:ok, translation} =
             MistralTranslator.translate(
               %{
                 text: "Hallo wereld. Nog een zin.",
                 segments: [
                   %{start: 0.0, end: 1.5, text: "Hallo wereld"},
                   %{start: 1.5, end: 3.0, text: "Nog een zin"}
                 ]
               },
               source_language: "nl",
               target_language: "en"
             )

    assert translation.language == "en"
    assert translation.text == "Hello world Another sentence"
    assert [%{text: "Hello world"}, %{text: "Another sentence"}] = translation.segments

    assert_receive {:mistral_translation_request, req}

    body = Jason.decode!(req.body)
    assert body["model"] == "mistral-medium-latest"
    assert body["temperature"] == 0.1
    assert [%{"role" => "user", "content" => prompt}] = body["messages"]
    assert prompt =~ "Source language: nl"
    assert prompt =~ "Hallo wereld"
    assert req.options[:receive_timeout] == 10 * 60 * 1000
    assert req.options[:finch][:pool_timeout] == 30_000
    assert req.options[:retry] == :transient
    assert req.options[:max_retries] == 3
  end

  test "translation retries transient errors without changing the prompt" do
    Req.default_options(adapter: RetryAdapter, retry_delay: fn _ -> 0 end, retry_log_level: false)
    Process.put(:mistral_responses, [503])

    assert {:ok, _} = MistralTranslator.translate(%{text: "Hallo wereld"})
    assert_receive {:retry_request, first}
    assert_receive {:mistral_translation_request, last}
    assert first.body == last.body
  end

  test "translation stops retrying after four unavailable responses" do
    Req.default_options(adapter: RetryAdapter, retry_delay: fn _ -> 0 end, retry_log_level: false)
    Process.put(:mistral_responses, [503, 503, 503, 503, 200])

    assert {:error, {:mistral_translation_failed, 503, _}} =
             MistralTranslator.translate(%{text: "Hallo wereld"})

    for _ <- 1..4, do: assert_receive({:retry_request, _})
    assert Process.get(:mistral_responses) == [200]
    refute_receive {:mistral_translation_request, _}
  end

  test "translation does not retry an invalid model response" do
    Req.default_options(adapter: RetryAdapter, retry_delay: fn _ -> 0 end, retry_log_level: false)
    Process.put(:mistral_responses, [400])

    assert {:error, {:mistral_translation_failed, 400, _}} =
             MistralTranslator.translate(%{text: "Hallo wereld"})

    assert_receive {:retry_request, _}
    refute_receive {:mistral_translation_request, _}
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
