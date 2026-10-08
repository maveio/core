defmodule MaveCore.Metrics.Event do
  use Ecto.Schema

  @primary_key false
  schema "events" do
    field :timestamp, :utc_datetime_usec
    field :name, :string
    field :session_id, Ecto.UUID
    field :space_hash, :string
    field :embed_hash, :string
    field :video_time, Ch, type: "Float32"
    field :duration, Ch, type: "Float32"
    field :source_url, :string
    field :component, :string

    # Session Context
    field :browser, :string
    field :browser_version, :string
    field :os, :string
    field :os_version, :string
    field :device, :string
    field :device_brand, :string
  end
end
