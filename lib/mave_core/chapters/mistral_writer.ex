defmodule MaveCore.Chapters.MistralWriter do
  @moduledoc """
  Suggests chapters with a Mistral chat model: it reads the timed transcript and
  returns topic changes with short titles in the transcript's language.

  Only the transcript text, its timestamps and scene-cut times are sent.
  """
  @behaviour MaveCore.Chapters.Writer

  @endpoint "https://api.mistral.ai/v1/chat/completions"
  @default_model "mistral-large-4-0"
  @max_transcript_characters 250_000

  @schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["chapters"],
    "properties" => %{
      "chapters" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["start", "title"],
          "properties" => %{
            "start" => %{"type" => "number"},
            "title" => %{"type" => "string"}
          }
        }
      }
    }
  }

  @doc "Whether a Mistral API key is configured."
  def available? do
    case System.get_env("MISTRAL_API_KEY") do
      key when is_binary(key) and key != "" -> true
      _ -> false
    end
  end

  @impl true
  def suggest(input, opts \\ []) do
    case System.get_env("MISTRAL_API_KEY") do
      key when is_binary(key) and key != "" ->
        # The whole transcript goes in one request; very long ones do not fit.
        if transcript_characters(input.cues) > @max_transcript_characters,
          do: {:error, :transcript_too_long},
          else: request(input, opts, key)

      _ ->
        {:error, :mistral_api_key_missing}
    end
  end

  defp transcript_characters(cues),
    do: Enum.reduce(cues, 0, fn cue, total -> total + String.length(cue.text) end)

  defp request(input, opts, key) do
    model = model()

    body = %{
      "model" => model,
      "temperature" => 0.2,
      "max_tokens" => 4_000,
      "messages" => [
        %{"role" => "system", "content" => system_prompt(input)},
        %{"role" => "user", "content" => user_prompt(input)}
      ],
      "response_format" => %{
        "type" => "json_schema",
        "json_schema" => %{"name" => "chapters", "schema" => @schema}
      }
    }

    Req.new(
      url: @endpoint,
      method: :post,
      json: body,
      headers: [{"authorization", "Bearer #{key}"}],
      receive_timeout: 120_000,
      retry: :transient,
      max_retries: 2
    )
    |> MaveCore.Usage.attach(opts[:usage_context], %{
      category: "chapters",
      provider: "mistral",
      model: model,
      operation: "suggest"
    })
    |> Req.request()
    |> case do
      {:ok, %{status: status, body: response}} when status in 200..299 -> decode(response)
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def system_prompt(input) do
    """
    You divide a video into chapters so viewers can jump to the part they need.

    You receive the video's transcript as lines of "[seconds] text", and
    optionally the times of scene cuts.

    Rules:
    - Start a chapter where the subject changes. Do not split one subject.
    - Use at most #{input.max_chapters} chapters. Use fewer when the video has fewer subjects.
    - Chapters last at least #{round(input.min_chapter_seconds)} seconds.
    - The first chapter starts at 0.
    - "start" is the number in brackets of the line where the chapter begins.
    - Scene cuts are hints: a new subject often begins near a cut.
    - Titles have two to six words, name the subject, and are written in the
      language of the transcript. No numbering, no quotation marks, no final
      punctuation. Use only what is said; do not add facts.

    Answer with JSON: {"chapters": [{"start": number, "title": string}]}.
    """
  end

  @doc false
  def user_prompt(input) do
    lines =
      Enum.map_join(input.cues, "\n", fn cue ->
        "[#{:erlang.float_to_binary(cue.start, decimals: 1)}] #{cue.text}"
      end)

    cuts =
      case input[:cuts] do
        [_ | _] = cuts ->
          "Scene cuts (seconds): " <>
            Enum.map_join(cuts, ", ", &:erlang.float_to_binary(&1 * 1.0, decimals: 1)) <> "\n"

        _ ->
          ""
      end

    """
    Duration: #{:erlang.float_to_binary(input.duration * 1.0, decimals: 1)} seconds
    Language: #{input[:language] || "unknown"}
    #{cuts}
    Transcript:
    #{lines}
    """
  end

  defp decode(%{"choices" => [%{"finish_reason" => "length"} | _]}),
    do: {:error, :model_output_truncated}

  defp decode(%{"choices" => [%{"message" => %{"content" => content}} | _]}) do
    text =
      if is_list(content),
        do:
          content
          |> Enum.filter(&(is_map(&1) and &1["type"] == "text"))
          |> Enum.map_join(& &1["text"]),
        else: content

    with true <- is_binary(text),
         {:ok, %{"chapters" => chapters}} when is_list(chapters) <- Jason.decode(text) do
      {:ok,
       for %{"start" => start, "title" => title} <- chapters,
           is_number(start) and is_binary(title) do
         %{start: start, title: title}
       end}
    else
      _ -> {:error, :invalid_model_json}
    end
  end

  defp decode(_response), do: {:error, :empty_model_answer}

  defp model do
    case System.get_env("MAVE_CHAPTERS_MODEL") do
      value when is_binary(value) and value != "" -> value
      _ -> @default_model
    end
  end
end
