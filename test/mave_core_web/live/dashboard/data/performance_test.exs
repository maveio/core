defmodule MaveCoreWeb.Live.Dashboard.Data.PerformanceTest do
  use MaveCoreWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MaveCore.Accounts
  alias MaveCore.ClickHouseRepo
  alias MaveCore.Embeds
  alias MaveCore.Metrics.CdnRequest
  alias MaveCore.Metrics.PlaybackQuality

  setup do
    db_name = ClickHouseRepo.config()[:database] || "mave_metrics"
    ClickHouseRepo.query("TRUNCATE TABLE IF EXISTS #{db_name}.playback_quality")
    ClickHouseRepo.query("TRUNCATE TABLE IF EXISTS #{db_name}.cdn_requests")
    {:ok, db_name: db_name}
  end

  test "the data page links to playback performance", %{conn: conn} do
    {conn, _space} = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, "/data")

    view |> element(~s(a[href="/data/performance"])) |> render_click()
    assert_patch(view, "/data/performance")
    assert has_element?(view, "#performance-experience")
  end

  test "explains what is missing before anything is measured", %{conn: conn} do
    {conn, _space} = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, "/data/performance")
    _ = render_async(view, 5_000)

    assert has_element?(view, "#performance-delivery-empty", "No delivery telemetry")
    assert has_element?(view, "#performance-findings-empty", "No playback measurements yet")
    refute has_element?(view, "#performance-delivery")
  end

  test "shows viewer experience next to delivery and names the cause", %{
    conn: conn,
    db_name: db_name
  } do
    {conn, space} = authenticated_conn(conn)
    {:ok, healthy} = Embeds.create_video_embed(space, %{name: "Healthy video"})
    {:ok, failing} = Embeds.create_video_embed(space, %{name: "Failing video"})
    now = DateTime.add(DateTime.utc_now(), -30, :second)

    # Sixty healthy plays, and thirty of another video of which half fail.
    plays =
      for number <- 1..90 do
        {embed, failed?} = if number <= 60, do: {healthy, false}, else: {failing, number > 75}

        [
          quality(space, embed, number, now, "playback_startup", %{startup_ms: 900}),
          quality(space, embed, number, now, "playback_sample", %{
            playing_ms: 30_000,
            bitrate: 4_000_000,
            height: 1080
          })
        ] ++
          if(failed?,
            do: [quality(space, embed, number, now, "playback_error", %{error_code: "E"})],
            else: []
          )
      end

    requests =
      for {embed, status, count} <- [{healthy, 200, 300}, {failing, 200, 80}, {failing, 503, 20}],
          _ <- 1..count do
        %{
          timestamp: now,
          space_hash: space.hash,
          embed_hash: embed.hash,
          status: status,
          cache_status: "hit",
          origin: 0,
          bytes: 1_000_000,
          ttfb_ms: 20,
          country: "NL",
          pop: "AMS"
        }
      end

    ClickHouseRepo.insert_all(PlaybackQuality, List.flatten(plays), prefix: db_name)
    ClickHouseRepo.insert_all(CdnRequest, requests, prefix: db_name)

    {:ok, view, _html} = live(conn, "/data/performance?period=year")
    _ = render_async(view, 5_000)

    assert has_element?(view, "#performance-experience", "900 ms")
    assert has_element?(view, "#performance-experience", "15 while playing")
    assert has_element?(view, "#performance-experience", "4,0 Mbps")
    assert has_element?(view, "#performance-delivery", "100%")
    assert has_element?(view, "#performance-delivery", "20 server")
    assert has_element?(view, "#performance-resolutions", "1080p")

    finding = "#performance-finding-video-#{failing.hash}"
    assert has_element?(view, finding, "Failing video")
    assert has_element?(view, finding, "50% of plays end in an error")
    assert has_element?(view, finding, "20% of its delivery requests fail")
    refute has_element?(view, "#performance-finding-video-#{healthy.hash}")

    row = "#performance-row-video-#{failing.hash}"
    assert has_element?(view, row <> ~s( a[href="/videos/#{Embeds.dashboard_embed_id(failing)}"]))
    assert has_element?(view, row <> ~s( [data-flagged="true"]), "50%")
    assert has_element?(view, row <> ~s( [data-flagged="true"]), "20%")

    # Regrouping keeps the period and reuses the loaded report.
    view
    |> element(~s(#performance-dimension-switch a[data-dimension="region"]))
    |> render_click()

    assert_patch(view, "/data/performance?period=year&by=region")
    assert has_element?(view, "#performance-row-region-NL", "90")
    refute has_element?(view, "#performance-history-loading")

    view
    |> element(~s(#performance-dimension-switch a[data-dimension="browser"]))
    |> render_click()

    assert has_element?(view, "#performance-row-browser-Chrome")
    refute has_element?(view, "#performance-breakdown", "CDN errors")
  end

  defp quality(space, embed, number, at, name, measurements) do
    Map.merge(
      %{
        timestamp: at,
        name: name,
        session_id: "00000000-0000-4000-8000-#{String.pad_leading("#{number}", 12, "0")}",
        space_hash: space.hash,
        embed_hash: embed.hash,
        startup_ms: 0,
        rebuffer_ms: 0,
        playing_ms: 0,
        bitrate: 0,
        width: 0,
        height: 0,
        error_code: "",
        browser: "Chrome",
        os: "Mac",
        device: "desktop",
        country: "NL"
      },
      measurements
    )
  end

  defp authenticated_conn(conn) do
    email = "data-performance-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(email)
    login_token = Accounts.generate_user_login_token(user)
    {:ok, {logged_in_user, persisted_login_token}} = Accounts.login_user(login_token)
    session_token = Accounts.generate_user_session_token(persisted_login_token, logged_in_user)
    refreshed_user = Accounts.get_user_by_email(email)

    conn =
      case System.get_env("MAVE_MANAGE_HOST") do
        host when is_binary(host) and host != "" -> %{conn | host: host}
        _ -> conn
      end

    {init_test_session(conn, user_token: session_token),
     refreshed_user.current_space_membership.space}
  end
end
