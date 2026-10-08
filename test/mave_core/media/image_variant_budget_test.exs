defmodule MaveCore.Media.ImageVariantBudgetTest do
  use MaveCore.DataCase, async: false

  alias MaveCore.Accounts
  alias MaveCore.Embeds
  alias MaveCore.Media.ImageVariantBudget

  setup do
    original = Application.get_env(:mave_core, :image_variant_budget)

    Application.put_env(:mave_core, :image_variant_budget,
      per_embed: 2,
      per_space: 3,
      per_installation: 4
    )

    on_exit(fn -> restore_env(:image_variant_budget, original) end)

    email = "image-budget-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(email)
    space = user.current_space_membership.space
    {:ok, first_embed} = Embeds.create_video_embed(space, %{name: "First video"})
    {:ok, second_embed} = Embeds.create_video_embed(space, %{name: "Second video"})

    other_email = "other-image-budget-#{System.unique_integer([:positive])}@example.com"
    {:ok, other_user} = Accounts.create_user(other_email)
    other_space = other_user.current_space_membership.space
    {:ok, other_embed} = Embeds.create_video_embed(other_space, %{name: "Other video"})

    %{
      space: space,
      first_embed: first_embed,
      second_embed: second_embed,
      other_space: other_space,
      other_embed: other_embed
    }
  end

  test "reserves each path once and enforces per-embed and per-space limits", %{
    space: space,
    first_embed: first_embed,
    second_embed: second_embed,
    other_space: other_space,
    other_embed: other_embed
  } do
    assert {:ok, :new} = reserve(space, first_embed, "first.jpg")
    assert {:ok, :existing} = reserve(space, first_embed, "first.jpg")
    assert {:ok, :new} = reserve(space, first_embed, "second.jpg")
    assert {:error, :limit_reached} = reserve(space, first_embed, "third.jpg")

    assert {:ok, :new} = reserve(space, second_embed, "first.jpg")
    assert {:error, :limit_reached} = reserve(space, second_embed, "second.jpg")

    assert {:ok, :new} = reserve(other_space, other_embed, "first.jpg")
    assert {:error, :limit_reached} = reserve(other_space, other_embed, "second.jpg")
  end

  defp reserve(space, embed, path) do
    ImageVariantBudget.reserve(space.hash, embed.hash, path)
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)
end
