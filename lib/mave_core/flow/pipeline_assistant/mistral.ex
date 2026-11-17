defmodule MaveCore.Flow.PipelineAssistant.Mistral do
  @moduledoc """
  Suggests pipeline changes with a Mistral chat model.

  Uses `MISTRAL_API_KEY`, like transcription and translation. Two optional
  settings change where the request goes:

  - `MAVE_PIPELINE_ASSISTANT_MODEL`: the model, `mistral-medium-latest` by
    default.
  - `MAVE_PIPELINE_ASSISTANT_URL`: another endpoint that speaks the same chat
    completions format with JSON schema output, for example a self-hosted
    model. `MAVE_PIPELINE_ASSISTANT_API_KEY` is then sent as its key, when set.
  """
  @behaviour MaveCore.Flow.PipelineAssistant.Provider

  @default_url "https://api.mistral.ai/v1/chat/completions"
  @default_model "mistral-medium-latest"
  @receive_timeout_ms 60_000

  @schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["reply", "operations"],
    "properties" => %{
      "reply" => %{"type" => "string"},
      "operations" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["action", "step_id"],
          "properties" => %{
            "action" => %{"type" => "string", "enum" => ["turn_off", "turn_on", "set_setting"]},
            "step_id" => %{"type" => "string"},
            "setting" => %{"type" => ["string", "null"]},
            "value" => %{"type" => ["string", "null"]}
          }
        }
      }
    }
  }

  @instructions """
  You help a person change the encoding pipeline of their video space in Mave.
  The pipeline is the list of steps every uploaded video goes through. You get
  the steps as JSON and the person's request. Answer with JSON: a "reply" and
  the "operations" to propose.

  Operations:
  - {"action": "turn_off", "step_id": id} turns an optional step off. For an
    add-on step it removes the step.
  - {"action": "turn_on", "step_id": id} turns a step back on. For an add-on
    step it adds the step.
  - {"action": "set_setting", "step_id": id, "setting": key, "value": text}
    sets one of the settings listed for that step. Numbers and true/false are
    written as text. A null value restores the default.

  Rules:
  - Use only step ids and setting keys from the list.
  - Steps marked "required" cannot be turned off.
  - When a request is about a group, such as a resolution or a language,
    include every step that belongs to it. In step names SD is 480p, HD 720p,
    FHD 1080p, QHD 1440p and UHD 4K.
  - Steps that need a step you turn off are turned off automatically. Do not
    list them unless the person asked for them.
  - Change only what the request asks for. When the request is unclear, or
    cannot be done with these steps and settings, return no operations and say
    what is possible instead.
  - When you need something only the person knows, such as a name to use,
    ask for it and return no operations.
  - Keep the reply to one or two plain sentences in the language of the
    request. Say what you propose. Nothing is saved until the person approves.
  """

  @impl true
  def available?, do: match?({:ok, _key}, api_key())

  @impl true
  def suggest(request, opts \\ []) do
    with {:ok, key} <- api_key() do
      body = %{
        "model" => model(),
        "temperature" => 0.1,
        "max_tokens" => 2_000,
        "messages" => messages(request),
        "response_format" => %{
          "type" => "json_schema",
          "json_schema" => %{"name" => "pipeline_proposal", "schema" => @schema}
        }
      }

      [
        url: url(),
        method: :post,
        json: body,
        headers: headers(key),
        receive_timeout: @receive_timeout_ms,
        retry: :transient,
        max_retries: 1
      ]
      |> Req.new()
      |> MaveCore.Usage.attach(opts[:usage_context], %{
        category: "pipeline_assistant",
        provider: "mistral",
        model: body["model"],
        operation: "propose"
      })
      |> Req.request()
      |> decode()
    end
  end

  defp headers(nil), do: [{"accept", "application/json"}]

  defp headers(key),
    do: [{"authorization", "Bearer #{key}"}, {"accept", "application/json"}]

  @doc false
  def messages(request) do
    history =
      for %{role: role, text: text} <- Map.get(request, :history, []),
          role in [:user, :assistant],
          is_binary(text) do
        %{"role" => Atom.to_string(role), "content" => text}
      end

    system = @instructions <> "\nSteps:\n" <> Jason.encode!(request.steps)

    [%{"role" => "system", "content" => system}] ++
      history ++ [%{"role" => "user", "content" => request.message}]
  end

  defp decode({:ok, %{status: status, body: body}}) when status in 200..299,
    do: decode_answer(body)

  defp decode({:ok, %{status: status}}), do: {:error, {:http_error, status}}
  defp decode({:error, _reason}), do: {:error, :unreachable}

  defp decode_answer(%{"choices" => [%{"message" => %{"content" => content}} | _]}) do
    with text when is_binary(text) <- content_text(content),
         {:ok, %{"reply" => reply} = answer} when is_binary(reply) <- Jason.decode(text) do
      operations = answer |> Map.get("operations") |> List.wrap() |> Enum.filter(&is_map/1)
      {:ok, %{reply: String.trim(reply), operations: operations}}
    else
      _ -> {:error, :invalid_model_answer}
    end
  end

  defp decode_answer(_body), do: {:error, :invalid_model_answer}

  defp content_text(content) when is_binary(content), do: content

  defp content_text(content) when is_list(content) do
    content
    |> Enum.filter(&(is_map(&1) and &1["type"] == "text"))
    |> Enum.map_join(& &1["text"])
  end

  defp content_text(_content), do: nil

  # A custom endpoint brings its own key, or none for a local model.
  defp api_key do
    case {env("MAVE_PIPELINE_ASSISTANT_URL"), env("MISTRAL_API_KEY")} do
      {nil, nil} -> {:error, :not_configured}
      {nil, key} -> {:ok, key}
      {_url, _key} -> {:ok, env("MAVE_PIPELINE_ASSISTANT_API_KEY")}
    end
  end

  defp url, do: env("MAVE_PIPELINE_ASSISTANT_URL") || @default_url
  defp model, do: env("MAVE_PIPELINE_ASSISTANT_MODEL") || @default_model

  defp env(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end
end
