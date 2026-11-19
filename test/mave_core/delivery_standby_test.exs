defmodule MaveCore.DeliveryStandbyTest do
  use MaveCore.DataCase, async: false

  import Plug.Conn

  alias MaveCore.{Accounts, DeliveryStandby, Embeds}
  alias MaveCore.DeliveryStandby.{CLI, Report}
  alias MaveCore.Media.Storage
  alias MaveCore.Repo

  @moduletag :integration

  setup do
    previous = Application.get_env(:mave_core, :delivery_standby)
    unique = System.unique_integer([:positive])

    standby =
      :mave_core
      |> Application.get_env(:s3)
      |> Map.new()
      |> Map.merge(%{bucket_prefix: "standby-#{unique}-"})

    Application.put_env(:mave_core, :delivery_standby,
      storage: standby,
      status_bucket: "standby-status-#{unique}"
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:mave_core, :delivery_standby, previous),
        else: Application.delete_env(:mave_core, :delivery_standby)
    end)

    {:ok, user} =
      Accounts.create_user("delivery-standby-#{unique}@example.com")

    space = user.current_space_membership.space
    {:ok, public} = Embeds.create_video_embed(space)
    {:ok, private} = Embeds.create_video_embed(space)
    private = set_visibility(private, :private)

    bucket = Storage.bucket_for_space(space.hash)
    :ok = Storage.ensure_bucket(bucket)

    for key <- [
          "#{public.hash}/manifest.json",
          "#{public.hash}/v1/video.mp4",
          "#{private.hash}/manifest.json",
          "themes/player/default.css",
          "stray.txt"
        ] do
      put!(bucket, key, "primary:#{key}")
    end

    %{
      space: space,
      public: public,
      private: private,
      bucket: bucket,
      standby: standby,
      standby_bucket: DeliveryStandby.bucket_for_space(space.hash, standby)
    }
  end

  test "sync copies public media only and check then reports the standby ready", context do
    %{space: space, public: public, standby: standby, standby_bucket: standby_bucket} = context

    assert {:ok, report} = DeliveryStandby.sync(space: space.hash)
    assert [%{copied: 3, revoked: 0, failed: 0, error: nil}] = report.spaces
    refute report.status_written

    assert keys(standby_bucket, standby) ==
             Enum.sort([
               "#{public.hash}/manifest.json",
               "#{public.hash}/v1/video.mp4",
               "themes/player/default.css"
             ])

    assert {:ok, "primary:" <> _key} =
             Storage.get(standby_bucket, "#{public.hash}/manifest.json", standby)

    assert {:ok, %{spaces: [%{copied: 0, current: 3}]}} = DeliveryStandby.sync(space: space.hash)

    assert {:ok, check} = DeliveryStandby.check(space: space.hash)
    assert [%{current: 3, missing: 0, stale: 0, not_public: 0}] = check.spaces
    assert Enum.map(check.findings, & &1.code) == [:never_synced, :edge_not_configured]
    refute check.ready?
  end

  test "a complete sync stores its status and makes the check pass" do
    assert {:ok, %{status_written: true}} = DeliveryStandby.sync()

    assert {:ok, %{"finished_at" => _time, "totals" => %{"failed" => 0}}} =
             DeliveryStandby.last_sync()

    assert {:ok, check} = DeliveryStandby.check()
    assert check.ready?
    assert Enum.map(check.findings, & &1.code) == [:edge_not_configured]
    assert Report.check(check) =~ "READY: delivery can be switched to the standby."

    assert {:ok, stale} = DeliveryStandby.check(max_age_seconds: -1)
    refute stale.ready?
    assert :sync_too_old in Enum.map(stale.findings, & &1.code)
  end

  test "media that turned private is flagged and removed by the next sync", context do
    %{space: space, public: public, standby: standby, standby_bucket: standby_bucket} = context

    assert {:ok, _report} = DeliveryStandby.sync()
    set_visibility(public, :private)

    assert {:ok, check} = DeliveryStandby.check(space: space.hash)
    refute check.ready?
    assert :not_public_on_standby in Enum.map(check.findings, & &1.code)

    assert {:ok, %{spaces: [%{revoked: 2}]}} = DeliveryStandby.sync(space: space.hash)
    assert keys(standby_bucket, standby) == ["themes/player/default.css"]
  end

  test "changed and deleted primary objects are brought over", context do
    %{space: space, public: public, bucket: bucket, standby: standby} = context
    %{standby_bucket: standby_bucket} = context

    assert {:ok, _report} = DeliveryStandby.sync(space: space.hash)

    put!(bucket, "#{public.hash}/manifest.json", "a newer and longer manifest")
    :ok = Storage.delete_object(bucket, "#{public.hash}/v1/video.mp4")

    assert {:ok, %{spaces: [%{stale: 1, orphaned: 1, copied: 0}]}} =
             DeliveryStandby.sync(space: space.hash, dry_run: true)

    assert {:ok, %{spaces: [%{copied: 1, orphans_deleted: 1}]}} =
             DeliveryStandby.sync(space: space.hash)

    assert {:ok, "a newer and longer manifest"} =
             Storage.get(standby_bucket, "#{public.hash}/manifest.json", standby)

    refute "#{public.hash}/v1/video.mp4" in keys(standby_bucket, standby)
  end

  test "a primary that lost most of its media does not empty the standby", context do
    %{space: space, public: public, bucket: bucket, standby: standby} = context
    %{standby_bucket: standby_bucket} = context

    segments = for index <- 1..24, do: "#{public.hash}/v1/segment-#{index}.ts"
    Enum.each(segments, &put!(bucket, &1, "segment"))
    assert {:ok, _report} = DeliveryStandby.sync(space: space.hash)

    Enum.each(segments, &(:ok = Storage.delete_object(bucket, &1)))

    assert {:ok, %{spaces: [%{orphans_held: 24, orphans_deleted: 0, warnings: [warning]}]}} =
             DeliveryStandby.sync(space: space.hash)

    assert warning =~ "force_deletes"
    assert length(keys(standby_bucket, standby)) == 27

    assert {:ok, %{spaces: [%{orphans_deleted: 24}]}} =
             DeliveryStandby.sync(space: space.hash, force_deletes: true)

    assert length(keys(standby_bucket, standby)) == 3
  end

  test "check requests public URLs from the standby edge under the public hostname", context do
    %{space: space, public: public, private: private} = context
    configure_edge("https://standby-edge.example.test")
    assert {:ok, _report} = DeliveryStandby.sync()
    test_pid = self()

    edge = fn conn ->
      [public_host] = get_req_header(conn, "host")

      send(
        test_pid,
        {:edge_request, public_host, conn.request_path, get_req_header(conn, "range")}
      )

      private_path = "/#{private.hash}/manifest.json"

      case {conn.request_path, get_req_header(conn, "range")} do
        {^private_path, _range} ->
          send_resp(conn, 403, "")

        {path, ["bytes=0-0"]} ->
          size = byte_size("primary:" <> String.trim_leading(path, "/"))

          conn
          |> put_resp_header("content-range", "bytes 0-0/#{size}")
          |> send_resp(206, "p")

        {path, []} ->
          conn
          |> put_resp_header("access-control-allow-origin", "*")
          |> send_resp(200, "primary:" <> String.trim_leading(path, "/"))
      end
    end

    assert {:ok, check} =
             DeliveryStandby.check(space: space.hash, probe_req_options: [plug: edge])

    assert check.findings == []
    assert check.ready?
    assert [%{probes_passed: 3}] = check.spaces

    public_host = "space-#{space.hash}.video-dns.com"
    manifest_path = "/#{public.hash}/manifest.json"
    assert_received {:edge_request, ^public_host, ^manifest_path, []}
    assert_received {:edge_request, ^public_host, ^manifest_path, ["bytes=0-0"]}

    leaking = fn conn ->
      conn
      |> put_resp_header("content-range", "bytes 0-0/1")
      |> send_resp(200, "served")
    end

    assert {:ok, failing} =
             DeliveryStandby.check(space: space.hash, probe_req_options: [plug: leaking])

    refute failing.ready?
    codes = Enum.map(failing.findings, & &1.code)
    assert :not_public_served in codes
    assert :public_media_differs in codes
    assert :range_requests_unsupported in codes
  end

  test "the command line reports a missing configuration" do
    Application.delete_env(:mave_core, :delivery_standby)

    refute DeliveryStandby.configured?()
    assert {:error, message} = CLI.run(["check"])
    assert message =~ "MAVE_DELIVERY_STANDBY_S3_ENDPOINT"
    assert {:error, "Usage:" <> _usage} = CLI.run(["switch"])
  end

  defp configure_edge(url) do
    config = Application.get_env(:mave_core, :delivery_standby)
    Application.put_env(:mave_core, :delivery_standby, Keyword.put(config, :edge_url, url))
  end

  defp set_visibility(embed, visibility) do
    embed
    |> Ecto.Changeset.change(playback_visibility: visibility, playback_status: visibility)
    |> Repo.update!()
  end

  defp put!(bucket, key, body) do
    {:ok, _response} = Storage.put(bucket, key, body, "text/plain")
  end

  defp keys(bucket, profile) do
    {:ok, objects} = Storage.list_objects(bucket, "", profile)
    objects |> Enum.map(& &1.key) |> Enum.sort()
  end
end
