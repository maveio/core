defmodule MaveCore.Playback.JWTTest do
  use MaveCore.DataCase, async: false

  alias MaveCore.{Accounts, Embeds, Playback, Repo, Spaces}

  def available?(_space), do: true
  def token_endpoint, do: MaveCoreWeb.Endpoint

  setup do
    previous = Application.get_env(:mave_core, :playback_adapter)
    Application.put_env(:mave_core, :playback_adapter, __MODULE__)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:mave_core, :playback_adapter, previous),
        else: Application.delete_env(:mave_core, :playback_adapter)
    end)

    {:ok, user} =
      Accounts.create_user("playback-#{System.unique_integer([:positive])}@example.com")

    space = user.current_space_membership.space
    {:ok, key} = Spaces.create_key(space, %{access_level: "read_only"})
    {:ok, embed} = Embeds.create_video_embed(space, %{name: "Private video"})

    embed =
      embed
      |> Ecto.Changeset.change(playback_visibility: :private, playback_status: :private)
      |> Repo.update!()

    %{space: space, key: key, embed: embed, identifier: space.hash <> embed.hash}
  end

  test "read-only keys sign a sub and exp token without aud or iat", context do
    exp = System.system_time(:second) + 600
    token = sign(context.key, %{"sub" => context.identifier, "exp" => exp})
    assert context.key.access_level == :read_only
    assert {:ok, expires_at} = Playback.authorize(token, context.embed)
    assert expires_at == exp
  end

  test "expiration is optional and revoking the key rejects subsequent media requests", context do
    token = sign(context.key, %{"sub" => context.space.id})
    assert {:ok, expires_at} = Playback.authorize(token, context.embed)
    assert expires_at <= System.system_time(:second) + 86_400
    assert {:ok, _} = Spaces.delete_key(context.key)
    assert {:error, :unauthorized} = Playback.authorize(token, context.embed)
  end

  test "tokens may last longer than a day while signed storage URLs remain bounded", context do
    now = System.system_time(:second)

    token =
      sign(context.key, %{"sub" => context.identifier, "iat" => now, "exp" => now + 604_800})

    assert {:ok, expires_at} = Playback.authorize(token, context.embed)
    assert expires_at <= System.system_time(:second) + 86_400
  end

  test "expired or malformed time claims and incorrect signatures are rejected", context do
    now = System.system_time(:second)

    for claims <- [%{"exp" => now - 1}, %{"exp" => "tomorrow"}, %{"iat" => now + 3600}] do
      token = sign(context.key, Map.put(claims, "sub", context.identifier))
      assert {:error, :unauthorized} = Playback.authorize(token, context.embed)
    end

    token = sign(%{context.key | secret: "incorrect-secret"}, %{"sub" => context.identifier})
    assert {:error, :unauthorized} = Playback.authorize(token, context.embed)
  end

  test "a token for one video does not authorize another video", context do
    {:ok, other} = Embeds.create_video_embed(context.space, %{name: "Other video"})
    token = sign(context.key, %{"sub" => context.identifier})

    assert {:error, :unauthorized} =
             Playback.authorize(token, other)
  end

  defp sign(key, claims) do
    header = encode(%{"alg" => "HS256", "typ" => "JWT"})
    payload = encode(claims)
    input = header <> "." <> payload
    signature = :crypto.mac(:hmac, :sha256, Spaces.display_api_key(key.key, key.secret), input)
    input <> "." <> Base.url_encode64(signature, padding: false)
  end

  defp encode(value), do: value |> Jason.encode!() |> Base.url_encode64(padding: false)
end
