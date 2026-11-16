defmodule MaveCore.LiveStreams.Config do
  @moduledoc false

  @defaults [
    enabled: false,
    rtmp_port: 1935,
    rtmp_url: nil,
    segment_seconds: 2,
    playlist_segments: 6,
    reconnect_seconds: 60,
    idle_timeout_seconds: 15,
    max_connections: 100
  ]

  def get(key) when is_atom(key) do
    :mave_core
    |> Application.get_env(:live_streams, [])
    |> Keyword.get(key, Keyword.fetch!(@defaults, key))
  end

  def enabled?, do: get(:enabled) == true
end
