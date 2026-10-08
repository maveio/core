defmodule MaveCore.Flow.Steps.EventNotifyWebhookStep do
  @moduledoc """
  Sends a completion webhook for flow runs.

  Default behavior is safe:
  - without callback URL, step returns `status: "skipped"`
  - with `notify_webhook_strict` enabled, missing callback or failed delivery returns an error
  """
  @behaviour MaveCore.Flow.Step

  alias MaveCore.Flow.Steps.Support, as: StepSupport
  alias MaveCore.PublicHttpUrl

  @response_body_limit 16 * 1_024
  @truncated_body "\n[mave: response body truncated]"

  @impl true
  def run(step_definition, context) do
    run_input = Map.get(context, :run_input, %{})
    dependency_outputs = Map.get(context, :dependency_outputs, %{})
    dependency_artifacts = Map.get(context, :dependency_artifacts, %{})
    params = Map.get(step_definition, "params", %{})
    flow_run_id = Map.get(context, :flow_run_id)
    step_id = Map.get(step_definition, "id", "notify_webhook")

    strict? =
      StepSupport.strict_enabled?(params, run_input, "notify_webhook_strict") or
        StepSupport.strict_enabled?(%{}, run_input, "event_notify_webhook_strict")

    override_url =
      run_input["callback_url"] || run_input["webhook_url"] || run_input["notify_webhook_url"]

    callback_url = override_url || params["url"]

    # A caller-selected destination must never inherit template credentials.
    headers =
      run_input["notify_webhook_headers"] ||
        if(override_url, do: %{}, else: params["headers"] || %{})

    payload = build_payload(run_input, dependency_outputs, dependency_artifacts, flow_run_id)

    with {:ok, callback_url} <- require_callback(callback_url),
         {:ok, status} <- deliver(callback_url, headers, payload) do
      {:ok,
       %{
         "status" => "ok",
         "step_type" => "event.notify_webhook",
         "step_id" => step_id,
         "callback_url" => callback_url,
         "response_status" => status,
         "delivered_at" => DateTime.utc_now() |> DateTime.to_iso8601()
       }, []}
    else
      {:error, :missing_callback_url} when strict? ->
        {:error, {:event_notify_webhook_failed, :missing_callback_url}}

      {:error, reason} when strict? ->
        {:error, {:event_notify_webhook_failed, reason}}

      {:error, :missing_callback_url} ->
        {:ok, skipped_output(step_id, "missing callback"), []}

      {:error, reason} ->
        {:ok, unavailable_output(step_id, reason, callback_url), []}
    end
  end

  defp build_payload(run_input, dependency_outputs, dependency_artifacts, flow_run_id) do
    manifest_output = Map.get(dependency_outputs, "manifest", %{})

    manifest_uri =
      manifest_output["manifest_uri"] ||
        find_manifest_uri(dependency_artifacts)

    %{
      "type" => "flow.completed",
      "flow_run_id" => flow_run_id,
      "space_hash" => run_input["space_hash"],
      "embed_hash" => run_input["embed_hash"],
      "version" => run_input["version"] || 0,
      "manifest" => %{
        "key" => manifest_output["manifest_key"],
        "uri" => manifest_uri,
        "checksum" => manifest_output["checksum"]
      },
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp find_manifest_uri(map) when is_map(map) do
    map
    |> Enum.flat_map(fn {_step_id, artifacts} ->
      case artifacts do
        list when is_list(list) -> list
        _ -> []
      end
    end)
    |> Enum.find_value(fn
      %{"name" => "manifest", "uri" => uri} when is_binary(uri) -> uri
      %{name: "manifest", uri: uri} when is_binary(uri) -> uri
      _ -> nil
    end)
  end

  defp find_manifest_uri(_), do: nil

  defp deliver(callback_url, headers, payload) do
    req_headers = normalize_headers(headers)

    with {:ok, req_options} <- callback_req_options(callback_url, req_headers, payload) do
      case Req.request(req_options) do
        {:ok, %Req.Response{status: status}} when status in 200..299 ->
          {:ok, status}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:http_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp callback_req_options(callback_url, headers, payload) do
    case PublicHttpUrl.req_options(callback_url,
           method: :post,
           json: payload,
           headers: headers,
           raw: true,
           decode_body: false,
           into: &collect_response_body/2,
           request_timeout: 15_000
         ) do
      {:ok, req_options} -> {:ok, req_options}
      {:error, reason} -> {:error, {:unsafe_callback_url, reason}}
    end
  end

  defp collect_response_body({:data, data}, {request, response}) do
    body = if is_binary(response.body), do: response.body, else: ""
    available = max(@response_body_limit - byte_size(@truncated_body) - byte_size(body), 0)

    if byte_size(data) <= available do
      {:cont, {request, %{response | body: body <> data}}}
    else
      prefix = binary_part(data, 0, available)
      {:halt, {request, %{response | body: body <> prefix <> @truncated_body}}}
    end
  end

  defp normalize_headers(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp normalize_headers(list) when is_list(list) do
    list
    |> Enum.flat_map(fn
      {k, v} -> [{to_string(k), to_string(v)}]
      _ -> []
    end)
  end

  defp normalize_headers(_), do: []

  defp require_callback(callback_url) when is_binary(callback_url) and callback_url != "",
    do: {:ok, callback_url}

  defp require_callback(_), do: {:error, :missing_callback_url}

  defp skipped_output(step_id, reason) do
    %{
      "status" => "skipped",
      "step_type" => "event.notify_webhook",
      "step_id" => step_id,
      "reason" => reason
    }
  end

  defp unavailable_output(step_id, reason, callback_url) do
    %{
      "status" => "unavailable",
      "step_type" => "event.notify_webhook",
      "step_id" => step_id,
      "callback_url" => callback_url,
      "error" => inspect(reason)
    }
  end
end
