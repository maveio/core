defmodule MaveCore.Ecto.LegacyShortUUID do
  @moduledoc """
  Ecto type wrapper for `MaveCore.LegacyShortUUID`.
  """

  @behaviour Ecto.Type

  alias MaveCore.LegacyShortUUID

  @impl Ecto.Type
  def type, do: :uuid

  @impl Ecto.Type
  def cast(value), do: LegacyShortUUID.cast(value)

  @impl Ecto.Type
  def load(value), do: LegacyShortUUID.load(value)

  @impl Ecto.Type
  def dump(value), do: LegacyShortUUID.dump(value)

  @impl Ecto.Type
  def embed_as(_format), do: :self

  @impl Ecto.Type
  def equal?(left, right), do: left == right

  @doc false
  @impl Ecto.Type
  def autogenerate, do: LegacyShortUUID.autogenerate()

  @doc false
  def generate, do: LegacyShortUUID.generate()
end
