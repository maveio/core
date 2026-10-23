defmodule MaveCore.MCP.Client do
  @moduledoc false
  use MaveCore.Schema

  schema "mcp_clients" do
    field :name, :string
    field :redirect_uris, {:array, :string}
    timestamps()
  end
end
