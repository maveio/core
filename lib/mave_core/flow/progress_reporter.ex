defmodule MaveCore.Flow.ProgressReporter do
  @moduledoc false

  use GenServer
  require Logger

  alias MaveCore.Embeds
  alias MaveCore.Embeds.Embed
  alias MaveCore.Embeds.Events, as: EmbedEvents
  alias MaveCore.Flow.{Events, Run, StepRun}
  alias MaveCore.Repo

  @default_interval_ms 5_000
  @default_min_percent_delta 1.0

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def report(pid, event) when is_pid(pid) and is_map(event) do
    GenServer.cast(pid, {:progress, event})
    :ok
  end

  def report(_pid, _event), do: :ok

  def flush(pid) when is_pid(pid), do: GenServer.call(pid, :flush)
  def flush(_pid), do: :ok

  def stop(pid) when is_pid(pid), do: GenServer.call(pid, :stop)
  def stop(_pid), do: :ok

  @impl true
  def init(opts) do
    state = %{
      flow_run_id: Keyword.fetch!(opts, :flow_run_id),
      step_run_id: Keyword.fetch!(opts, :step_run_id),
      step_id: Keyword.fetch!(opts, :step_id),
      step_type: Keyword.fetch!(opts, :step_type),
      interval_ms: configured_interval_ms(),
      min_percent_delta: configured_min_percent_delta(),
      latest: nil,
      last_flushed_at_ms: nil,
      last_flushed_percent: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:progress, event}, state) do
    progress = normalize_progress(event)
    state = %{state | latest: progress}

    if flush_now?(state, progress) do
      {:noreply, flush_state(state)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:flush, _from, state) do
    {:reply, :ok, flush_state(state)}
  end

  def handle_call(:stop, _from, state) do
    {:stop, :normal, :ok, flush_state(state)}
  end

  defp flush_now?(%{last_flushed_at_ms: nil}, _progress), do: true

  defp flush_now?(_state, %{"force" => true}), do: true

  defp flush_now?(state, progress) do
    enough_time? =
      System.monotonic_time(:millisecond) - state.last_flushed_at_ms >= state.interval_ms

    enough_delta? =
      percent_delta(progress["percent"], state.last_flushed_percent) >= state.min_percent_delta

    enough_time? and enough_delta?
  end

  defp flush_state(%{latest: nil} = state), do: state

  defp flush_state(%{latest: progress} = state) do
    progress = Map.put(progress, "updated_at", now_iso8601())

    case persist_progress(state, progress) do
      :ok ->
        broadcast_progress(state, progress)

        %{
          state
          | last_flushed_at_ms: System.monotonic_time(:millisecond),
            last_flushed_percent: progress["percent"]
        }

      {:error, reason} ->
        Logger.warning(
          "Failed to persist flow progress for #{state.flow_run_id}/#{state.step_id}: " <>
            inspect(reason)
        )

        state
    end
  end

  defp persist_progress(state, progress) do
    Repo.transaction(fn -> update_step_run_progress!(state.step_run_id, progress) end)
    |> case do
      {:ok, _step_run} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp update_step_run_progress!(step_run_id, progress) do
    case Repo.get(StepRun, step_run_id) do
      %StepRun{} = step_run -> persist_step_run_progress!(step_run, progress)
      nil -> Repo.rollback(:step_run_not_found)
    end
  end

  defp persist_step_run_progress!(step_run, progress) do
    metadata =
      (step_run.execution_metadata || %{})
      |> Map.put("progress", progress)

    step_run
    |> StepRun.changeset(%{execution_metadata: metadata})
    |> Repo.update()
    |> case do
      {:ok, step_run} -> step_run
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp broadcast_progress(state, progress) do
    Events.broadcast_updated(state.flow_run_id, %{
      "step_status" => "executing",
      "step_type" => state.step_type,
      "progress" => progress["percent"]
    })

    maybe_broadcast_embed_progress(state.flow_run_id, state.step_type, progress)
  end

  defp maybe_broadcast_embed_progress(flow_run_id, step_type, progress) do
    with %Run{input: %{"space_hash" => space_hash, "embed_hash" => embed_hash}} <-
           Repo.get(Run, flow_run_id),
         %Embed{} = embed <- Embeds.get_embed_by_hashes(space_hash, embed_hash) do
      EmbedEvents.broadcast_updated(embed.space_id, embed.id, %{
        "phase" => "processing",
        "step_type" => step_type,
        "progress" => progress["percent"]
      })
    else
      _ -> :ok
    end
  end

  defp normalize_progress(event) do
    percent = normalize_percent(value(event, "percent") || percent_from_ratio(event))

    %{
      "status" => normalize_string(value(event, "status") || "executing"),
      "source" => normalize_string(value(event, "source") || "unknown"),
      "stage" => normalize_string(value(event, "stage") || "processing"),
      "step_id" => normalize_string(value(event, "step_id")),
      "codec" => normalize_string(value(event, "codec")),
      "size" => normalize_string(value(event, "size")),
      "container" => normalize_string(value(event, "container")),
      "variants" => normalize_string_list(value(event, "variants")),
      "preset" => normalize_string(value(event, "preset")),
      "tune" => normalize_string(value(event, "tune")),
      "percent" => percent,
      "ratio" => normalize_ratio(value(event, "ratio")),
      "out_time_ms" => normalize_integer(value(event, "out_time_ms")),
      "total_ms" => normalize_integer(value(event, "total_ms")),
      "frame" => normalize_integer(value(event, "frame")),
      "fps" => normalize_float(value(event, "fps")),
      "speed_x" => normalize_float(value(event, "speed_x")),
      "ffmpeg_elapsed_ms" => normalize_integer(value(event, "ffmpeg_elapsed_ms")),
      "total_size_bytes" => normalize_integer(value(event, "total_size_bytes")),
      "dup_frames" => normalize_integer(value(event, "dup_frames")),
      "drop_frames" => normalize_integer(value(event, "drop_frames")),
      "force" => value(event, "force") in [true, "true", 1, "1"]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp percent_from_ratio(event) do
    case normalize_ratio(value(event, "ratio")) do
      ratio when is_float(ratio) -> ratio * 100.0
      _ -> nil
    end
  end

  defp percent_delta(nil, _old), do: 0.0
  defp percent_delta(_new, nil), do: @default_min_percent_delta
  defp percent_delta(new, old), do: abs(new - old)

  defp normalize_percent(value) when is_integer(value), do: normalize_percent(value * 1.0)

  defp normalize_percent(value) when is_float(value) do
    value
    |> max(0.0)
    |> min(100.0)
    |> Float.round(1)
  end

  defp normalize_percent(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _rest} -> normalize_percent(parsed)
      :error -> nil
    end
  end

  defp normalize_percent(_value), do: nil

  defp normalize_ratio(value) when is_integer(value), do: normalize_ratio(value * 1.0)

  defp normalize_ratio(value) when is_float(value) do
    value
    |> max(0.0)
    |> min(1.0)
    |> Float.round(4)
  end

  defp normalize_ratio(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _rest} -> normalize_ratio(parsed)
      :error -> nil
    end
  end

  defp normalize_ratio(_value), do: nil

  defp normalize_integer(value) when is_integer(value), do: value

  defp normalize_integer(value) when is_float(value), do: round(value)

  defp normalize_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  defp normalize_integer(_value), do: nil

  defp normalize_float(value) when is_integer(value), do: normalize_float(value * 1.0)

  defp normalize_float(value) when is_float(value) do
    value
    |> max(0.0)
    |> Float.round(3)
  end

  defp normalize_float(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _rest} -> normalize_float(parsed)
      :error -> nil
    end
  end

  defp normalize_float(_value), do: nil

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      values -> values
    end
  end

  defp normalize_string_list(_values), do: nil

  defp normalize_string(value) when is_binary(value) and value != "", do: value
  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(_value), do: nil

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || existing_atom_value(map, key)
  end

  defp value(_map, _key), do: nil

  defp existing_atom_value(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp configured_interval_ms do
    :mave_core
    |> Application.get_env(:flow_progress_reporter, [])
    |> Keyword.get(:interval_ms, @default_interval_ms)
    |> normalize_positive_integer(@default_interval_ms)
  end

  defp configured_min_percent_delta do
    :mave_core
    |> Application.get_env(:flow_progress_reporter, [])
    |> Keyword.get(:min_percent_delta, @default_min_percent_delta)
    |> normalize_positive_float(@default_min_percent_delta)
  end

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_positive_integer(_value, default), do: default

  defp normalize_positive_float(value, _default) when is_float(value) and value > 0, do: value

  defp normalize_positive_float(value, _default) when is_integer(value) and value > 0,
    do: value * 1.0

  defp normalize_positive_float(_value, default), do: default

  defp now_iso8601 do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
