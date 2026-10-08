defmodule MaveCore.Transcription.MistralTest do
  use ExUnit.Case, async: false

  alias MaveCore.Transcription.Mistral

  defmodule RequestAdapter do
    def run(request) do
      send(self(), {:mistral_request, request})

      response = %Finch.Response{
        status: 200,
        headers: [{"content-type", "application/json"}],
        body:
          Jason.encode!(%{
            "text" => "Hello world",
            "language" => "en",
            "segments" => [%{"start" => 0.0, "end" => 1.0, "text" => "Hello world"}]
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
    previous_model = System.get_env("MISTRAL_TRANSCRIPTION_MODEL")

    System.put_env("MISTRAL_API_KEY", "test-key")
    System.delete_env("MISTRAL_TRANSCRIPTION_MODEL")

    on_exit(fn ->
      restore_env(:req, :default_options, previous_req_options)
      restore_system_env("MISTRAL_API_KEY", previous_api_key)
      restore_system_env("MISTRAL_TRANSCRIPTION_MODEL", previous_model)
    end)

    :ok
  end

  test "transcribe_url sends a file_url request with extended receive timeout" do
    Req.default_options(adapter: RequestAdapter)

    assert {:ok, transcription} =
             Mistral.transcribe_url("https://space-ubg50.video-dns.com/video/audio.mp3",
               language: "en"
             )

    assert transcription.text == "Hello world"
    assert transcription.language == "en"
    assert [%{start: start_time, end: end_time, text: "Hello world"}] = transcription.segments
    assert_in_delta start_time, 0.0, 0.001
    assert_in_delta end_time, 1.0, 0.001

    assert_receive {:mistral_request, req}

    assert %{
             "file_url" => "https://space-ubg50.video-dns.com/video/audio.mp3",
             "model" => "voxtral-mini-2602",
             "timestamp_granularities" => ["segment"]
           } = Jason.decode!(req.body)

    refute Map.has_key?(Jason.decode!(req.body), "language")
    assert req.options[:receive_timeout] == 30 * 60 * 1000
    assert req.options[:finch][:pool_timeout] == 30_000
    assert req.options[:retry] == :transient
    assert req.options[:max_retries] == 3
  end

  test "URL transcription recovers after transient HTTP and transport failures" do
    Req.default_options(adapter: RetryAdapter, retry_delay: fn _ -> 0 end, retry_log_level: false)
    Process.put(:mistral_responses, [503, 429, %Req.TransportError{reason: :timeout}])

    assert {:ok, %{text: "Hello world"}} = Mistral.transcribe_url("https://example.com/audio.mp3")
    assert_receive {:retry_request, first}
    assert_receive {:retry_request, second}
    assert_receive {:retry_request, third}
    assert_receive {:mistral_request, last}
    assert first.body == second.body
    assert second.body == third.body
    assert third.body == last.body
    refute_receive {:retry_request, _}
  end

  test "multipart transcription retries server failures with the same audio" do
    Req.default_options(adapter: RetryAdapter, retry_delay: fn _ -> 0 end, retry_log_level: false)
    Process.put(:mistral_responses, [502, 500, 504])

    assert {:ok, %{text: "Hello world"}} = Mistral.transcribe("synthetic audio bytes")
    assert_receive {:retry_request, first}
    assert_receive {:retry_request, _}
    assert_receive {:retry_request, _}
    assert_receive {:mistral_request, last}

    multipart_body = fn request ->
      ["multipart/form-data; boundary=" <> boundary] =
        Req.Request.get_header(request, "content-type")

      request.body |> IO.iodata_to_binary() |> String.replace(boundary, "BOUNDARY")
    end

    assert multipart_body.(first) == multipart_body.(last)
    assert multipart_body.(last) =~ "synthetic audio bytes"
  end

  test "persistent failures stop after four requests and retain the provider error" do
    Req.default_options(adapter: RetryAdapter, retry_delay: fn _ -> 0 end, retry_log_level: false)
    Process.put(:mistral_responses, [503, 503, 503, 503, 200])

    assert {:error, {:mistral_request_failed, 503, %{"error" => "provider failure"}}} =
             Mistral.transcribe_url("https://example.com/audio.mp3")

    for _ <- 1..4, do: assert_receive({:retry_request, _})
    assert Process.get(:mistral_responses) == [200]
    refute_receive {:mistral_request, _}
  end

  test "invalid requests and credentials are not retried" do
    Req.default_options(adapter: RetryAdapter, retry_delay: fn _ -> 0 end, retry_log_level: false)

    for status <- [400, 401, 403, 404, 422] do
      Process.put(:mistral_responses, [status])

      assert {:error, {:mistral_request_failed, ^status, _}} =
               Mistral.transcribe_url("https://example.com/audio.mp3")

      assert_receive {:retry_request, _}
      refute_receive {:mistral_request, _}
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
