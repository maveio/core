defmodule MaveCore.Experiments do
  @moduledoc """
  A/B tests that compare several videos behind one embed.

  A test belongs to one video embed. Its variants are videos from the same
  space; the embed's own video is always variant A. While a test runs, the
  embed's iframe page gives each viewer one variant at random. After the
  configured period the test is evaluated once: with enough evidence the embed
  is locked to the winner, otherwise the test stays open until someone decides.

  See `docs/ab_testing.md` for scope and `MaveCore.Experiments.Stats` for the
  decision rule.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias MaveCore.Assets.Video
  alias MaveCore.Embeds
  alias MaveCore.Embeds.{Embed, Events, PlayerPublisher, SettingsSerializer}
  alias MaveCore.Experiments.{Experiment, Metrics, Stats, Variant}
  alias MaveCore.Media.{CdnCache, Storage}
  alias MaveCore.Repo
  alias MaveCore.Spaces.Space
  alias MaveCore.Workers.ExperimentWorker

  @max_variants 4
  @open_statuses [:running, :needs_decision]
  @variant_preload [variants: [embed: [asset: [:current_video]]]]

  def max_variants, do: @max_variants

  @doc "Settings for a new test, as a changeset for the setup form."
  def change_settings(attrs \\ %{}) do
    Experiment.settings_changeset(
      %Experiment{metric: :watch_time, duration_days: 14, min_views: 100},
      attrs
    )
  end

  @doc """
  The test that currently decides what `embed` plays, or else its most recent
  ended test.
  """
  @spec current(Embed.t()) :: Experiment.t() | nil
  def current(%Embed{id: embed_id}) do
    from(e in Experiment,
      where: e.embed_id == ^embed_id,
      order_by: [asc: e.status == :ended, desc: e.started_at],
      limit: 1,
      preload: ^@variant_preload
    )
    |> Repo.one()
  end

  @doc "Whether a video can host a test or take part in one as a variant."
  @spec eligible?(Embed.t()) :: :ok | {:error, :not_ready | :private | :audio_only}
  def eligible?(%Embed{type: :video, deleted_at: nil} = embed) do
    embed = Repo.preload(embed, asset: [:current_video])

    case embed.asset do
      %{current_video: %Video{status: status} = video} when status in ["ready", "playable"] ->
        cond do
          MaveCore.Playback.protected?(embed) -> {:error, :private}
          is_nil(video.max_width) or is_nil(video.max_height) -> {:error, :audio_only}
          true -> :ok
        end

      _ ->
        {:error, :not_ready}
    end
  end

  def eligible?(_embed), do: {:error, :not_ready}

  @doc "Videos matching `query` that could be added to a test on `host`."
  @spec search_candidates(Space.t(), Embed.t(), String.t(), [String.t()]) :: [map()]
  def search_candidates(%Space{} = space, %Embed{} = host, query, exclude_ids \\ []) do
    excluded = MapSet.new([host.id | exclude_ids])
    suggestions = Embeds.search_video_suggestions(space, query, limit: 8)

    eligible_ids =
      from(e in Embed,
        where: e.space_id == ^space.id and e.id in ^Enum.map(suggestions, & &1.uuid),
        preload: [asset: [:current_video]]
      )
      |> Repo.all()
      |> Enum.filter(&(eligible?(&1) == :ok))
      |> MapSet.new(& &1.id)

    Enum.filter(suggestions, &(&1.uuid in eligible_ids and &1.uuid not in excluded))
  end

  @doc """
  Starts a test on `host` against the videos in `variant_embed_ids`.

  Viewers of the iframe embed are split across the variants from the moment
  this returns.
  """
  @spec start(Embed.t(), [String.t()], map()) ::
          {:ok, Experiment.t()} | {:error, Ecto.Changeset.t() | atom()}
  def start(%Embed{} = host, variant_embed_ids, attrs) when is_list(variant_embed_ids) do
    host = Repo.preload(host, [:space, asset: [:current_video]])
    now = DateTime.utc_now()
    changeset = Experiment.settings_changeset(%Experiment{}, attrs)

    with :ok <- eligible?(host),
         {:ok, challengers} <- fetch_challengers(host, variant_embed_ids),
         {:ok, settings} <- Ecto.Changeset.apply_action(changeset, :insert) do
      experiment =
        changeset
        |> Ecto.Changeset.change(%{
          space_id: host.space_id,
          embed_id: host.id,
          status: :running,
          started_at: now,
          ends_at: DateTime.add(now, settings.duration_days, :day)
        })

      Multi.new()
      |> Multi.insert(:experiment, experiment)
      |> Multi.run(:variants, fn repo, %{experiment: experiment} ->
        insert_variants(repo, experiment, [host | challengers])
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{experiment: experiment}} -> published(experiment)
        {:error, :experiment, changeset, _changes} -> {:error, changeset}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  # The tested embed's own video is always variant A.
  defp insert_variants(repo, experiment, embeds) do
    embeds
    |> Enum.with_index()
    |> Enum.each(fn {embed, position} ->
      repo.insert!(%Variant{experiment_id: experiment.id, embed_id: embed.id, position: position})
    end)

    {:ok, nil}
  end

  defp fetch_challengers(host, ids) do
    ids = ids |> Enum.uniq() |> Enum.reject(&(&1 == host.id))

    embeds =
      from(e in Embed,
        where: e.space_id == ^host.space_id and e.id in ^ids and is_nil(e.deleted_at),
        preload: [asset: [:current_video]]
      )
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    challengers = Enum.map(ids, &Map.get(embeds, &1))

    cond do
      challengers == [] -> {:error, :no_variants}
      length(challengers) > @max_variants - 1 -> {:error, :too_many_variants}
      Enum.any?(challengers, &is_nil/1) -> {:error, :variant_not_found}
      Enum.any?(challengers, &(eligible?(&1) != :ok)) -> {:error, :variant_not_playable}
      true -> {:ok, challengers}
    end
  rescue
    Ecto.Query.CastError -> {:error, :variant_not_found}
  end

  @doc """
  Per-variant metrics and the current reading of the evidence.

  A decided or stopped test reports the numbers stored at that moment.
  """
  @spec report(Experiment.t()) :: {:ok, map()} | {:error, :analytics_unavailable}
  def report(%Experiment{status: status, results: %{} = results} = experiment)
      when status in [:locked, :ended] do
    {:ok, build_report(experiment, stored_metrics(experiment, results))}
  end

  def report(%Experiment{} = experiment) do
    with {:ok, metrics} <- live_metrics(experiment, DateTime.utc_now()) do
      {:ok, build_report(experiment, metrics)}
    end
  end

  defp live_metrics(%Experiment{} = experiment, now) do
    experiment = Repo.preload(experiment, [:space, :embed, variants: :embed])
    hashes = Enum.map(experiment.variants, & &1.embed.hash)

    with {:ok, by_hash} <-
           Metrics.variants(
             experiment.space.hash,
             experiment.embed.hash,
             hashes,
             experiment.started_at,
             experiment.ended_at || now
           ) do
      {:ok, Map.new(experiment.variants, &{&1.id, Map.fetch!(by_hash, &1.embed.hash)})}
    end
  end

  defp stored_metrics(experiment, results) do
    Map.new(experiment.variants, fn variant ->
      stored = Map.get(results, variant.id, %{})

      {variant.id,
       %{
         views: stored["views"] || 0,
         watch_seconds: (stored["watch_seconds"] || 0) * 1.0,
         watch_variance: (stored["watch_variance"] || 0) * 1.0,
         completions: stored["completions"] || 0
       }}
    end)
  end

  defp build_report(experiment, metrics) do
    rows =
      Enum.map(experiment.variants, fn variant ->
        metrics |> Map.fetch!(variant.id) |> Map.put(:id, variant.id)
      end)

    evaluation = Stats.evaluate(rows, experiment.metric, experiment.min_views)

    %{
      evaluation: evaluation,
      variants:
        Enum.map(rows, fn row ->
          Map.merge(row, %{
            value: Stats.value(row, experiment.metric),
            completion_rate: Stats.value(row, :completion_rate),
            leader: evaluation.leader_id == row.id
          })
        end)
    }
  end

  @doc "Evaluates every running test whose period is over."
  @spec evaluate_due(DateTime.t()) :: :ok
  def evaluate_due(now \\ DateTime.utc_now()) do
    from(e in Experiment, where: e.status == :running and e.ends_at <= ^now, select: e.id)
    |> Repo.all()
    |> Enum.each(fn id ->
      case Repo.get(Experiment, id) do
        %Experiment{} = experiment -> evaluate(experiment, now)
        nil -> :ok
      end
    end)
  end

  @doc """
  Ends the test period: locks the embed to the winner when the evidence is
  sufficient, and otherwise leaves the test open for a decision. Analytics
  outages leave the test untouched so the next round can retry.
  """
  @spec evaluate(Experiment.t(), DateTime.t()) ::
          {:ok, Experiment.t()} | {:error, :analytics_unavailable | :not_running}
  def evaluate(%Experiment{} = experiment, now \\ DateTime.utc_now()) do
    experiment = Repo.preload(experiment, @variant_preload)

    with {:ok, metrics} <- live_metrics(experiment, now) do
      case build_report(experiment, metrics).evaluation.outcome do
        {:winner, variant_id} ->
          transition(experiment, [:running], %{
            status: :locked,
            winner_variant_id: variant_id,
            decided_by: :automatic,
            outcome_reason: nil,
            ended_at: now,
            results: snapshot(metrics)
          })

        {:inconclusive, reason} ->
          transition(experiment, [:running], %{status: :needs_decision, outcome_reason: reason})
      end
    end
  end

  @doc "Keeps an open test running for another `days` days before it is evaluated again."
  @spec extend(Experiment.t(), pos_integer()) :: {:ok, Experiment.t()} | {:error, :not_running}
  def extend(%Experiment{} = experiment, days) when is_integer(days) and days in 1..90 do
    now = DateTime.utc_now()
    from = if DateTime.compare(experiment.ends_at, now) == :gt, do: experiment.ends_at, else: now

    transition(experiment, @open_statuses, %{
      status: :running,
      outcome_reason: nil,
      ends_at: DateTime.add(from, days, :day)
    })
  end

  @doc "Locks the embed to a variant chosen by a person."
  @spec choose_winner(Experiment.t(), String.t()) ::
          {:ok, Experiment.t()} | {:error, :not_running | :variant_not_found}
  def choose_winner(%Experiment{} = experiment, variant_id) do
    experiment = Repo.preload(experiment, @variant_preload)

    if Enum.any?(experiment.variants, &(&1.id == variant_id)) do
      decide(experiment, %{status: :locked, winner_variant_id: variant_id, decided_by: :manual})
    else
      {:error, :variant_not_found}
    end
  end

  @doc "Stops an open test without a winner. The embed plays its own video again."
  @spec stop(Experiment.t()) :: {:ok, Experiment.t()} | {:error, :not_running}
  def stop(%Experiment{} = experiment),
    do: decide(Repo.preload(experiment, @variant_preload), %{status: :ended})

  @doc "Removes the lock of a decided test. The embed plays its own video again."
  @spec unlock(Experiment.t()) :: {:ok, Experiment.t()} | {:error, :not_running}
  def unlock(%Experiment{} = experiment), do: transition(experiment, [:locked], %{status: :ended})

  defp decide(experiment, changes) do
    now = DateTime.utc_now()

    results =
      case live_metrics(experiment, now) do
        {:ok, metrics} -> snapshot(metrics)
        {:error, _reason} -> nil
      end

    transition(experiment, @open_statuses, Map.merge(changes, %{ended_at: now, results: results}))
  end

  defp snapshot(metrics) do
    Map.new(metrics, fn {variant_id, row} ->
      {variant_id, Map.new(row, fn {key, value} -> {Atom.to_string(key), value} end)}
    end)
  end

  # The status guard makes concurrent decisions safe: only the first one applies.
  defp transition(%Experiment{id: id}, from_statuses, changes) do
    changes = Map.put(changes, :updated_at, DateTime.utc_now())

    from(e in Experiment, where: e.id == ^id and e.status in ^from_statuses)
    |> Repo.update_all(set: Map.to_list(changes))
    |> case do
      {1, _} -> published(Repo.get!(Experiment, id))
      {0, _} -> {:error, :not_running}
    end
  end

  defp published(%Experiment{} = experiment) do
    experiment = Repo.preload(experiment, [:embed | @variant_preload], force: true)

    # The decision is already stored. A storage outage must not undo it, so the
    # embed page is retried in the background until it reflects the decision.
    with {:error, _reason} <- publish_player(experiment.embed) do
      %{"publish_embed_id" => experiment.embed_id}
      |> ExperimentWorker.new(schedule_in: 30)
      |> Oban.insert()
    end

    Events.broadcast_updated(experiment.space_id, experiment.embed_id, %{"action" => "experiment"})

    {:ok, experiment}
  end

  @doc "Publishes the iframe page of `embed` so it reflects the embed's current test."
  @spec publish_player(Embed.t()) :: :ok | {:error, term()}
  def publish_player(%Embed{} = embed) do
    embed = Repo.preload(embed, :space)
    space = embed.space
    storage = Application.get_env(:mave_core, :flow_storage_adapter, Storage)
    bucket = Storage.bucket_for_space(space.hash, space.region)

    with {:ok, _output} <-
           PlayerPublisher.publish(storage, bucket, space.hash, embed.hash, 0, space.region) do
      CdnCache.purge_best_effort(space.hash, space.region, ["#{embed.hash}/player.html"])
    end
  end

  @doc """
  Ends tests that can no longer run because `embed` was deleted: tests hosted
  on it, tests locked to it, and open tests left with a single variant.
  """
  @spec embed_deleted(Embed.t()) :: :ok
  def embed_deleted(%Embed{id: embed_id}) do
    from(e in Experiment,
      left_join: v in assoc(e, :variants),
      where: e.status in ^Experiment.active_statuses(),
      where: e.embed_id == ^embed_id or v.embed_id == ^embed_id,
      distinct: true,
      preload: [:embed, :winner_variant, variants: :embed]
    )
    |> Repo.all()
    |> Enum.each(fn experiment ->
      remaining = Enum.count(experiment.variants, &is_nil(&1.embed.deleted_at))

      cond do
        experiment.embed_id == embed_id ->
          end_without_publishing(experiment)

        experiment.status == :locked and experiment.winner_variant.embed_id != embed_id ->
          :ok

        experiment.status == :locked or remaining < 2 ->
          transition(experiment, Experiment.active_statuses(), %{
            status: :ended,
            ended_at: experiment.ended_at || DateTime.utc_now()
          })

        true ->
          publish_player(experiment.embed)
      end
    end)
  end

  defp end_without_publishing(%Experiment{id: id} = experiment) do
    from(e in Experiment, where: e.id == ^id)
    |> Repo.update_all(set: [status: :ended, ended_at: experiment.ended_at || DateTime.utc_now()])
  end

  @doc """
  What the iframe page of an embed should play, for `PlayerPublisher`.

  Returns `%{id: id, variants: public_ids}` while viewers are being split,
  `%{locked: public_id}` once another video won, and `nil` for the embed's own
  video. Variants that can no longer be played publicly are left out.
  """
  @spec player_state(String.t(), String.t()) :: map() | nil
  def player_state(space_hash, embed_hash) when is_binary(space_hash) and is_binary(embed_hash) do
    from(e in Experiment,
      join: host in assoc(e, :embed),
      join: space in assoc(e, :space),
      where: space.hash == ^space_hash and host.hash == ^embed_hash,
      where: e.status in ^Experiment.active_statuses(),
      preload: [space: space, variants: [embed: [asset: [:current_video]]]]
    )
    |> Repo.one()
    |> case do
      %Experiment{status: :locked} = experiment -> locked_state(experiment)
      %Experiment{} = experiment -> split_state(experiment)
      nil -> nil
    end
  end

  defp locked_state(experiment) do
    case Enum.find(experiment.variants, &(&1.id == experiment.winner_variant_id)) do
      %Variant{position: position, embed: embed} when position > 0 ->
        if eligible?(embed) == :ok, do: %{locked: public_id(experiment.space, embed)}

      _original ->
        nil
    end
  end

  defp split_state(experiment) do
    case Enum.filter(experiment.variants, &(eligible?(&1.embed) == :ok)) do
      [_, _ | _] = playable ->
        %{id: experiment.id, variants: Enum.map(playable, &public_id(experiment.space, &1.embed))}

      _too_few ->
        nil
    end
  end

  defp public_id(space, embed), do: SettingsSerializer.public_embed_id(space, embed)
end
