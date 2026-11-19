defmodule MaveCore.AccountDeletion do
  @moduledoc """
  Optional host-application guard for account and space deletion.
  """

  alias MaveCore.Spaces.Space

  @callback can_delete_space?(Space.t()) :: :ok | {:error, term()}
  @callback enqueue_deleted_space_cleanup(Space.t()) :: :ok | {:error, term()}
  @callback requirements() :: [String.t()]
  @callback error_message(term()) :: String.t() | nil

  @callback settings_action(MaveCore.Accounts.User.t(), Space.t()) :: :account | :space | :hidden
  @callback can_delete_subspace?(MaveCore.Accounts.User.t(), Space.t()) :: :ok | {:error, term()}
  @callback has_subspaces?(Space.t()) :: boolean()

  def has_subspaces?(space), do: call_backend(:has_subspaces?, [space], false)

  def can_delete_subspace?(user, space),
    do: call_backend(:can_delete_subspace?, [user, space], :ok)

  @callback delete_subspace(MaveCore.Accounts.User.t(), Space.t()) ::
              {:ok, Space.t()} | {:error, term()}

  def settings_action(user, space), do: call_backend(:settings_action, [user, space], :account)

  def delete_subspace(user, space),
    do: call_backend(:delete_subspace, [user, space], {:error, :not_authorized})

  @optional_callbacks has_subspaces?: 1,
                      can_delete_subspace?: 2,
                      settings_action: 2,
                      delete_subspace: 2,
                      enqueue_deleted_space_cleanup: 1,
                      requirements: 0,
                      error_message: 1

  def can_delete_space?(%Space{} = space) do
    case backend() do
      backend when is_atom(backend) ->
        if Code.ensure_loaded?(backend) and function_exported?(backend, :can_delete_space?, 1) do
          backend.can_delete_space?(space)
        else
          :ok
        end

      _other ->
        :ok
    end
  end

  def enqueue_deleted_space_cleanup(%Space{} = space) do
    case backend() do
      backend when is_atom(backend) ->
        if Code.ensure_loaded?(backend) and
             function_exported?(backend, :enqueue_deleted_space_cleanup, 1) do
          backend.enqueue_deleted_space_cleanup(space)
        else
          :ok
        end

      _other ->
        :ok
    end
  end

  def requirements do
    case call_backend(:requirements, [], []) do
      requirements when is_list(requirements) ->
        Enum.filter(requirements, &(is_binary(&1) and String.trim(&1) != ""))

      _requirements ->
        []
    end
  end

  def error_message(reason) do
    case call_backend(:error_message, [reason], nil) do
      message when is_binary(message) and message != "" -> message
      _message -> nil
    end
  end

  defp call_backend(callback, args, default) do
    case backend() do
      backend when is_atom(backend) ->
        if Code.ensure_loaded?(backend) and function_exported?(backend, callback, length(args)) do
          apply(backend, callback, args)
        else
          default
        end

      _backend ->
        default
    end
  end

  defp backend do
    Application.get_env(:mave_core, :account_deletion_backend)
  end
end
