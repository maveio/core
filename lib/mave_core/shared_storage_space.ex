defmodule MaveCore.SharedStorageSpace do
  @moduledoc """
  Optional marker for a space whose object storage is shared by multiple users.

  Standalone Core does not reserve a space hash. Host applications may configure
  `:shared_storage_space_hash` when they intentionally operate a shared bucket.
  """

  @spec hash() :: String.t() | nil
  def hash do
    case Application.get_env(:mave_core, :shared_storage_space_hash) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          value -> value
        end

      _value ->
        nil
    end
  end

  @spec shared?(map()) :: boolean()
  def shared?(%{hash: candidate}), do: hash?(candidate)
  def shared?(_space), do: false

  @spec hash?(term()) :: boolean()
  def hash?(candidate) when is_binary(candidate) do
    case hash() do
      configured when is_binary(configured) -> String.trim(candidate) == configured
      nil -> false
    end
  end

  def hash?(_candidate), do: false
end
