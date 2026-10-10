defmodule MaveCore.Playback.SessionTest do
  use ExUnit.Case, async: false
  alias MaveCore.Embeds.Embed
  alias MaveCore.Playback

  defmodule Endpoint do
    def config(:secret_key_base), do: String.duplicate("playback-test", 8)
  end

  defmodule Adapter do
    def token_endpoint, do: Endpoint
  end

  setup do
    previous = Application.get_env(:mave_core, :playback_adapter)
    Application.put_env(:mave_core, :playback_adapter, Adapter)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:mave_core, :playback_adapter, previous),
        else: Application.delete_env(:mave_core, :playback_adapter)
    end)
  end

  test "dashboard sessions use the active deployment endpoint and bind to one video" do
    embed = %Embed{id: Ecto.UUID.generate(), space_id: Ecto.UUID.generate()}
    session = Playback.dashboard_session(embed)
    assert_in_delta session.expires_at - System.system_time(:second), 86_400, 1
    assert {:ok, session.expires_at} == Playback.authorize(session.token, embed)

    assert {:error, :unauthorized} ==
             Playback.authorize(session.token, %{embed | id: Ecto.UUID.generate()})

    assert {:error, :unauthorized} == Playback.authorize(nil, embed)
  end

  test "dashboard sessions remain valid after an hour but never past their expiry" do
    embed = %Embed{id: Ecto.UUID.generate(), space_id: Ecto.UUID.generate()}
    now = System.system_time(:second)
    claims = %{embed_id: embed.id, space_id: embed.space_id, expires_at: now + 79_200}
    token = Phoenix.Token.sign(Endpoint, "media-playback-v1", claims, signed_at: now - 7200)
    assert {:ok, claims.expires_at} == Playback.authorize(token, embed)

    expired = Phoenix.Token.sign(Endpoint, "media-playback-v1", %{claims | expires_at: now - 1})
    assert {:error, :unauthorized} == Playback.authorize(expired, embed)
  end
end
