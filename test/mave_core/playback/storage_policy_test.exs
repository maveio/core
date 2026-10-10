defmodule MaveCore.Playback.StoragePolicyTest do
  use MaveCore.DataCase, async: false

  import Plug.Conn

  alias MaveCore.{Accounts, Embeds}
  alias MaveCore.Playback.Minio

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
end
