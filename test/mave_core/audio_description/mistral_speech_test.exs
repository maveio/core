defmodule MaveCore.AudioDescription.MistralSpeechTest do
  use ExUnit.Case, async: false

  alias MaveCore.AudioDescription.MistralSpeech

  defmodule Adapter do
    def run(request) do
      send(self(), {:speech_request, Jason.decode!(request.body)})

      {request,
       Req.Response.new(status: 200, body: %{"audio_data" => Base.encode64("test audio")})}
    end
  end

  setup do
    previous = Application.get_env(:req, :default_options)
    env = Map.new(["MISTRAL_API_KEY", "MAVE_AUDIO_DESCRIPTION_VOICES"], &{&1, System.get_env(&1)})
    System.put_env("MISTRAL_API_KEY", "test-key")
    System.put_env("MAVE_AUDIO_DESCRIPTION_VOICES", "nl:test-dutch-voice")
    Req.default_options(adapter: Adapter)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:req, :default_options, previous),
        else: Application.delete_env(:req, :default_options)

      for {key, value} <- env do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    :ok
  end

  test "warm delivery keeps the selected voice and natural pace" do
    for opts <- [[], [pace: :moderate]] do
      assert {:ok, "test audio"} = MistralSpeech.speak("Een korte beschrijving.", "nl", opts)
      assert_received {:speech_request, request}
      assert request["voice_id"] == "test-dutch-voice"
      assert request["input"] == "[emotion=warm]Een korte beschrijving."
    end
  end

  test "Dutch speech with English names or a URL keeps the Dutch voice" do
    for language <- ["nl", "nl-NL"],
        text <- ["Ze vertelt over Open Access.", "Lees de uitleg op example.org."] do
      assert {:ok, _} = MistralSpeech.speak(text, language)
      assert_received {:speech_request, request}
      assert request["voice_id"] == "test-dutch-voice"

      assert request["input"] == "[emotion=warm]" <> text
    end
  end

  test "fitting can request fast speech while retaining warm delivery" do
    assert {:ok, _} = MistralSpeech.speak("Een korte beschrijving.", "nl", pace: :fast)
    assert_received {:speech_request, request}
    assert request["input"] == "[emotion=warm][pace=fast]Een korte beschrijving."
  end

  test "generated text cannot override the chosen delivery" do
    assert {:ok, _} = MistralSpeech.speak("[emotion=angry][pace=slow]Een zin.", "nl")
    assert_received {:speech_request, request}
    assert request["input"] == "[emotion=warm]Een zin."
  end
end
