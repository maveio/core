defmodule MaveCore.Schema do
  @moduledoc false

  defmacro __using__(_) do
    quote do
      use Ecto.Schema

      @primary_key {:id, MaveCore.Ecto.LegacyShortUUID, autogenerate: true}
      @foreign_key_type MaveCore.Ecto.LegacyShortUUID
      @timestamps_opts [type: :utc_datetime_usec]
    end
  end
end
