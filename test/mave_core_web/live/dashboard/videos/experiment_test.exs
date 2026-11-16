defmodule MaveCoreWeb.Live.Dashboard.Videos.ExperimentTest do
  use MaveCoreWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias MaveCore.Accounts
  alias MaveCore.Assets.{Asset, Video}
  alias MaveCore.ClickHouseRepo
  alias MaveCore.Embeds.Embed
  alias MaveCore.Experiments
  alias MaveCore.Experiments.Experiment
  alias MaveCore.Repo
  alias MaveCore.Spaces.Space
  alias MaveCore.TestSupport.FlowStorageAdapterStub

  defmodule Storage do
    def update_embed_visibility(_space, _embed_hash, _visibility, _region), do: :ok
  end

  @settings %{"metric" => "watch_time", "duration_days" => 7, "min_views" => 30}

  setup %{conn: conn} do
    old_storage_adapter = Application.get_env(:mave_core, :flow_storage_adapter)
    old_storage_module = Application.get_env(:mave_core, :storage_module)
    Application.put_env(:mave_core, :flow_storage_adapter, FlowStorageAdapterStub)
    Application.put_env(:mave_core, :storage_module, __MODULE__.Storage)
    FlowStorageAdapterStub.reset!()
    ClickHouseRepo.query!("TRUNCATE TABLE events")

    on_exit(fn ->
      restore_env(:flow_storage_adapter, old_storage_adapter)
      restore_env(:storage_module, old_storage_module)
      FlowStorageAdapterStub.reset!()
      ClickHouseRepo.query!("TRUNCATE TABLE events")
    end)

    {conn, space} = authenticated_conn(conn)

    %{
      conn: conn,
      space: space,
      host: video_embed_fixture(space, "Product tour"),
      challenger: video_embed_fixture(space, "Shorter cut")
    }
  end

  test "a test is set up from the video page and splits the embed page", context do
    %{conn: conn, space: space, host: host, challenger: challenger} = context
    video_embed_fixture(space, "Shorter private cut", playback_visibility: :private)

    {:ok, view, _html} = live(conn, ~p"/videos/#{host.id}")
    view |> element("#video-experiment-setup") |> render_click()

    view |> element("#video-experiment-search") |> render_change(%{"query" => "Shorter"})

    # Only videos that every viewer can play are offered.
    assert has_element?(view, "#video-experiment-suggestion-#{challenger.id}")
    assert view |> element("#video-experiment-suggestions") |> render() =~ "Shorter cut"
    refute view |> element("#video-experiment-suggestions") |> render() =~ "private"

    view |> element("#video-experiment-suggestion-#{challenger.id}") |> render_click()

    view
    |> form("#video-experiment-settings", %{
      "experiment" => %{
        "metric" => "completion_rate",
        "duration_days" => "10",
        "min_views" => "50"
      }
    })
    |> render_submit()

    assert view |> element("#video-experiment-status") |> render() =~ "Test running"
    assert has_element?(view, "#video-experiment-variant-A", "Product tour")
    assert has_element?(view, "#video-experiment-variant-B", "Shorter cut")

    assert %Experiment{status: :running, metric: :completion_rate, min_views: 50} =
             experiment = Experiments.current(host)

    assert DateTime.diff(experiment.ends_at, experiment.started_at, :day) == 10

    page = player_page(space, host)
    assert page =~ space.hash <> host.hash
    assert page =~ space.hash <> challenger.hash
  end

  test "a test needs another video and valid settings", %{conn: conn, host: host} do
    {:ok, view, _html} = live(conn, ~p"/videos/#{host.id}")
    view |> element("#video-experiment-setup") |> render_click()

    html =
      view
      |> form("#video-experiment-settings", %{"experiment" => %{"duration_days" => "0"}})
      |> render_change()

    assert html =~ "must be greater than or equal to 1"

    view |> form("#video-experiment-settings") |> render_submit()

    assert view |> element("#video-experiment-error") |> render() =~
             "Add at least one other video"

    assert Experiments.current(host) == nil
  end

  test "a private video explains why it cannot be tested", %{conn: conn, space: space} do
    private = video_embed_fixture(space, "Internal", playback_visibility: :private)

    {:ok, view, _html} = live(conn, ~p"/videos/#{private.id}")

    assert view |> element("#video-experiment") |> render() =~ "need public playback"
    refute has_element?(view, "#video-experiment-setup")
  end

  test "a running test shows what viewers of the embed page did", context do
    %{conn: conn, space: space, host: host, challenger: challenger} = context
    start_an_hour_ago(host, [challenger.id])
    insert_views(space, host, host, 1..40, watch: 10, reach: 12)
    insert_views(space, host, challenger, 101..140, watch: 30, reach: 38)

    {:ok, view, _html} = live(conn, ~p"/videos/#{host.id}")

    original = view |> element("#video-experiment-variant-A") |> render()
    assert original =~ "10.0 s"
    assert original =~ "0.0%"

    shorter = view |> element("#video-experiment-variant-B") |> render()
    assert shorter =~ "30.0 s"
    assert shorter =~ "100.0%"
    assert shorter =~ "leading"
  end

  test "an unclear result waits for a decision and is not locked silently", context do
    %{conn: conn, space: space, host: host, challenger: challenger} = context
    start_an_hour_ago(host, [challenger.id])
    insert_views(space, host, host, 1..5, watch: 10, reach: 12)
    insert_views(space, host, challenger, 101..105, watch: 30, reach: 38)

    {:ok, view, _html} = live(conn, ~p"/videos/#{host.id}")
    assert view |> element("#video-experiment-status") |> render() =~ "Test running"

    # The scheduled evaluation updates the open page.
    end_period()
    Experiments.evaluate_due()
    render(view)

    assert view |> element("#video-experiment-status") |> render() =~ "Needs your decision"
    assert view |> element("#video-experiment-decision") |> render() =~ "Too few viewers"
    assert view |> element("#video-experiment-decision") |> render() =~ "5 of the 30 views"
    assert player_page(space, host) =~ space.hash <> challenger.hash

    view |> element("#video-experiment-extend") |> render_click()

    assert view |> element("#video-experiment-status") |> render() =~ "Test running"
    assert %Experiment{status: :running} = Experiments.current(host)
  end

  test "a video picked by hand locks the embed until the lock is removed", context do
    %{conn: conn, space: space, host: host, challenger: challenger} = context
    start_an_hour_ago(host, [challenger.id])
    end_period()
    Experiments.evaluate_due()

    {:ok, view, _html} = live(conn, ~p"/videos/#{host.id}")
    view |> element("#video-experiment-lock-B") |> render_click()

    assert view |> element("#video-experiment-status") |> render() =~ "Locked to video B"
    assert view |> element("#video-experiment-overview") |> render() =~ "Chosen by hand"
    assert has_element?(view, "#video-experiment-variant-B", "winner")
    refute has_element?(view, "#video-experiment-lock-A")

    page = player_page(space, host)
    assert page =~ ~s(embed="#{space.hash}#{challenger.hash}")
    refute page =~ space.hash <> host.hash

    view |> element("#video-experiment-unlock") |> render_click()

    assert view |> element("#video-experiment-status") |> render() =~ "lock removed"
    assert player_page(space, host) =~ ~s(embed="#{space.hash}#{host.hash}")
    assert has_element?(view, "#video-experiment-setup")
  end

  test "a clear result is locked automatically", context do
    %{conn: conn, space: space, host: host, challenger: challenger} = context
    start_an_hour_ago(host, [challenger.id])
    insert_views(space, host, host, 1..40, watch: 10, reach: 12)
    insert_views(space, host, challenger, 101..140, watch: 30, reach: 38)
    end_period()
    Experiments.evaluate_due()

    {:ok, view, _html} = live(conn, ~p"/videos/#{host.id}")

    assert view |> element("#video-experiment-status") |> render() =~ "Locked to video B"
    assert view |> element("#video-experiment-overview") |> render() =~ "Decided automatically"
    assert view |> element("#video-experiment-variant-B") |> render() =~ "30.0 s"
    assert player_page(space, host) =~ ~s(embed="#{space.hash}#{challenger.hash}")
  end

  test "stopping a test returns the embed to the original", context do
    %{conn: conn, space: space, host: host, challenger: challenger} = context
    start_an_hour_ago(host, [challenger.id])

    {:ok, view, _html} = live(conn, ~p"/videos/#{host.id}")
    view |> element("#video-experiment-stop") |> render_click()

    assert view |> element("#video-experiment-status") |> render() =~ "stopped without a winner"
    refute player_page(space, host) =~ space.hash <> challenger.hash
  end

  # Moves the end of every test period into the past, as if the days went by.
  defp end_period do
    Repo.update_all(Experiment, set: [ends_at: DateTime.add(DateTime.utc_now(), -1, :second)])
  end

  # Starts a test and moves its start back so the inserted views fall inside it.
  defp start_an_hour_ago(host, challenger_ids) do
    {:ok, experiment} = Experiments.start(host, challenger_ids, @settings)

    from(e in Experiment, where: e.id == ^experiment.id)
    |> Repo.update_all(set: [started_at: DateTime.add(DateTime.utc_now(), -1, :hour)])
  end

  defp player_page(%Space{} = space, %Embed{} = embed) do
    {:ok, page} =
      FlowStorageAdapterStub.get("space-#{space.hash}", "#{embed.hash}/player.html", space.region)

    page
  end

  # One play/pause pair per session sent from `page`'s iframe embed page,
  # watching `watch` seconds and reaching second `reach` of 40.
  defp insert_views(space, %Embed{} = page, %Embed{} = played, sessions, opts) do
    source_url = "https://cdn.example.com/space-#{space.hash}/#{page.hash}/player.html"
    watch = Keyword.fetch!(opts, :watch)
    reach = Keyword.fetch!(opts, :reach)

    rows =
      Enum.flat_map(sessions, fn index ->
        session =
          "00000000-0000-0000-0000-" <> String.pad_leading(Integer.to_string(index), 12, "0")

        for {name, offset, video_time} <- [{"play", 0, 0}, {"pause", watch, reach}] do
          [
            "(addSeconds(now64(6), #{offset - watch - 5}), '#{name}', ",
            "'#{session}', '#{space.hash}', '#{played.hash}', #{video_time}, 40, ",
            "'#{source_url}', 'Chrome', '100', 'Mac', '14', 'Desktop', 'Apple')"
          ]
          |> IO.iodata_to_binary()
        end
      end)

    ClickHouseRepo.query!("""
    INSERT INTO events
    (timestamp, name, session_id, space_hash, embed_hash, video_time, duration, source_url,
     browser, browser_version, os, os_version, device, device_brand)
    VALUES #{Enum.join(rows, ",\n")}
    """)
  end

  defp authenticated_conn(conn) do
    email = "experiment-live-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(email)
    login_token = Accounts.generate_user_login_token(user)
    {:ok, {logged_in_user, persisted_login_token}} = Accounts.login_user(login_token)
    session_token = Accounts.generate_user_session_token(persisted_login_token, logged_in_user)

    conn =
      conn
      |> with_manage_host()
      |> init_test_session(user_token: session_token)

    {conn, logged_in_user.current_space_membership.space}
  end

  defp with_manage_host(conn) do
    case System.get_env("MAVE_MANAGE_HOST") do
      host when is_binary(host) and host != "" -> %{conn | host: host}
      _ -> conn
    end
  end

  defp video_embed_fixture(%Space{} = space, name, opts \\ []) do
    asset = Repo.insert!(%Asset{space_id: space.id, name: name})

    video =
      Repo.insert!(%Video{
        asset_id: asset.id,
        status: "ready",
        file_name: "#{name}.mp4",
        max_width: 1920,
        max_height: 1080,
        duration: 40.0,
        aspect_ratio: "16/9"
      })

    asset |> Ecto.Changeset.change(current_video_id: video.id) |> Repo.update!()
    visibility = Keyword.get(opts, :playback_visibility, :public)

    Repo.insert!(%Embed{
      space_id: space.id,
      asset_id: asset.id,
      hash: unique_hash(),
      type: :video,
      playback_visibility: visibility,
      playback_status: visibility
    })
  end

  defp unique_hash do
    alphabet = ~c"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    for _ <- 1..10, into: "", do: <<Enum.random(alphabet)>>
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)
end
