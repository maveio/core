defmodule MaveCore.Metrics.PlaybackQuality do
  @moduledoc """
  Player-reported playback quality events.

  Players send these through the regular event endpoint; they are stored apart
  from engagement events so viewing statistics are unaffected. One playback
  attempt is one session of one video:

    * `playback_request` – playback was requested (click or autoplay).
    * `playback_startup` – the first frame rendered; `startup_ms` since the request.
    * `playback_rebuffer` – a stall ended; `rebuffer_ms` it lasted.
    * `playback_sample` – `playing_ms` played since the previous sample, with the
      rendition's `bitrate` (bits per second), `width` and `height`.
    * `playback_error` – playback failed; `error_code` identifies the cause.

  An error before startup is a startup failure, afterwards a playback failure.
  """

  use Ecto.Schema

  @names ~w(playback_request playback_startup playback_rebuffer playback_sample playback_error)
  @max_duration_ms 600_000
  @max_bitrate 200_000_000
  @max_dimension 16_384
  @max_error_code_bytes 64

  @primary_key false
  schema "playback_quality" do
    field :timestamp, :utc_datetime_usec
    field :name, Ch, type: "LowCardinality(String)"
    field :session_id, Ecto.UUID
    field :space_hash, :string
    field :embed_hash, :string
    field :startup_ms, Ch, type: "UInt32"
    field :rebuffer_ms, Ch, type: "UInt32"
    field :playing_ms, Ch, type: "UInt32"
    field :bitrate, Ch, type: "UInt32"
    field :width, Ch, type: "UInt16"
    field :height, Ch, type: "UInt16"
    field :error_code, Ch, type: "LowCardinality(String)"
    field :browser, Ch, type: "LowCardinality(String)"
    field :os, Ch, type: "LowCardinality(String)"
    field :device, Ch, type: "LowCardinality(String)"
    field :country, Ch, type: "LowCardinality(String)"
  end

  def names, do: @names

  @doc "Whether an ingested event belongs in the playback quality table."
  def event?(%{"name" => name}), do: name in @names
  def event?(_event), do: false

  @doc """
  Typed measurements of a validated event. Values outside a plausible range are
  clamped, so one misbehaving client cannot distort averages.
  """
  def measurements(event) when is_map(event) do
    %{
      startup_ms: bounded(event["startup_ms"], @max_duration_ms),
      rebuffer_ms: bounded(event["rebuffer_ms"], @max_duration_ms),
      playing_ms: bounded(event["playing_ms"], @max_duration_ms),
      bitrate: bounded(event["bitrate"], @max_bitrate),
      width: bounded(event["width"], @max_dimension),
      height: bounded(event["height"], @max_dimension),
      error_code: error_code(event["error_code"]),
      country: country(event["country"])
    }
  end

  @doc "A two-letter ISO country code, or an empty string when unknown."
  def country(value) when is_binary(value) do
    code = value |> String.trim() |> String.upcase()
    if code =~ ~r/\A[A-Z]{2}\z/ and code != "XX", do: code, else: ""
  end

  def country(_value), do: ""

  defp bounded(value, max) when is_number(value), do: value |> trunc() |> max(0) |> min(max)
  defp bounded(_value, _max), do: 0

  defp error_code(value) when is_binary(value) do
    value
    |> String.replace(~r/[^A-Za-z0-9_.:\-]/, "")
    |> binary_part_max(@max_error_code_bytes)
  end

  defp error_code(value) when is_integer(value), do: Integer.to_string(value)
  defp error_code(_value), do: ""

  defp binary_part_max(value, max) when byte_size(value) > max, do: binary_part(value, 0, max)
  defp binary_part_max(value, _max), do: value
end
