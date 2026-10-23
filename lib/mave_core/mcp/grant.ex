defmodule MaveCore.MCP.Grant do
  @moduledoc false
  use MaveCore.Schema

  schema "mcp_grants" do
    belongs_to :client, MaveCore.MCP.Client
    belongs_to :user, MaveCore.Accounts.User
    belongs_to :space, MaveCore.Spaces.Space
    field :resource, :string
    field :scope, :string
    field :redirect_uri, :string
    field :code_hash, :binary
    field :code_challenge, :string
    field :code_expires_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    timestamps()
  end
end
