defmodule MaveCore.ExperimentsTest do
  use MaveCore.DataCase, async: false

  alias MaveCore.Accounts
  alias MaveCore.Assets.{Asset, Video}
  alias MaveCore.ClickHouseRepo
  alias MaveCore.Embeds
  alias MaveCore.Embeds.Embed
  alias MaveCore.Embeds.PlayerPublisher
  alias MaveCore.Experiments
  alias MaveCore.Experiments.Experiment
  alias MaveCore.Spaces.Space
  alias MaveCore.TestSupport.FlowStorageAdapterStub
  alias MaveCore.Workers.ExperimentWorker

  @settings %{"metric" => "watch_time", "duration_days" => 7, "min_views" => 30}

  setup do
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

    space = space_fixture()

    %{
      space: space,
      host: video_embed_fixture(space, "Original"),
      challenger: video_embed_fixture(space, "Shorter cut")
    }
  end

  defmodule Storage do
    def update_embed_visibility(_space, _embed_hash, _visibility, _region), do: :ok
  end

  describe "start/3" do
    test "splits iframe viewers across the original and its challengers", context do
      %{space: space, host: host, challenger: challenger} = context

      assert {:ok, experiment} = Experiments.start(host, [challenger.id], @settings)

      assert experiment.status == :running
      assert experiment.metric == :watch_time
      assert DateTime.diff(experiment.ends_at, experiment.started_at, :day) == 7
      assert Enum.map(experiment.variants, & &1.embed_id) == [host.id, challenger.id]

      page = player_page(space, host)

      assert page =~
               ~s("variants":["#{space.hash}#{host.hash}","#{space.hash}#{challenger.hash}"])

      assert page =~ ~s("id":"#{experiment.id}")
      assert page =~ "window.localStorage"
      refute page =~ "<mave-player"

      assert Experiments.current(host).id == experiment.id
    end

    test "rejects a second test on the same embed", %{host: host, challenger: challenger} do
      assert {:ok, _experiment} = Experiments.start(host, [challenger.id], @settings)
      assert {:error, changeset} = Experiments.start(host, [challenger.id], @settings)
      assert "already has an A/B test" in errors_on(changeset).embed_id
    end

    test "rejects variants that cannot play publicly in this space", context do
      %{space: space, host: host, challenger: challenger} = context
      other_space_video = video_embed_fixture(space_fixture(), "Elsewhere")
      processing = video_embed_fixture(space, "Processing", status: "preparing")
      audio = video_embed_fixture(space, "Podcast", max_width: nil, max_height: nil)
      private = video_embed_fixture(space, "Private", playback_visibility: :private)

      assert {:error, :no_variants} = Experiments.start(host, [], @settings)
      assert {:error, :no_variants} = Experiments.start(host, [host.id], @settings)
      assert {:error, :variant_not_found} = Experiments.start(host, ["nope"], @settings)

      assert {:error, :variant_not_found} =
               Experiments.start(host, [other_space_video.id], @settings)

      for embed <- [processing, audio, private] do
        assert {:error, :variant_not_playable} = Experiments.start(host, [embed.id], @settings)
      end

      too_many = for index <- 1..4, do: video_embed_fixture(space, "Cut #{index}").id
      assert {:error, :too_many_variants} = Experiments.start(host, too_many, @settings)

      assert {:error, :private} = Experiments.start(private, [challenger.id], @settings)
      assert Repo.aggregate(Experiment, :count) == 0
    end

    test "validates the settings", %{host: host, challenger: challenger} do
      assert {:error, changeset} =
               Experiments.start(host, [challenger.id], %{
                 "metric" => "clicks",
                 "duration_days" => 0,
                 "min_views" => 5
               })

      assert %{metric: [_], duration_days: [_], min_views: [_]} = errors_on(changeset)
    end
  end

  describe "report/1" do
    test "counts only views that came through the tested embed", context do
      %{space: space, host: host, challenger: challenger} = context
      experiment = start_an_hour_ago(host, [challenger.id])

      # Through the test: 40 views of each variant.
      insert_views(space, host, host, 1..40, watch: 10, reach: 10)
      insert_views(space, host, challenger, 41..80, watch: 20, reach: 38)
      # The challenger embedded on its own page, and the host on a website.
      insert_views(space, challenger, challenger, 81..120, watch: 40, reach: 40)
      insert_views(space, "https://example.com/pricing", host, 121..160, watch: 40, reach: 40)
      # Before the test started.
      insert_views(space, host, host, 161..170, watch: 40, reach: 40, seconds_ago: 7_200)

      assert {:ok, %{variants: [original, shorter], evaluation: evaluation}} =
               Experiments.report(experiment)

      assert %{views: 40, completions: 0, leader: false} = original
      assert_in_delta original.value, 10.0, 0.01
      assert %{views: 40, completions: 40, leader: true} = shorter
      assert_in_delta shorter.value, 20.0, 0.01
      assert shorter.completion_rate == 1.0
      assert evaluation.outcome == {:winner, Enum.at(experiment.variants, 1).id}
    end

    test "reports variants without views", %{host: host, challenger: challenger} do
      {:ok, experiment} = Experiments.start(host, [challenger.id], @settings)

      assert {:ok, %{variants: [%{views: 0, value: +0.0}, %{views: 0}], evaluation: evaluation}} =
               Experiments.report(experiment)

      assert evaluation.outcome == {:inconclusive, :insufficient_views}
    end
  end

  describe "evaluate_due/1" do
    test "locks the embed to the winner once the period is over", context do
      %{space: space, host: host, challenger: challenger} = context
      experiment = start_an_hour_ago(host, [challenger.id])
      insert_views(space, host, host, 1..40, watch: 10, reach: 10)
      insert_views(space, host, challenger, 41..80, watch: 20, reach: 38)

      # Nothing happens while the test period is running.
      assert :ok = Experiments.evaluate_due()
      assert Repo.get!(Experiment, experiment.id).status == :running

      end_period()
      assert :ok = ExperimentWorker.perform(%Oban.Job{args: %{}})

      locked = Experiments.current(host)
      assert locked.status == :locked
      assert locked.decided_by == :automatic
      assert locked.winner_variant_id == Enum.at(experiment.variants, 1).id
      assert locked.ended_at

      # The same embed code now plays the winning video for everyone.
      page = player_page(space, host)
      assert page =~ ~s(<mave-player embed="#{space.hash}#{challenger.hash}")
      refute page =~ "experiment"

      # Views after the decision do not change the stored result.
      insert_views(space, host, host, 81..200, watch: 40, reach: 40)

      assert {:ok, %{variants: [%{views: 40}, %{views: 40, leader: true}]}} =
               Experiments.report(locked)
    end

    test "keeps the test open when there are too few viewers", context do
      %{space: space, host: host, challenger: challenger} = context
      experiment = start_an_hour_ago(host, [challenger.id])
      insert_views(space, host, host, 1..5, watch: 10, reach: 10)
      insert_views(space, host, challenger, 6..10, watch: 30, reach: 38)

      assert :ok = evaluate_after_period()

      open = Experiments.current(host)
      assert open.status == :needs_decision
      assert open.outcome_reason == :insufficient_views
      assert is_nil(open.winner_variant_id)
      assert is_nil(open.ended_at)
      assert open.id == experiment.id

      # Viewers are still split, and evaluating again changes nothing.
      assert player_page(space, host) =~ ~s("id":"#{experiment.id}")
      assert :ok = Experiments.evaluate_due()
      assert Experiments.current(host).status == :needs_decision
    end

    test "keeps the test open when the difference is not clear", context do
      %{space: space, host: host, challenger: challenger} = context
      start_an_hour_ago(host, [challenger.id])
      insert_views(space, host, host, 1..40, watch: 20, reach: 20)
      insert_views(space, host, challenger, 41..79, watch: 20, reach: 20)
      insert_views(space, host, challenger, 80..80, watch: 21, reach: 20)

      assert :ok = evaluate_after_period()

      assert %{status: :needs_decision, outcome_reason: :no_clear_difference} =
               Experiments.current(host)
    end

    test "leaves the test alone while analytics cannot answer", context do
      %{host: host, challenger: challenger} = context
      {:ok, experiment} = Experiments.start(host, [challenger.id], @settings)
      ClickHouseRepo.query!("RENAME TABLE events TO events_unavailable")
      on_exit(fn -> ClickHouseRepo.query("RENAME TABLE events_unavailable TO events") end)

      assert {:error, :analytics_unavailable} = Experiments.evaluate(experiment)

      assert {:error, :analytics_unavailable} = Experiments.report(experiment)
      assert Repo.get!(Experiment, experiment.id).status == :running
    end
  end

  describe "decisions on an open test" do
    setup %{space: space, host: host, challenger: challenger} do
      experiment = start_an_hour_ago(host, [challenger.id])
      insert_views(space, host, host, 1..5, watch: 10, reach: 10)
      :ok = evaluate_after_period()
      %{experiment: Repo.get!(Experiment, experiment.id)}
    end

    test "extending resumes the test for the chosen number of days", context do
      %{experiment: experiment, host: host} = context

      assert {:ok, extended} = Experiments.extend(experiment, 7)
      assert extended.status == :running
      assert is_nil(extended.outcome_reason)
      assert_in_delta DateTime.diff(extended.ends_at, DateTime.utc_now(), :hour), 7 * 24, 1
      assert {:ok, later} = Experiments.extend(extended, 7)
      assert_in_delta DateTime.diff(later.ends_at, DateTime.utc_now(), :hour), 14 * 24, 1
      assert Experiments.current(host).status == :running
    end

    test "a person can lock any variant", %{experiment: experiment, space: space, host: host} do
      [_original, shorter] = Repo.preload(experiment, variants: :embed).variants

      assert {:error, :variant_not_found} = Experiments.choose_winner(experiment, experiment.id)
      assert {:ok, locked} = Experiments.choose_winner(experiment, shorter.id)
      assert %{status: :locked, decided_by: :manual} = locked
      assert locked.winner_variant_id == shorter.id

      assert player_page(space, host) =~
               ~s(<mave-player embed="#{space.hash}#{shorter.embed.hash}")

      assert {:ok, %{variants: [%{views: 5}, %{views: 0}]}} = Experiments.report(locked)
      assert {:error, :not_running} = Experiments.stop(locked)
      assert {:error, :not_running} = Experiments.extend(locked, 7)
    end

    test "locking the original keeps the plain page", context do
      %{experiment: experiment, space: space, host: host} = context
      [original, _shorter] = Repo.preload(experiment, :variants).variants

      assert {:ok, %{status: :locked}} = Experiments.choose_winner(experiment, original.id)
      assert player_page(space, host) =~ ~s(<mave-player embed="#{space.hash}#{host.hash}")
    end

    test "stopping restores the original and frees the embed for a new test", context do
      %{experiment: experiment, space: space, host: host, challenger: challenger} = context

      assert {:ok, stopped} = Experiments.stop(experiment)
      assert %{status: :ended, winner_variant_id: nil} = stopped
      assert stopped.ended_at
      assert player_page(space, host) =~ ~s(<mave-player embed="#{space.hash}#{host.hash}")
      refute player_page(space, host) =~ "experiment"

      assert {:ok, next} = Experiments.start(host, [challenger.id], @settings)
      assert Experiments.current(host).id == next.id
    end

    test "removing a lock restores the original", context do
      %{experiment: experiment, space: space, host: host} = context
      [_original, shorter] = Repo.preload(experiment, :variants).variants
      {:ok, locked} = Experiments.choose_winner(experiment, shorter.id)

      assert {:ok, %{status: :ended, winner_variant_id: winner}} = Experiments.unlock(locked)
      assert winner == shorter.id
      assert player_page(space, host) =~ ~s(<mave-player embed="#{space.hash}#{host.hash}")
      assert {:error, :not_running} = Experiments.unlock(locked)
    end
  end

  describe "deleted videos" do
    test "a test ends when it is left with a single variant", context do
      %{space: space, host: host, challenger: challenger} = context
      {:ok, _experiment} = Experiments.start(host, [challenger.id], @settings)

      assert {:ok, _deleted} = Embeds.delete_embed(challenger)

      assert Experiments.current(host).status == :ended
      assert player_page(space, host) =~ ~s(<mave-player embed="#{space.hash}#{host.hash}")
    end

    test "a test continues with the remaining variants", context do
      %{space: space, host: host, challenger: challenger} = context
      third = video_embed_fixture(space, "Third cut")
      {:ok, _experiment} = Experiments.start(host, [challenger.id, third.id], @settings)

      assert {:ok, _deleted} = Embeds.delete_embed(third)

      assert Experiments.current(host).status == :running
      page = player_page(space, host)

      assert page =~
               ~s("variants":["#{space.hash}#{host.hash}","#{space.hash}#{challenger.hash}"])
    end

    test "a lock ends when the winning video is deleted", context do
      %{space: space, host: host, challenger: challenger} = context
      {:ok, experiment} = Experiments.start(host, [challenger.id], @settings)
      [_original, shorter] = experiment.variants
      {:ok, _locked} = Experiments.choose_winner(experiment, shorter.id)

      assert {:ok, _deleted} = Embeds.delete_embed(challenger)

      assert Experiments.current(host).status == :ended
      assert player_page(space, host) =~ ~s(<mave-player embed="#{space.hash}#{host.hash}")
    end

    test "deleting the tested video ends its test", %{host: host, challenger: challenger} do
      {:ok, experiment} = Experiments.start(host, [challenger.id], @settings)

      assert {:ok, _deleted} = Embeds.delete_embed(host)
      assert Repo.get!(Experiment, experiment.id).status == :ended
    end
  end

  test "a failed page upload is retried in the background", context do
    %{space: space, host: host, challenger: challenger} = context
    bucket = "space-#{space.hash}"
    FlowStorageAdapterStub.fail_public_put!(bucket, "#{host.hash}/player.html", space.region)

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, experiment} = Experiments.start(host, [challenger.id], @settings)
      assert experiment.status == :running

      assert [%Oban.Job{args: %{"publish_embed_id" => embed_id}} = job] =
               Repo.all(Oban.Job)

      assert embed_id == host.id

      FlowStorageAdapterStub.reset!()
      assert :ok = ExperimentWorker.perform(job)
      assert player_page(space, host) =~ ~s("id":"#{experiment.id}")
    end)
  end

  test "republishing the page from elsewhere keeps the test", context do
    %{space: space, host: host, challenger: challenger} = context
    {:ok, experiment} = Experiments.start(host, [challenger.id], @settings)

    assert {:ok, _output} =
             PlayerPublisher.publish(
               FlowStorageAdapterStub,
               "space-#{space.hash}",
               space.hash,
               host.hash,
               0,
               space.region
             )

    assert player_page(space, host) =~ ~s("id":"#{experiment.id}")
  end

  # Moves the end of every test period into the past, as if the days went by.
  defp end_period do
    Repo.update_all(Experiment, set: [ends_at: DateTime.add(DateTime.utc_now(), -1, :second)])
  end

  defp evaluate_after_period do
    end_period()
    Experiments.evaluate_due()
  end

  # Starts a test and moves its start back so the inserted views fall inside it.
  defp start_an_hour_ago(host, challenger_ids) do
    {:ok, experiment} = Experiments.start(host, challenger_ids, @settings)

    from(e in Experiment, where: e.id == ^experiment.id)
    |> Repo.update_all(set: [started_at: DateTime.add(DateTime.utc_now(), -1, :hour)])

    Experiments.current(host)
  end

  defp player_page(%Space{} = space, %Embed{} = embed) do
    {:ok, page} =
      FlowStorageAdapterStub.get("space-#{space.hash}", "#{embed.hash}/player.html", space.region)

    page
  end

  # One play/pause pair per session, sent from `page` (an embed's iframe page
  # or any other URL), watching `watch` seconds and reaching second `reach`.
  defp insert_views(space, page, %Embed{} = played, sessions, opts) do
    source_url =
      case page do
        %Embed{hash: hash} -> "https://cdn.example.com/space-#{space.hash}/#{hash}/player.html"
        url when is_binary(url) -> url
      end

    seconds_ago = Keyword.get(opts, :seconds_ago, 0)
    watch = Keyword.fetch!(opts, :watch)
    reach = Keyword.fetch!(opts, :reach)

    rows =
      Enum.flat_map(sessions, fn index ->
        session =
          "00000000-0000-0000-0000-" <> String.pad_leading(Integer.to_string(index), 12, "0")

        for {name, offset, video_time} <- [{"play", 0, 0}, {"pause", watch, reach}] do
          [
            "(addSeconds(now64(6), #{offset - seconds_ago - watch - 5}), '#{name}', ",
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

  defp space_fixture do
    {:ok, user} =
      Accounts.create_user("experiments-#{System.unique_integer([:positive])}@example.com")

    user.current_space_membership.space
  end

  defp video_embed_fixture(%Space{} = space, name, opts \\ []) do
    asset = Repo.insert!(%Asset{space_id: space.id, name: name})

    video =
      Repo.insert!(%Video{
        asset_id: asset.id,
        status: Keyword.get(opts, :status, "ready"),
        file_name: "#{name}.mp4",
        max_width: Keyword.get(opts, :max_width, 1920),
        max_height: Keyword.get(opts, :max_height, 1080),
        duration: 40.0
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
