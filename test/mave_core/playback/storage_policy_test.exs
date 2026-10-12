defmodule MaveCore.Playback.StoragePolicyTest do
  use MaveCore.DataCase, async: false

  import Plug.Conn

  alias MaveCore.{Accounts, Embeds, Playback}
  alias MaveCore.Assets.Video
  alias MaveCore.Playback.Minio
  alias MaveCore.Workers.PlaybackVisibilityWorker

  setup {Req.Test, :verify_on_exit!}

  setup do
    previous = Application.get_env(:mave_core, :playback_adapter)
    previous_req = Req.default_options()
    Application.put_env(:mave_core, :playback_adapter, Minio)
    Req.default_options(plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Req.default_options(previous_req)

      if previous,
        do: Application.put_env(:mave_core, :playback_adapter, previous),
        else: Application.delete_env(:mave_core, :playback_adapter)
    end)

    {:ok, user} =
      Accounts.create_user("storage-policy-#{System.unique_integer([:positive])}@example.com")

    %{space: user.current_space_membership.space}
  end

  test "new private embeds protect their empty prefix before media exists", %{space: space} do
    {:ok, public} = Embeds.create_video_embed(space)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "PUT"
      assert conn.query_string == "policy"
      {:ok, body, conn} = read_body(conn)
      resources = Jason.decode!(body)["Statement"] |> hd() |> Map.fetch!("Resource")
      assert Enum.any?(resources, &String.ends_with?(&1, "/#{public.hash}/*"))
      send(self(), {:policy_resources, resources})
      send_resp(conn, 200, "")
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "PUT"
      assert conn.query_string == "cors"
      send_resp(conn, 200, "")
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "HEAD"
      assert String.ends_with?(conn.request_path, "/manifest.json")
      send_resp(conn, 404, "")
    end)

    assert {:ok, private} = Embeds.create_video_embed(space, %{visibility: :private})
    assert private.playback_status == :private
    assert is_nil(private.asset.current_video_id)
    assert_receive {:policy_resources, resources}
    refute Enum.any?(resources, &String.ends_with?(&1, "/#{private.hash}/*"))
  end

  test "empty embeds can transition from public to private and back", %{space: space} do
    {:ok, embed} = Embeds.create_video_embed(space)
    assert is_nil(embed.asset.current_video_id)

    for {visibility, pending} <- [private: :protecting, public: :publishing] do
      expect_storage_sync(embed, visibility, 404)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, updated} = Playback.request_visibility(embed, visibility)
        assert updated.playback_status == pending
      end)

      assert :ok = PlaybackVisibilityWorker.perform(%Oban.Job{args: %{"embed_id" => embed.id}})
      updated = Repo.reload!(embed)
      assert updated.playback_visibility == visibility
      assert updated.playback_status == visibility
    end
  end

  test "a missing manifest still fails verification when a current video exists", %{space: space} do
    {:ok, embed} = Embeds.create_video_embed(space)
    video = %Video{} |> Video.changeset(%{asset_id: embed.asset_id}) |> Repo.insert!()
    embed.asset |> change(current_video_id: video.id) |> Repo.update!()
    embed = Repo.reload!(embed) |> Repo.preload(:space)

    for visibility <- [:private, :public] do
      expect_storage_sync(embed, visibility, 404)

      assert {:error, :playback_storage_verification_failed} =
               Minio.apply_visibility(embed, visibility)
    end
  end

  test "empty embeds do not ignore storage authorization failures", %{space: space} do
    {:ok, embed} = Embeds.create_video_embed(space)
    expect_storage_sync(embed, :public, 403)

    assert {:error, :playback_storage_verification_failed} =
             Minio.apply_visibility(embed, :public)
  end

  defp expect_storage_sync(embed, visibility, manifest_status) do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "PUT"
      assert conn.query_string == "policy"
      {:ok, body, conn} = read_body(conn)
      resources = Jason.decode!(body)["Statement"] |> hd() |> Map.fetch!("Resource")

      assert Enum.any?(resources, &String.ends_with?(&1, "/#{embed.hash}/*")) ==
               (visibility == :public)

      send_resp(conn, 200, "")
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "PUT"
      assert conn.query_string == "cors"
      send_resp(conn, 200, "")
    end)

    Req.Test.expect(__MODULE__, if(manifest_status == 403, do: 4, else: 1), fn conn ->
      assert conn.method == "HEAD"
      assert String.ends_with?(conn.request_path, "/#{embed.hash}/manifest.json")
      send_resp(conn, manifest_status, "")
    end)
  end
end
