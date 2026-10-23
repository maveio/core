defmodule MaveCoreWeb.Api.Data.RangesControllerTest do
  use MaveCoreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias MaveCore.Accounts
  alias MaveCore.ClickHouseRepo
  alias MaveCore.Embeds
  alias MaveCore.Repo
  alias MaveCore.Spaces

  @range %{"from" => "2024-02-28", "to" => "2024-03-01"}

  setup %{conn: conn} do
    {:ok, _} = ClickHouseRepo.query("TRUNCATE TABLE events")
    {:ok, user} = Accounts.create_user("range-#{System.unique_integer([:positive])}@example.com")
    space = user.current_space_membership.space
    {:ok, video} = Embeds.create_video_embed(space, %{name: "A video, with \"quotes\""})
    {:ok, key} = Spaces.create_key(space, %{access_level: :read_only})
    auth = "Bearer " <> Spaces.display_api_key(key.key, key.secret)

    token = Accounts.generate_user_login_token(user)
    {:ok, {user, persisted}} = Accounts.login_user(token)
    session = Accounts.generate_user_session_token(persisted, user)
    browser_conn = init_test_session(conn, user_token: session)

    %{space: space, video: video, auth: auth, browser_conn: browser_conn}
  end

  test "both API versions expose additive ranges and preserve their legacy response", context do
    %{conn: conn, space: space, video: video, auth: auth} = context

    for prefix <- ["/api/v1", "/v1"],
        suffix <- ["spaces/#{space.hash}", "videos/#{space.hash <> video.hash}"] do
      path = "#{prefix}/#{suffix}/data"
      default_conn = conn |> put_req_header("authorization", auth) |> get(path)
      default = json_response(default_conn, 200)["data"]
      refute Map.has_key?(default, "range")

      range_conn = conn |> recycle() |> put_req_header("authorization", auth) |> get(path, @range)
      data = json_response(range_conn, 200)["data"]
      assert Map.delete(data, "range") == default
      assert data["range"]["totals"]["views"] == 0

      assert Enum.map(data["range"]["series"], & &1["date"]) == [
               "2024-02-28",
               "2024-02-29",
               "2024-03-01"
             ]
    end
  end

  test "both endpoints return 422 for invalid range combinations", context do
    %{conn: conn, space: space, video: video, auth: auth} = context

    for suffix <- ["spaces/#{space.hash}", "videos/#{space.hash <> video.hash}"],
        params <- [%{"from" => "2024-01-01"}, Map.put(@range, "granularity", "hour")] do
      result =
        conn
        |> recycle()
        |> put_req_header("authorization", auth)
        |> get("/v1/#{suffix}/data", params)

      assert %{"error" => _} = json_response(result, 422)
    end
  end

  test "CSV includes archived and zero-view videos, excludes deleted and other-tenant videos",
       context do
    %{browser_conn: conn, space: space, video: video} = context
    {:ok, archived} = Embeds.create_video_embed(space, %{name: "=SUM(A1)", archived: true})
    {:ok, deleted} = Embeds.create_video_embed(space, %{name: "Deleted"})
    deleted |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update!()

    {:ok, stranger} =
      Accounts.create_user("other-range-#{System.unique_integer([:positive])}@example.com")

    {:ok, _} =
      Embeds.create_video_embed(stranger.current_space_membership.space, %{name: "Other tenant"})

    result = get(conn, "/#{space.id}/data/export.csv", @range)
    assert result.status == 200
    assert result.state == :chunked
    assert get_resp_header(result, "content-type") == ["text/csv; charset=utf-8"]
    assert result.resp_body =~ "embed_id,title,views,watch_seconds,completion_rate\r\n"

    assert result.resp_body =~
             "#{space.hash <> video.hash}\",\"A video, with \"\"quotes\"\"\",0,0.0,"

    assert result.resp_body =~ "#{space.hash <> archived.hash}\",\"'=SUM(A1)\""
    refute result.resp_body =~ "Deleted"
    refute result.resp_body =~ "Other tenant"
  end

  test "CSV exports beyond a single 250-video batch", context do
    now = DateTime.utc_now()

    videos =
      Enum.map(1..251, fn index ->
        %{
          id: Ecto.UUID.generate(),
          hash: String.pad_leading(to_string(index), 10, "0"),
          space_id: context.space.id,
          type: :video,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(MaveCore.Embeds.Embed, videos)
    result = get(context.browser_conn, "/data/export.csv", @range)
    assert result.status == 200
    assert length(String.split(result.resp_body, "\r\n", trim: true)) == 253

    for video <- videos do
      assert result.resp_body =~ context.space.hash <> video.hash
    end
  end

  test "CSV requires membership, authentication and paired dates", context do
    %{conn: conn, browser_conn: browser, space: space} = context
    assert get(conn, "/data/export.csv", @range).status == 302
    assert get(browser, "/#{space.id}/data/export.csv").status == 422
    assert get(browser, "/invalid/data/export.csv", @range).status == 404
    assert get(browser, "/#{Ecto.UUID.generate()}/data/export.csv", @range).status in [403, 404]
  end

  test "blocked aggregate data permission also blocks CSV and range controls", context do
    old = Application.get_env(:mave_core, :usage_limits_backend)

    Application.put_env(
      :mave_core,
      :usage_limits_backend,
      MaveCore.TestSupport.AnalyticsUsageLimitStub
    )

    on_exit(fn ->
      if old,
        do: Application.put_env(:mave_core, :usage_limits_backend, old),
        else: Application.delete_env(:mave_core, :usage_limits_backend)
    end)

    assert get(context.browser_conn, "/data/export.csv", @range).status == 403
    {:ok, view, _} = live(context.browser_conn, "/data")
    refute has_element?(view, "#analytics-range-form")
  end

  test "Data page applies dates, renders leap-day buckets and links the same CSV range",
       context do
    {:ok, view, _} = live(context.browser_conn, "/#{context.space.id}/data")
    assert has_element?(view, "#analytics-range-form")
    view |> form("#analytics-range-form", range: @range) |> render_submit()
    _ = render_async(view, 10_000)
    assert has_element?(view, "#analytics-range-buckets", "2024-02-29")
    assert has_element?(view, "#analytics-csv-export[href*='from=2024-02-28']")
    view |> element("#analytics-range-reset") |> render_click()
    _ = render_async(view, 10_000)
    refute has_element?(view, "#analytics-range-totals")
  end
end
