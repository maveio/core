defmodule MaveCore.SpaceCreation do
  @moduledoc """
  Shared create-space form and backend dispatch.
  """

  import Ecto.Changeset

  alias MaveCore.Accounts

  @empty_message "Seems to be empty"
  @invalid_message "This doesn't seem like a valid domain"
  @no_owner_message "Please choose a managing space"

  @domain_regex ~r/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$/i

  @callback owner_space_options_for_user(MaveCore.Accounts.User.t()) :: [{String.t(), String.t()}]
  @callback can_create_space_for_user?(
              MaveCore.Accounts.User.t(),
              MaveCore.Spaces.Space.t() | nil
            ) :: boolean()
  @callback create_space_for_user(MaveCore.Accounts.User.t(), map()) ::
              {:ok, MaveCore.Accounts.User.t()} | {:error, term()}
  @callback standalone_description() :: String.t()

  @optional_callbacks can_create_space_for_user?: 2, standalone_description: 0

  def backend do
    Application.get_env(:mave_core, :space_creation_backend, Accounts)
  end

  def can_create_space_for_user?(user, current_space) do
    backend = backend()

    if function_exported?(backend, :can_create_space_for_user?, 2) do
      backend.can_create_space_for_user?(user, current_space)
    else
      true
    end
  end

  def owner_space_options_for_user(user) do
    backend = backend()

    if function_exported?(backend, :owner_space_options_for_user, 1) do
      backend.owner_space_options_for_user(user)
    else
      []
    end
  end

  def create_space_for_user(user, attrs) when is_map(attrs) do
    backend().create_space_for_user(user, attrs)
  end

  def standalone_description do
    backend = backend()

    if function_exported?(backend, :standalone_description, 0) do
      case backend.standalone_description() do
        description when is_binary(description) and description != "" -> description
        _description -> "Create a standalone space."
      end
    else
      "Create a standalone space."
    end
  end

  def change_form(attrs \\ %{}, opts \\ []) when is_map(attrs) and is_list(opts) do
    require_owner_space? = Keyword.get(opts, :require_owner_space?, false)

    {%{}, %{domain: :string, owner_space_id: :string}}
    |> cast(stringify_keys(attrs), [:domain, :owner_space_id])
    |> validate_required([:domain], message: @empty_message)
    |> update_change(:domain, &normalize_domain/1)
    |> validate_format(:domain, @domain_regex, message: @invalid_message)
    |> maybe_validate_owner_space(require_owner_space?)
  end

  def add_owner_space_error(%Ecto.Changeset{} = changeset) do
    add_error(changeset, :owner_space_id, @no_owner_message)
  end

  defp maybe_validate_owner_space(changeset, true) do
    validate_required(changeset, [:owner_space_id], message: @no_owner_message)
  end

  defp maybe_validate_owner_space(changeset, false), do: changeset

  defp normalize_domain(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> remove_scheme()
    |> remove_path_and_port()
    |> String.trim_trailing(".")
    |> remove_www()
  end

  defp remove_scheme("http://" <> rest), do: rest
  defp remove_scheme("https://" <> rest), do: rest
  defp remove_scheme(value), do: value

  defp remove_path_and_port(value) do
    value
    |> String.split("/", parts: 2)
    |> List.first()
    |> String.split(":", parts: 2)
    |> List.first()
  end

  defp remove_www("www." <> rest), do: rest
  defp remove_www(value), do: value

  defp stringify_keys(map) do
    Enum.into(map, %{}, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end
end
