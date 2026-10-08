defmodule MaveCoreWeb.Api.Data.EventIngest do
  @moduledoc false

  @max_events_per_request 500
  @max_name_bytes 128
  @max_embed_id_bytes 256
  @max_source_url_bytes 2048
  @max_keys_per_event 40
  @max_key_bytes 64
  @max_string_value_bytes 2048

  @max_clock_skew_future_ms 10 * 60 * 1000
  @max_age_past_ms 24 * 60 * 60 * 1000

  def validate_and_enrich(events, user_agent) when is_list(events) do
    if length(events) > @max_events_per_request do
      {:error, :too_many_events}
    else
      now_ms = System.system_time(:millisecond)

      with {:ok, sanitized} <- validate_events(events, now_ms) do
        enriched = Enum.map(sanitized, &Map.put(&1, "user_agent", user_agent))
        {:ok, enriched}
      end
    end
  end

  def validate_and_enrich(_events, _user_agent), do: {:error, :invalid_payload}

  defp validate_events(events, now_ms) do
    events
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {event, idx}, {:ok, acc} ->
      case validate_event(event, now_ms) do
        {:ok, sanitized} -> {:cont, {:ok, [sanitized | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_event, idx, reason}}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      other -> other
    end
  end

  defp validate_event(event, now_ms) when is_map(event) do
    event = sanitize_map(event)

    with {:ok, name} <- required_string(event, "name", @max_name_bytes),
         {:ok, session_id} <- required_uuid(event, "session_id"),
         {:ok, timestamp} <- required_timestamp(event, "timestamp"),
         {:ok, timestamp} <- clamp_timestamp(timestamp, now_ms),
         {:ok, embed_id} <- optional_string(event, "embed_id", @max_embed_id_bytes),
         {:ok, component} <- optional_string(event, "component", @max_string_value_bytes),
         {:ok, source_url} <- optional_string(event, "source_url", @max_source_url_bytes) do
      sanitized =
        event
        |> Map.put("name", name)
        |> Map.put("session_id", session_id)
        |> Map.put("timestamp", timestamp)

      sanitized =
        if embed_id,
          do: Map.put(sanitized, "embed_id", embed_id),
          else: Map.delete(sanitized, "embed_id")

      sanitized =
        if component,
          do: Map.put(sanitized, "component", component),
          else: Map.delete(sanitized, "component")

      sanitized =
        if source_url,
          do: Map.put(sanitized, "source_url", sanitize_url(source_url)),
          else: Map.delete(sanitized, "source_url")

      {:ok, sanitized}
    end
  end

  defp validate_event(_event, _now_ms), do: {:error, :event_not_map}

  defp sanitize_map(map) do
    map
    |> Enum.take(@max_keys_per_event)
    |> Enum.reduce(%{}, fn {k, v}, acc ->
      key =
        cond do
          is_binary(k) -> k
          is_atom(k) -> Atom.to_string(k)
          true -> nil
        end

      if invalid_key?(key) do
        acc
      else
        put_sanitized_value(acc, key, v)
      end
    end)
  end

  defp invalid_key?(nil), do: true
  defp invalid_key?(key), do: byte_size(key) > @max_key_bytes

  defp put_sanitized_value(acc, key, value) do
    case sanitize_value(value) do
      :drop -> acc
      sanitized_value -> Map.put(acc, key, sanitized_value)
    end
  end

  defp sanitize_value(v) when is_binary(v) do
    if byte_size(v) > @max_string_value_bytes do
      binary_part(v, 0, @max_string_value_bytes)
    else
      v
    end
  end

  defp sanitize_value(v) when is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp sanitize_value(_v), do: :drop

  defp required_string(map, key, max_bytes) do
    case Map.get(map, key) do
      v when is_binary(v) and v != "" ->
        if byte_size(v) <= max_bytes, do: {:ok, v}, else: {:error, {:too_long, key}}

      _ ->
        {:error, {:missing_or_invalid, key}}
    end
  end

  defp required_uuid(map, key) do
    with value when is_binary(value) and value != "" <- Map.get(map, key),
         {:ok, uuid} <- Ecto.UUID.cast(value) do
      {:ok, uuid}
    else
      _ -> {:error, {:invalid, key}}
    end
  end

  defp optional_string(map, key, max_bytes) do
    case Map.get(map, key) do
      nil ->
        {:ok, nil}

      v when is_binary(v) and v != "" ->
        if byte_size(v) <= max_bytes, do: {:ok, v}, else: {:error, {:too_long, key}}

      _ ->
        {:error, {:invalid, key}}
    end
  end

  defp required_timestamp(map, key) do
    case Map.get(map, key) do
      v when is_integer(v) -> {:ok, v}
      v when is_float(v) -> {:ok, trunc(v)}
      v when is_binary(v) -> parse_int(v)
      _ -> {:error, {:missing_or_invalid, key}}
    end
  end

  defp parse_int(v) do
    case Integer.parse(v) do
      {int, _rest} -> {:ok, int}
      :error -> {:error, {:invalid, "timestamp"}}
    end
  end

  defp clamp_timestamp(ts, now_ms) do
    cond do
      ts > now_ms + @max_clock_skew_future_ms ->
        {:ok, now_ms}

      ts < now_ms - @max_age_past_ms ->
        {:ok, now_ms}

      true ->
        {:ok, ts}
    end
  end

  defp sanitize_url(url) when is_binary(url) do
    uri = URI.parse(url)
    %{uri | query: nil, fragment: nil} |> URI.to_string()
  end
end
