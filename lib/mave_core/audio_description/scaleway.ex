defmodule MaveCore.AudioDescription.Scaleway do
  @moduledoc """
  Chat completions with a JSON-schema answer on Scaleway Generative APIs (EU).

  Describing uses an image model (Gemma 4) that gets labelled stills; it runs
  with `reasoning_effort: "none"`, because with reasoning it runs out of tokens.
  Requires `SCALEWAY_API_KEY` (an IAM application with only
  `GenerativeApisModelAccess`).
  """

  @endpoint "https://api.scaleway.ai/v1/chat/completions"
  @default_model "gemma-4-26b-a4b-it"
  @pool_timeout_ms 30_000
  @receive_timeout_ms 5 * 60 * 1000

  @doc """
  Sends `system` and the user `content` parts and decodes the JSON answer.

  Options: `:schema` (required), `:max_tokens`, `:model`.
  """
  def chat_json(system, content, opts) when is_binary(system) and is_list(content) do
    with {:ok, api_key} <- fetch_api_key() do
      body =
        %{
          "model" => Keyword.get(opts, :model) || model(),
          "max_tokens" => Keyword.get(opts, :max_tokens, 8_000),
          "temperature" => 0.3,
          "response_format" => %{
            "type" => "json_schema",
            "json_schema" => %{"name" => "result", "schema" => Keyword.fetch!(opts, :schema)}
          },
          "messages" => [
            %{"role" => "system", "content" => system},
            %{"role" => "user", "content" => content}
          ]
        }
        |> maybe_put("reasoning_effort", reasoning_effort())

      body
      |> request(api_key)
      |> decode_answer()
    end
  end

  defp request(body, api_key) do
    case Req.post(endpoint(),
           json: body,
           headers: [{"authorization", "Bearer #{api_key}"}, {"accept", "application/json"}],
           finch: [pool_timeout: @pool_timeout_ms],
           receive_timeout: @receive_timeout_ms,
           retry: :transient,
           max_retries: 3
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, truncate(body)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_answer({:ok, %{"choices" => [%{"message" => %{"content" => content}} | _]}})
       when is_binary(content) and content != "" do
    content
    |> String.trim()
    |> String.replace(~r/^```(?:json)?\s*/i, "")
    |> String.replace(~r/```\s*$/, "")
    |> Jason.decode()
    |> case do
      {:ok, %{} = answer} -> {:ok, answer}
      _ -> {:error, :invalid_model_json}
    end
  end

  defp decode_answer({:ok, %{"choices" => [%{"finish_reason" => reason} | _]}}),
    do: {:error, {:empty_model_answer, reason}}

  defp decode_answer({:ok, _body}), do: {:error, :empty_model_answer}
  defp decode_answer({:error, _reason} = error), do: error

  defp fetch_api_key do
    case System.get_env("SCALEWAY_API_KEY") do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :scaleway_api_key_missing}
    end
  end

  defp model, do: env("MAVE_AUDIO_DESCRIPTION_MODEL", @default_model)
  defp endpoint, do: env("MAVE_AUDIO_DESCRIPTION_ENDPOINT", @endpoint)

  defp reasoning_effort do
    case env("MAVE_AUDIO_DESCRIPTION_REASONING_EFFORT", "none") do
      "" -> nil
      value -> value
    end
  end

  defp env(name, default) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> String.trim(value)
      _ -> default
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp truncate(body) when is_binary(body), do: String.slice(body, 0, 600)
  defp truncate(body), do: body |> inspect() |> String.slice(0, 600)
end
