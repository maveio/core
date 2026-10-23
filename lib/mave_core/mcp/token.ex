defmodule MaveCore.MCP.Token do
  @moduledoc false
  use MaveCore.Schema

  schema "mcp_tokens" do
    belongs_to :grant, MaveCore.MCP.Grant
    field :access_hash, :binary
    field :refresh_hash, :binary
    field :access_expires_at, :utc_datetime_usec
    field :refresh_expires_at, :utc_datetime_usec
    field :refreshed_at, :utc_datetime_usec
    timestamps()
  end
end
