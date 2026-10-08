defmodule MaveCore.ClickHouseRepo do
  @moduledoc """
  A wrapper around the `Ch` driver to handle connection and query execution.
  Intentionally separate from Ecto to allow optimized batch ingestion.
  """

  use Ecto.Repo,
    otp_app: :mave_core,
    adapter: Ecto.Adapters.ClickHouse
end
