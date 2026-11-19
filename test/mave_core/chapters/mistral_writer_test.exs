defmodule MaveCore.Chapters.MistralWriterTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias MaveCore.Chapters.{MistralWriter, Suggester}
  alias MaveCore.TestSupport.ChapterTranscriptFixture, as: Fixture

  defmodule Adapter do
    def run(request) do
      send(self(), {:request, Jason.decode!(request.body), request.headers})

      {request,
       Req.Response.new(
         status: Process.get(:writer_status, 200),
         body: Process.get(:writer_response)
       )}
    end
  end

  setup do
    old = Application.get_env(:req, :default_options)
    key = System.get_env("MISTRAL_API_KEY")
    model = System.get_env("MAVE_CHAPTERS_MODEL")
    System.put_env("MISTRAL_API_KEY", "test-key")
    System.delete_env("MAVE_CHAPTERS_MODEL")
    Req.default_options(adapter: Adapter, retry: false)

    on_exit(fn ->
      if old,
        do: Application.put_env(:req, :default_options, old),
        else: Application.delete_env(:req, :default_options)

      restore("MISTRAL_API_KEY", key)
      restore("MAVE_CHAPTERS_MODEL", model)
    end)

    :ok
  end

  defp input(overrides \\ %{}) do
    Map.merge(
      %{
        cues: Fixture.cues(),
        duration: Fixture.duration(),
        language: "en",
        cuts: [35.0],
        max_chapters: 5,
        min_chapter_seconds: 15.0
      },
      overrides
    )
  end

  defp answer(content),
    do: %{"choices" => [%{"finish_reason" => "stop", "message" => %{"content" => content}}]}

  test "sends the timed transcript and reads the chapters from the answer" do
    Process.put(
      :writer_response,
      answer([
        %{"type" => "thinking", "thinking" => "private reasoning"},
        %{
          "type" => "text",
          "text" =>
            ~s({"chapters":[{"start":0,"title":"Garden"},{"start":35.7,"title":"Bicycle"},{"start":"x","title":"Broken"}]})
        }
      ])
    )

    assert MistralWriter.suggest(input()) ==
             {:ok, [%{start: 0, title: "Garden"}, %{start: 35.7, title: "Bicycle"}]}

    assert_received {:request, body, headers}
    assert headers["authorization"] == ["Bearer test-key"]
    assert body["model"] == "mistral-large-4-0"
    assert body["response_format"]["type"] == "json_schema"

    [%{"role" => "system", "content" => system}, %{"role" => "user", "content" => user}] =
      body["messages"]

    assert system =~ "Use at most 5 chapters"
    assert system =~ "at least 15 seconds"
    assert user =~ "[35.7] The bicycle is the second subject of this video."
    assert user =~ "Scene cuts (seconds): 35.0"
    assert user =~ "Language: en"
  end

  test "uses the configured model" do
    System.put_env("MAVE_CHAPTERS_MODEL", "mistral-small-test")
    Process.put(:writer_response, answer(~s({"chapters":[]})))

    assert MistralWriter.suggest(input()) == {:ok, []}
    assert_received {:request, %{"model" => "mistral-small-test"}, _headers}
  end

  test "reports failures without the provider's answer" do
    Process.put(:writer_response, answer("not json"))
    assert MistralWriter.suggest(input()) == {:error, :invalid_model_json}

    Process.put(:writer_response, %{
      "choices" => [%{"finish_reason" => "length", "message" => %{"content" => "{"}}]
    })

    assert MistralWriter.suggest(input()) == {:error, :model_output_truncated}

    Process.put(:writer_status, 401)
    assert MistralWriter.suggest(input()) == {:error, {:http_error, 401}}

    System.delete_env("MISTRAL_API_KEY")
    assert MistralWriter.suggest(input()) == {:error, :mistral_api_key_missing}
    refute MistralWriter.available?()
  end

  test "does not send transcripts that are too long for one request" do
    cues = for index <- 0..300, do: %{start: index * 1.0, end: index + 1.0, text: line()}

    assert MistralWriter.suggest(input(%{cues: cues})) == {:error, :transcript_too_long}
    refute_received {:request, _body, _headers}
  end

  test "the suggestion is checked like any other and falls back when the model fails" do
    Process.put(
      :writer_response,
      answer(
        ~s({"chapters":[{"start":1.2,"title":"1. The garden."},{"start":36.4,"title":"Bicycle care"}]})
      )
    )

    assert {:ok,
            %{
              generator: "mistral",
              chapters: [
                %{"start" => +0.0, "title" => "The garden"},
                %{"start" => 35.7, "title" => "Bicycle care"}
              ]
            }} =
             Suggester.suggest(
               cues: Fixture.cues(),
               duration: Fixture.duration(),
               writer: MistralWriter
             )

    Process.put(:writer_status, 400)

    log =
      capture_log(fn ->
        assert {:ok, %{generator: "local", chapters: [_, _, _, _]}} =
                 Suggester.suggest(
                   cues: Fixture.cues(),
                   duration: Fixture.duration(),
                   writer: MistralWriter
                 )
      end)

    assert log =~ "{:http_error, 400}"
  end

  defp line, do: String.duplicate("words ", 200)

  defp restore(name, nil), do: System.delete_env(name)
  defp restore(name, value), do: System.put_env(name, value)
end
