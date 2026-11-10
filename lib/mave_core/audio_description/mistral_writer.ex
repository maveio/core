defmodule MaveCore.AudioDescription.MistralWriter do
  @moduledoc "Structured narration generation with Mistral Large 4, separate from vision and TTS."

  def chat_json(system, content, opts) do
    case System.get_env("MISTRAL_API_KEY") do
      key when is_binary(key) and key != "" -> request(system, content, opts, key)
      _ -> {:error, :mistral_api_key_missing}
    end
  end

  defp request(system, content, opts, key) do
    body = %{
      "model" => model(),
      "reasoning_effort" => Keyword.get(opts, :reasoning_effort, "medium"),
      "temperature" => 0.2,
      "max_tokens" => Keyword.get(opts, :max_tokens, 12_000),
      "messages" => [
        %{"role" => "system", "content" => system},
        %{"role" => "user", "content" => content}
      ],
      "response_format" => %{
        "type" => "json_schema",
        "json_schema" => %{
          "name" => "audio_description",
          "schema" => Keyword.fetch!(opts, :schema)
        }
      }
    }

    case Req.post("https://api.mistral.ai/v1/chat/completions",
           json: body,
           headers: [{"authorization", "Bearer #{key}"}],
           receive_timeout: 300_000,
           retry: :transient,
           max_retries: 2
         ) do
      {:ok, %{status: status, body: response}} when status in 200..299 -> decode(response)
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
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

    case is_binary(text) && Jason.decode(text) do
      {:ok, %{} = data} -> {:ok, data}
      _ -> {:error, :invalid_model_json}
    end
  end

  defp decode(_), do: {:error, :empty_model_answer}

  defp model do
    case System.get_env("MAVE_AUDIO_DESCRIPTION_WRITER_MODEL") do
      value when is_binary(value) and value != "" -> value
      _ -> "mistral-large-4-0"
    end
  end
end
