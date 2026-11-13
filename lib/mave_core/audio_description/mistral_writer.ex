defmodule MaveCore.AudioDescription.MistralWriter do
  @moduledoc "Structured narration generation with Mistral Large 4, separate from vision and TTS."

  def chat_json(system, content, opts) do
    case System.get_env("MISTRAL_API_KEY") do
      key when is_binary(key) and key != "" -> request(system, content, opts, key)
      _ -> {:error, :mistral_api_key_missing}
    end
  end

  defp request(system, content, opts, key) do
    started = System.monotonic_time(:millisecond)

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

    response =
      Req.post("https://api.mistral.ai/v1/chat/completions",
        json: body,
        headers: [{"authorization", "Bearer #{key}"}],
        receive_timeout: 300_000,
        retry: :transient,
        max_retries: 2
      )

    if callback = opts[:on_response], do: callback.(metrics(response, body, started))

    case response do
      {:ok, %{status: status, body: response}} when status in 200..299 -> decode(response)
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp metrics(response, request, started) do
    base = %{
      "model" => request["model"],
      "reasoning_effort" => request["reasoning_effort"],
      "max_tokens" => request["max_tokens"],
      "elapsed_ms" => System.monotonic_time(:millisecond) - started
    }

    case response do
      {:ok, %{status: status, body: body}} when is_map(body) ->
        usage = Map.take(body["usage"] || %{}, ~w(prompt_tokens completion_tokens total_tokens))
        details = get_in(body, ["usage", "completion_tokens_details"]) || %{}
        usage = Map.merge(usage, Map.take(details, ~w(reasoning_tokens)))
        first = List.first(body["choices"] || []) || %{}

        Map.merge(base, %{
          "http_status" => status,
          "finish_reason" => first["finish_reason"],
          "usage" => usage
        })

      {:ok, %{status: status}} ->
        Map.put(base, "http_status", status)

      {:error, _} ->
        Map.put(base, "transport_error", true)
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
