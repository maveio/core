defmodule MaveCore.Spaces.Domain do
  @moduledoc false
  use MaveCore.Schema
  import Ecto.Changeset

  alias MaveCore.Spaces.Space

  @empty_message "Seems to be empty"
  @invalid_message "This doesn't seem like a valid domain"

  schema "space_domains" do
    field :domain, :string

    belongs_to :space, Space

    timestamps()
  end

  def changeset(domain, attrs) do
    domain
    |> cast(attrs, [:domain, :space_id])
    |> validate_required([:domain, :space_id], message: @empty_message)
    |> normalize_domain()
    |> validate_format(
      :domain,
      ~r/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$/i,
      message: @invalid_message
    )
    |> unique_constraint(:domain, name: :space_domains_space_id_domain_index)
  end

  defp normalize_domain(changeset) do
    update_change(changeset, :domain, fn value ->
      value
      |> to_string()
      |> String.trim()
      |> String.downcase()
      |> remove_scheme()
      |> remove_path_and_port()
      |> String.trim_trailing(".")
      |> remove_www()
    end)
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
end
