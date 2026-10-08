defmodule MaveCore.Metrics.IngestionBuffer do
  @moduledoc false

  use Broadway

  alias Broadway.Message
  alias MaveCore.ClickHouseRepo
  alias MaveCore.EmbedId

  def start_link(_opts) do
    batch_timeout =
      :mave_core
      |> Application.get_env(:metrics_ingestion, [])
      |> Keyword.get(:clickhouse_batch_timeout, 1000)

    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module: {Broadway.DummyProducer, []}
      ],
      processors: [
        default: [concurrency: 5]
      ],
      batchers: [
        clickhouse: [
          batch_size: 1000,
          batch_timeout: batch_timeout,
          concurrency: 2
        ]
      ]
    )
  end

  def push(events) when is_list(events) do
    messages =
      Enum.map(events, fn event ->
        %Message{
          data: event,
          acknowledger: {Broadway.NoopAcknowledger, nil, nil}
        }
      end)

    Broadway.push_messages(__MODULE__, messages)
  end

  def push(event), do: push([event])

  @impl true
  def handle_message(_, message, _) do
    # Validate or transform message
    event = message.data

    # Ensure timestamp exists or default to now
    timestamp = Map.get(event, "timestamp", DateTime.utc_now() |> DateTime.to_unix(:millisecond))

    # Store prepared event
    message
    |> Message.put_data(Map.put(event, "timestamp", timestamp))
    |> Message.put_batcher(:clickhouse)
  end

  @impl true
  def handle_batch(:clickhouse, messages, _batch_info, _context) do
    formatted_rows = Enum.map(messages, &format_row(&1.data))

    # We use schema-less insert_all.
    # Must use the dynamic database name.
    config = MaveCore.ClickHouseRepo.config()
    db_name = config[:database] || "mave_metrics"
    # insert_all allows {prefix, table} tuple?
    # Or strict table name string?
    # Ecto supports passing a schema module OR a table name.
    # To support dynamic database (prefix), we typically use schema with @schema_prefix or options [prefix: ...].
    # But insert_all accepts `prefix` option.

    try do
      {_count, _} =
        ClickHouseRepo.insert_all(MaveCore.Metrics.Event, formatted_rows, prefix: db_name)

      # If successful, return messages
      messages
    rescue
      e ->
        require Logger
        Logger.error("Failed to insert metrics batch: #{inspect(e)}")
        Enum.map(messages, &Message.failed(&1, e))
    end
  end

  defp format_row(row) do
    %{space_hash: space_hash, embed_hash: embed_hash} = split_embed_id(row["embed_id"])
    %{client: client, os: os, device: device} = parse_user_agent(row["user_agent"])

    %{
      timestamp: DateTime.from_unix!(row["timestamp"] * 1000, :microsecond),
      name: row["name"],
      session_id: row["session_id"],
      space_hash: space_hash,
      embed_hash: embed_hash,
      video_time: (row["video_time"] || 0.0) * 1.0,
      duration: (row["duration"] || 0.0) * 1.0,
      source_url: row["source_url"] || "",
      component: row["component"] || "",
      browser: sanitize(client.name),
      browser_version: sanitize(client.version),
      os: sanitize(os.name),
      os_version: sanitize(os.version),
      device: sanitize(device.type, "desktop"),
      device_brand: sanitize(device.brand)
    }
  end

  defp split_embed_id(embed_id) when is_binary(embed_id) do
    case EmbedId.split(embed_id) do
      {:ok, parts} -> parts
      :error -> %{space_hash: "", embed_hash: ""}
    end
  end

  defp split_embed_id(_embed_id), do: %{space_hash: "", embed_hash: ""}

  defp parse_user_agent(user_agent) do
    parsed_ua = UAInspector.parse(user_agent || "")

    %{
      client: parsed_field(parsed_ua, :client, %{name: "Unknown", version: ""}),
      os: parsed_field(parsed_ua, :os, %{name: "Unknown", version: ""}),
      device: parsed_field(parsed_ua, :device, %{type: "desktop", brand: "", model: ""})
    }
  end

  defp parsed_field(parsed_ua, field, default) when is_map(parsed_ua) do
    parsed_ua
    |> Map.get(field)
    |> default_map(default)
  end

  defp parsed_field(_parsed_ua, _field, default), do: default

  defp default_map(value, _default) when is_map(value), do: value
  defp default_map(_value, default), do: default

  defp sanitize(val, default \\ "Unknown")
  defp sanitize(:unknown, default), do: default
  defp sanitize(nil, default), do: default
  defp sanitize(val, _) when is_binary(val), do: val
  defp sanitize(val, _), do: to_string(val)
end
