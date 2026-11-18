defmodule MaveCore.Usage do
  @moduledoc "Optional host hook for resource usage, without pricing or billing policy."
  require Logger

  @callback record(map()) :: term()

  @context_keys ~w(flow_run_id space_id space_hash embed_hash video_id step_id)a

  def context(context, step_id) do
    input = Map.get(context, :run_input, %{})

    %{
      flow_run_id: context[:flow_run_id],
      space_hash: input["space_hash"],
      embed_hash: input["embed_hash"],
      video_id: input["video_id"],
      step_id: step_id
    }
  end

  @doc "Records each HTTP attempt, including retries, without retaining request or response content."
  def attach(request, nil, _metadata), do: request

  def attach(request, context, metadata) do
    if Application.get_env(:mave_core, :usage_recorder),
      do: attach_steps(request, context, metadata),
      else: request
  end

  defp attach_steps(request, context, metadata) do
    request
    |> Req.Request.prepend_request_steps(
      usage_start: fn request ->
        request
        |> Req.Request.put_private(:usage_event_id, Ecto.UUID.generate())
        |> Req.Request.put_private(:usage_started, System.monotonic_time(:millisecond))
      end
    )
    |> Req.Request.prepend_response_steps(
      usage_stop: fn {request, response} ->
        body = response |> uncompressed_body() |> decode_body()
        quantities = token_usage(body)

        quantities =
          if response.status in 200..299,
            do: Map.merge(metadata[:quantities] || %{}, quantities),
            else: quantities

        record(
          context,
          Map.merge(metadata, %{
            event_id: request.private[:usage_event_id],
            elapsed_ms: elapsed(request),
            http_status: response.status,
            status: if(response.status in 200..299, do: "succeeded", else: "failed"),
            quantities: quantities,
            usage_status: if(quantities == %{}, do: "unknown", else: "measured")
          })
        )

        {request, response}
      end
    )
    |> Req.Request.prepend_error_steps(
      usage_error: fn {request, error} ->
        record(
          context,
          Map.merge(metadata, %{
            event_id: request.private[:usage_event_id],
            elapsed_ms: elapsed(request),
            status: "failed",
            quantities: %{},
            usage_status: "unknown"
          })
        )

        {request, error}
      end
    )
  end

  def record(nil, _event), do: :ok

  def record(context, event) do
    if recorder = Application.get_env(:mave_core, :usage_recorder) do
      event =
        event
        |> Map.merge(Map.take(context, @context_keys))
        |> Map.put_new(:event_id, Ecto.UUID.generate())
        |> Map.put_new(:occurred_at, DateTime.utc_now())

      case recorder.record(event) do
        {:error, _} -> Logger.warning("Resource usage could not be recorded")
        _ -> :ok
      end
    end

    :ok
  rescue
    _ -> Logger.warning("Resource usage recorder failed")
  end

  defp elapsed(request),
    do: max(0, System.monotonic_time(:millisecond) - request.private[:usage_started])

  defp uncompressed_body(%{body: body} = response) when is_binary(body) do
    case Req.Utils.decompress_with_encoding(
           Req.Response.get_header(response, "content-encoding"),
           body
         ) do
      {body, _} -> body
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp uncompressed_body(response), do: response.body

  defp decode_body(body) when is_map(body), do: body

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} -> decoded
      _ -> %{}
    end
  end

  defp decode_body(_), do: %{}

  defp token_usage(body) do
    usage = if is_map(body["usage"]), do: body["usage"], else: %{}

    %{
      "input_tokens" => usage["prompt_tokens"],
      "output_tokens" => usage["completion_tokens"],
      "cached_input_tokens" => get_in(usage, ["prompt_tokens_details", "cached_tokens"]),
      "reasoning_tokens" => get_in(usage, ["completion_tokens_details", "reasoning_tokens"])
    }
    |> Map.reject(fn {_key, value} -> not is_integer(value) or value < 0 end)
  end
end
