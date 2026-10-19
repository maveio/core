defmodule MaveCore.Transcription.MistralLanguageDetectorTest do
  use ExUnit.Case, async: false

  alias MaveCore.Transcription.MistralLanguageDetector

  defmodule RequestAdapter do
    def run(request) do
      send(self(), {:language_request, request})

      case Process.get(:language_http_result, {200, response(~s({"language":"it"}))}) do
        {status, body} -> {request, Req.Response.new(status: status, body: body)}
        exception -> {request, exception}
      end
    end

    def response(content), do: %{"choices" => [%{"message" => %{"content" => content}}]}
  end

  setup do
    previous_options = Application.get_env(:req, :default_options)
    previous_key = System.get_env("MISTRAL_API_KEY")
    Req.default_options(adapter: RequestAdapter)
    System.put_env("MISTRAL_API_KEY", "test-key")

    on_exit(fn ->
      if previous_options,
        do: Application.put_env(:req, :default_options, previous_options),
        else: Application.delete_env(:req, :default_options)

      if previous_key,
        do: System.put_env("MISTRAL_API_KEY", previous_key),
        else: System.delete_env("MISTRAL_API_KEY")
    end)

    :ok
  end

  test "classifies transcript data through a bounded structured chat request" do
    text = "La nostra azienda offre un servizio di qualità."
    assert {:ok, "it"} = MistralLanguageDetector.detect(text)
    assert_received {:language_request, request}
    body = Jason.decode!(request.body)

    assert body["model"] == "mistral-small-latest"
    assert body["temperature"] == 0
    assert body["max_tokens"] == 64
    assert body["response_format"]["type"] == "json_schema"
    assert body["response_format"]["json_schema"]["strict"]
    assert [%{"role" => "system"}, %{"role" => "user", "content" => content}] = body["messages"]
    assert Jason.decode!(content) == %{"transcript_samples" => [text]}
    assert request.options[:receive_timeout] == 15_000
    assert request.options[:retry] == false
  end

  test "samples the beginning, middle and end without sending a whole long transcript" do
    text =
      String.duplicate("α", 2_500) <> String.duplicate("β", 2_500) <> String.duplicate("γ", 2_500)

    assert {:ok, "it"} = MistralLanguageDetector.detect(text)
    assert_received {:language_request, request}
    [_, %{"content" => content}] = Jason.decode!(request.body)["messages"]
    samples = Jason.decode!(content)["transcript_samples"]

    assert samples == Enum.map(["α", "β", "γ"], &String.duplicate(&1, 2_000))
  end

  test "handles unknown and three-letter codes without inventing a language" do
    for {value, expected} <- [
          {nil, nil},
          {"und", nil},
          {"xxx", nil},
          {"ita", "it"},
          {"pol", "pl"}
        ] do
      Process.put(
        :language_http_result,
        {200, RequestAdapter.response(Jason.encode!(%{"language" => value}))}
      )

      assert {:ok, ^expected} = MistralLanguageDetector.detect("Transcript sample")
    end
  end

  test "rejects malformed or explanatory model output" do
    for body <- [
          RequestAdapter.response("Italian"),
          RequestAdapter.response(~s({"language":"Italian"})),
          RequestAdapter.response(~s({"language":42})),
          %{"choices" => []}
        ] do
      Process.put(:language_http_result, {200, body})

      assert {:error, :invalid_language_detection_response} =
               MistralLanguageDetector.detect("Transcript sample")
    end
  end

  test "does not retry failed detection or expose provider response bodies" do
    for result <- [{503, %{"error" => "provider failure"}}, %Req.TransportError{reason: :timeout}] do
      Process.put(:language_http_result, result)
      assert {:error, _reason} = MistralLanguageDetector.detect("Transcript sample")
      assert_received {:language_request, _}
      refute_received {:language_request, _}
    end
  end

  test "skips missing input and fails softly when no credentials are configured" do
    System.delete_env("MISTRAL_API_KEY")
    assert {:ok, nil} = MistralLanguageDetector.detect("  ")
    assert {:ok, nil} = MistralLanguageDetector.detect(nil)

    assert {:error, :mistral_api_key_missing} =
             MistralLanguageDetector.detect("Transcript sample")

    refute_received {:language_request, _}
  end
end
