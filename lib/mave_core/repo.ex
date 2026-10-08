defmodule MaveCore.Repo do
  use Ecto.Repo,
    otp_app: :mave_core,
    adapter: Ecto.Adapters.Postgres
end
