defmodule MaveCoreWeb.Api.Data.VideosControllerTest do
  use MaveCoreWeb.ConnCase

  alias MaveCore.Accounts
  alias MaveCore.Embeds
  alias MaveCore.Spaces

  setup do
    config = Application.get_env(:mave_core, MaveCore.ClickHouseRepo)
    db_name = config[:database] || "mave_metrics"
    MaveCore.ClickHouseRepo.query("TRUNCATE TABLE IF EXISTS #{db_name}.events")

    email = "api-video-data-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(email)
    space = user.current_space_membership.space
    {:ok, video} = Embeds.create_video_embed(space, %{name: "Data Video"})
    {:ok, key} = Spaces.create_key(space)

    auth =
      key
      |> then(&Spaces.display_api_key(&1.key, &1.secret))
      |> then(&"Bearer #{&1}")

    {:ok, db_name: db_name, space: space, video: video, auth: auth}
  end

  describe "GET /api/v1/videos/:embed_id/data" do
    test "historical outliers cannot inflate the per-second graph", context do
      %{db_name: db_name, space: space, video: video, auth: auth, conn: conn} = context
      embed_id = "#{space.hash}#{video.hash}"

      for duration <- [10, 1_000_000_000, -1, 14_401, "nan", "inf"] do
        {:ok, _} =
          MaveCore.ClickHouseRepo.query("""
          INSERT INTO #{db_name}.events
            (timestamp, name, session_id, space_hash, embed_hash, video_time, duration)
          VALUES (addSeconds(now64(6), -2), 'play', generateUUIDv4(),
            '#{space.hash}', '#{video.hash}', 0, #{duration})
          """)
      end

      conn =
        conn
        |> put_req_header("authorization", auth)
        |> get(~p"/api/v1/videos/#{embed_id}/data")

      assert %{"data" => %{"dropoff" => %{"duration_seconds" => 10, "per_second" => seconds}}} =
               json_response(conn, 200)

      assert length(seconds) == 10
    end

    test "unsupported-only durations return an empty graph", context do
      %{db_name: db_name, space: space, video: video, auth: auth, conn: conn} = context
      embed_id = "#{space.hash}#{video.hash}"

      {:ok, _} =
        MaveCore.ClickHouseRepo.query("""
        INSERT INTO #{db_name}.events
          (timestamp, name, session_id, space_hash, embed_hash, video_time, duration)
        VALUES (addSeconds(now64(6), -2), 'play', generateUUIDv4(),
          '#{space.hash}', '#{video.hash}', 0, 1000000000)
        """)

      conn =
        conn
        |> put_req_header("authorization", auth)
        |> get(~p"/api/v1/videos/#{embed_id}/data")

      assert %{"data" => %{"dropoff" => %{"duration_seconds" => 0, "per_second" => []}}} =
               json_response(conn, 200)
    end

    test "returns views + dropoff + sources for embed", %{
      conn: conn,
      db_name: db_name,
      space: space,
      video: video,
      auth: auth
    } do
      embed_id = "#{space.hash}#{video.hash}"

      sql = """
      INSERT INTO #{db_name}.events
      (timestamp, name, session_id, space_hash, embed_hash, video_time, duration, source_url, browser, browser_version, os, os_version, device, device_brand)
      VALUES
      (addSeconds(now64(6), -6), 'play',  '00000000-0000-0000-0000-000000000101', '#{space.hash}', '#{video.hash}', 0.0, 10, 'https://example.com/watch/abc', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple'),
      (addSeconds(now64(6), -2), 'pause', '00000000-0000-0000-0000-000000000101', '#{space.hash}', '#{video.hash}', 5.0, 10, 'https://example.com/watch/abc', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple'),
      (addSeconds(now64(6), -5), 'play',  '00000000-0000-0000-0000-000000000102', '#{space.hash}', '#{video.hash}', 0.0, 10, 'https://news.ycombinator.com/item?id=1', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple'),
      (addSeconds(now64(6), -1), 'pause', '00000000-0000-0000-0000-000000000102', '#{space.hash}', '#{video.hash}', 2.0, 10, 'https://news.ycombinator.com/item?id=1', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple')
      """

      {:ok, _} = MaveCore.ClickHouseRepo.query(sql)
      MaveCore.ClickHouseRepo.query("OPTIMIZE TABLE #{db_name}.events FINAL")

      conn =
        conn
        |> put_req_header("authorization", auth)
        |> get(~p"/api/v1/videos/#{embed_id}/data")

      assert %{
               "data" => %{
                 "id" => ^embed_id,
                 "views" => %{
                   "today" => today,
                   "month" => month,
                   "year" => year
                 },
                 "dropoff" => %{
                   "duration_seconds" => 10,
                   "per_second" => per_second
                 },
                 "sources" => sources
               }
             } = json_response(conn, 200)

      assert today >= 2
      assert month >= 2
      assert year >= 2

      assert is_list(per_second)
      assert is_list(sources)
      assert sources != []
      assert Enum.any?(sources, &(&1 == %{"path" => "example.com/watch/abc", "percentage" => 50}))

      assert Enum.any?(
               sources,
               &(&1 == %{"path" => "news.ycombinator.com/item", "percentage" => 50})
             )

      assert length(per_second) == 10
    end

    test "dropoff per_second does not count late-start sessions early", %{
      conn: conn,
      db_name: db_name,
      space: space,
      video: video,
      auth: auth
    } do
      embed_id = "#{space.hash}#{video.hash}"

      sql = """
      INSERT INTO #{db_name}.events
      (timestamp, name, session_id, space_hash, embed_hash, video_time, duration, source_url, browser, browser_version, os, os_version, device, device_brand)
      VALUES
      (addSeconds(now64(6), -30), 'play',  '00000000-0000-0000-0000-000000000201', '#{space.hash}', '#{video.hash}', 0.0, 14.2, 'https://example.com/a', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple'),
      (addSeconds(now64(6), -22), 'pause', '00000000-0000-0000-0000-000000000201', '#{space.hash}', '#{video.hash}', 8.0, 14.2, 'https://example.com/a', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple'),
      (addSeconds(now64(6), -21), 'play',  '00000000-0000-0000-0000-000000000201', '#{space.hash}', '#{video.hash}', 8.0, 14.2, 'https://example.com/a', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple'),
      (addSeconds(now64(6), -17), 'pause', '00000000-0000-0000-0000-000000000201', '#{space.hash}', '#{video.hash}', 12.0, 14.2, 'https://example.com/a', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple'),

      (addSeconds(now64(6), -16), 'play',  '00000000-0000-0000-0000-000000000202', '#{space.hash}', '#{video.hash}', 0.0, 14.2, 'https://example.com/b', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple'),
      (addSeconds(now64(6), -15), 'pause', '00000000-0000-0000-0000-000000000202', '#{space.hash}', '#{video.hash}', 1.0, 14.2, 'https://example.com/b', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple'),

      (addSeconds(now64(6), -10), 'play',  '00000000-0000-0000-0000-000000000203', '#{space.hash}', '#{video.hash}', 10.0, 14.2, 'https://example.com/c', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple'),
      (addSeconds(now64(6), -6),  'pause', '00000000-0000-0000-0000-000000000203', '#{space.hash}', '#{video.hash}', 14.2, 14.2, 'https://example.com/c', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple')
      """

      {:ok, _} = MaveCore.ClickHouseRepo.query(sql)
      MaveCore.ClickHouseRepo.query("OPTIMIZE TABLE #{db_name}.events FINAL")

      conn =
        conn
        |> put_req_header("authorization", auth)
        |> get(~p"/api/v1/videos/#{embed_id}/data")

      assert %{"data" => %{"dropoff" => %{"duration_seconds" => 15, "per_second" => per_second}}} =
               json_response(conn, 200)

      # Spot-check key seconds:
      # - second 0: sessions A+B
      # - second 1: session A only (because B ended exactly at 1.0)
      # - second 10: sessions A+C
      assert Enum.at(per_second, 0) == 2
      assert Enum.at(per_second, 1) == 1
      assert Enum.at(per_second, 10) == 2

      assert length(per_second) == 15
    end

    test "dropoff per_second counts resumed session once per second", %{
      conn: conn,
      db_name: db_name,
      space: space,
      video: video,
      auth: auth
    } do
      embed_id = "#{space.hash}#{video.hash}"

      sql = """
      INSERT INTO #{db_name}.events
      (timestamp, name, session_id, space_hash, embed_hash, video_time, duration, source_url, browser, browser_version, os, os_version, device, device_brand)
      VALUES
      (addSeconds(now64(6), -8), 'play',  '00000000-0000-0000-0000-000000000301', '#{space.hash}', '#{video.hash}', 0.0, 8.083333, 'https://example.com/resume', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple'),
      (addSeconds(now64(6), -7), 'pause', '00000000-0000-0000-0000-000000000301', '#{space.hash}', '#{video.hash}', 0.13333334, 8.083333, 'https://example.com/resume', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple'),
      (addSeconds(now64(6), -6), 'play',  '00000000-0000-0000-0000-000000000301', '#{space.hash}', '#{video.hash}', 0.2664196, 8.083333, 'https://example.com/resume', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple'),
      (addSeconds(now64(6), -2), 'pause', '00000000-0000-0000-0000-000000000301', '#{space.hash}', '#{video.hash}', 4.154774, 8.083333, 'https://example.com/resume', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple')
      """

      {:ok, _} = MaveCore.ClickHouseRepo.query(sql)
      MaveCore.ClickHouseRepo.query("OPTIMIZE TABLE #{db_name}.events FINAL")

      conn =
        conn
        |> put_req_header("authorization", auth)
        |> get(~p"/api/v1/videos/#{embed_id}/data")

      assert %{"data" => %{"views" => %{"year" => 1}, "dropoff" => %{"per_second" => per_second}}} =
               json_response(conn, 200)

      assert Enum.slice(per_second, 0, 5) == [1, 1, 1, 1, 1]
      assert Enum.all?(Enum.slice(per_second, 5, 4), &(&1 == 0))
    end

    test "invalid embed_id returns 404", %{conn: conn, auth: auth} do
      conn =
        conn
        |> put_req_header("authorization", auth)
        |> get(~p"/api/v1/videos/invalid/data")

      assert response(conn, 404)
    end

    test "cannot read another space's video data", %{conn: conn, auth: auth} do
      other_email = "api-video-data-other-#{System.unique_integer([:positive])}@example.com"
      {:ok, other_user} = Accounts.create_user(other_email)
      other_space = other_user.current_space_membership.space
      {:ok, other_video} = Embeds.create_video_embed(other_space, %{name: "Other Data Video"})

      conn =
        conn
        |> put_req_header("authorization", auth)
        |> get(~p"/api/v1/videos/#{other_space.hash <> other_video.hash}/data")

      assert %{"error" => "This video embed does not exist."} = json_response(conn, 404)
    end

    test "does not return analytics for a collection id", %{
      conn: conn,
      space: space,
      auth: auth
    } do
      {:ok, collection} = Embeds.create_folder_embed(space, %{name: "Data Folder"})

      conn =
        conn
        |> put_req_header("authorization", auth)
        |> get(~p"/api/v1/videos/#{space.hash <> collection.hash}/data")

      assert %{"error" => "This video embed does not seem to be part of your space."} =
               json_response(conn, 403)
    end

    test "missing auth returns 401", %{conn: conn, space: space} do
      embed_id = "#{space.hash}aaaaaaaaaa"
      conn = get(conn, ~p"/api/v1/videos/#{embed_id}/data")
      assert response(conn, 401)
    end
  end
end
