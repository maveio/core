defmodule MaveCore.LiveStreams.Segment do
  @moduledoc false
  use Ecto.Schema

  alias MaveCore.LiveStreams.LiveStream

  @type t :: %__MODULE__{}

  @primary_key false
  @foreign_key_type MaveCore.Ecto.LegacyShortUUID
  @timestamps_opts [type: :utc_datetime_usec]

  schema "live_stream_segments" do
    belongs_to :live_stream, LiveStream, primary_key: true
    # Increases for the lifetime of the stream, across broadcasts.
    field :sequence, :integer, primary_key: true
    field :broadcast, :integer
    field :duration, :float
    field :key, :string
    field :size_bytes, :integer
    # True for the first segment after the encoder reconnected.
    field :discontinuity, :boolean, default: false
    # Discontinuities in the broadcast up to and including this segment.
    field :discontinuity_sequence, :integer, default: 0
    field :program_date_time, :utc_datetime_usec

    timestamps(updated_at: false)
  end
end
