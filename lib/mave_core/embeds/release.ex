defmodule MaveCore.Embeds.Release do
  @moduledoc """
  Scheduled video releases.

  A scheduled release keeps every object under the embed prefix private until
  `release_at`. Scheduling requests private playback through the configured
  `MaveCore.Playback.Adapter`, so manifests, playlists, renditions, frames and
  downloads are denied by storage itself, not only hidden by the player.

  While a release is pending, public players receive `manifest/1` instead of
  the real manifest: settings, name and the release time for a countdown, but no
  media references. Customer playback JWTs are rejected for media; dashboard
  sessions keep working so owners can preview the video.

  At `release_at`, `MaveCore.Workers.ReleaseWorker` requests public playback.
  The pending release is cleared by `MaveCore.Workers.PlaybackVisibilityWorker`
  only after storage confirms public access, so players never see a gap between
  the countdown and the real manifest.
  """
  import Ecto.Query

  alias MaveCore.Assets.Video
  alias MaveCore.Embeds
  alias MaveCore.Embeds.{Embed, Events, SettingsSerializer}
  alias MaveCore.Playback
  alias MaveCore.Repo
  alias MaveCore.Spaces.Space
  alias MaveCore.Workers.{PlaybackVisibilityWorker, ReleaseWorker}

  @sweep_batch_size 100

  @type error ::
          :not_found
          | :release_in_past
          | :playback_unavailable
          | :playback_private
          | :not_scheduled

  @doc "Whether the embed has a release that has not completed yet."
  def pending?(%Embed{release_at: %DateTime{}}), do: true
  def pending?(_embed), do: false

  @doc "Whether a pending release has reached its release time."
  def due?(embed, now \\ DateTime.utc_now())

  def due?(%Embed{release_at: %DateTime{} = release_at}, now),
    do: DateTime.compare(release_at, now) != :gt

  def due?(_embed, _now), do: false

  @doc "Unix seconds of the pending release, or nil."
  def release_unix(%Embed{release_at: %DateTime{} = release_at}),
    do: DateTime.to_unix(release_at)

  def release_unix(_embed), do: nil

  @doc """
  Schedules or reschedules a release.

  Only public videos, or videos that already have a pending release, can be
  scheduled. Private (token) videos keep their own access model.
  """
  @spec schedule(Embed.t(), DateTime.t()) :: {:ok, Embed.t()} | {:error, error()}
  def schedule(%Embed{} = embed, %DateTime{} = release_at) do
    release_at = %{DateTime.truncate(release_at, :second) | microsecond: {0, 6}}

    if DateTime.compare(release_at, DateTime.utc_now()) == :gt do
      embed
      |> with_space_lock(fn space, current -> do_schedule(space, current, release_at) end)
      |> broadcast()
    else
      {:error, :release_in_past}
    end
  end

  defp do_schedule(space, %Embed{} = current, release_at) do
    if reason = schedule_error(space, current), do: Repo.rollback(reason)

    scheduled =
      current
      |> Ecto.Changeset.change(release_at: release_at)
      |> Repo.update!()

    protected =
      case Playback.request_visibility(scheduled, :private, release: true) do
        {:ok, protected} -> protected
        {:error, reason} -> Repo.rollback(reason)
      end

    %{embed_id: protected.id, release_at: DateTime.to_unix(release_at)}
    |> ReleaseWorker.new(scheduled_at: release_at)
    |> Oban.insert!()

    protected
  end

  defp schedule_error(space, %Embed{} = current) do
    cond do
      current.type != :video or not is_nil(current.deleted_at) ->
        :not_found

      not Playback.available?(space) ->
        :playback_unavailable

      pending?(current) ->
        nil

      current.playback_visibility != :public or current.playback_status != :public ->
        :playback_private

      true ->
        nil
    end
  end

  @doc "Releases a pending video immediately."
  @spec release_now(Embed.t()) :: {:ok, Embed.t()} | {:error, error()}
  def release_now(%Embed{} = embed) do
    embed
    |> with_space_lock(fn _space, current ->
      if pending?(current) do
        current
        |> Ecto.Changeset.change(release_at: DateTime.utc_now())
        |> Repo.update!()
        |> do_release_due()
      else
        Repo.rollback(:not_scheduled)
      end
    end)
    |> broadcast()
  end

  @doc """
  Starts the release when it is due. Safe to call repeatedly.

  Returns `{:ok, {:not_due, seconds}}` when the release time is still ahead.
  """
  def release_due(embed_id) when is_binary(embed_id) do
    case Repo.get(Embed, embed_id) do
      %Embed{} = embed ->
        embed
        |> with_space_lock(fn _space, current -> do_release_due(current) end)
        |> broadcast()

      nil ->
        {:ok, nil}
    end
  end

  defp do_release_due(%Embed{} = current) do
    now = DateTime.utc_now()

    cond do
      not pending?(current) or not is_nil(current.deleted_at) ->
        current

      not due?(current, now) ->
        {:not_due, max(DateTime.diff(current.release_at, now, :second), 1)}

      true ->
        publish(current)
    end
  end

  # The visibility worker clears `release_at` once storage is public. If that
  # job exhausted its retries (storage outage), queue it again so a due
  # release always completes once storage recovers.
  defp publish(%Embed{playback_status: :publishing} = current) do
    unless visibility_sync_queued?(current.id) do
      %{embed_id: current.id} |> PlaybackVisibilityWorker.new() |> Oban.insert!()
    end

    current
  end

  defp publish(%Embed{playback_visibility: :public, playback_status: :public} = current),
    do: current |> Ecto.Changeset.change(release_at: nil) |> Repo.update!()

  defp publish(%Embed{} = current) do
    case Playback.request_visibility(current, :public, release: true) do
      {:ok, updated} -> updated
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp visibility_sync_queued?(embed_id) do
    worker = Oban.Worker.to_string(PlaybackVisibilityWorker)

    Repo.exists?(
      from(j in Oban.Job,
        where:
          j.worker == ^worker and j.state in ~w(available scheduled executing retryable) and
            fragment("?->>'embed_id' = ?", j.args, ^embed_id)
      )
    )
  end

  @doc "IDs of releases that are due and have not completed."
  def due_embed_ids(limit \\ @sweep_batch_size) do
    now = DateTime.utc_now()

    Repo.all(
      from(e in Embed,
        where: not is_nil(e.release_at) and e.release_at <= ^now and is_nil(e.deleted_at),
        order_by: [asc: e.release_at],
        limit: ^limit,
        select: e.id
      )
    )
  end

  @doc """
  Public manifest for a pending release.

  It carries only presentation data and the release time. Generated thumbnails
  and frames come from the protected media, so only an uploaded custom poster
  (stored outside the embed prefix) is included.
  """
  def manifest(%Embed{} = embed) do
    embed = Repo.preload(embed, [:space, :settings, asset: [:current_video]])
    video = current_video(embed)
    settings = SettingsSerializer.manifest_settings(embed.settings)
    custom_poster? = settings["poster"] == "custom"

    poster =
      if custom_poster?,
        do: SettingsSerializer.manifest_poster(embed.space, embed, embed.settings, %{}),
        else: %{}

    %{
      "id" => SettingsSerializer.public_embed_id(embed.space, embed),
      "name" => name(embed, video),
      "space_id" => embed.space.hash,
      "created_at" => DateTime.to_unix(embed.inserted_at || DateTime.utc_now()),
      "release_at" => release_unix(embed),
      "server_time" => System.system_time(:second),
      "settings" => if(custom_poster?, do: settings, else: Map.put(settings, "poster", nil)),
      "poster" => %{
        "image_src" => poster["image_src"],
        "initial_frame_src" => poster["initial_frame_src"],
        "renditions" => [],
        "type" => nil,
        "video_src" => nil
      },
      "subtitles" => [],
      "audio_tracks" => [],
      "waveform" => nil,
      "video" => %{
        "id" => embed.hash,
        "version" => Embeds.current_video_version(embed),
        "audio" => nil,
        "aspect_ratio" => SettingsSerializer.video_aspect_ratio(video),
        "filetype" => filetype(video),
        "original" => nil,
        "size" => nil,
        "duration" => video && video.duration,
        "language" => nil,
        "status" => "scheduled",
        "ready" => false,
        "sources" => [],
        "renditions" => [],
        "src" => nil,
        "max_width" => video && video.max_width,
        "max_height" => video && video.max_height
      }
    }
  end

  defp with_space_lock(%Embed{} = embed, fun) do
    Repo.transaction(fn ->
      space = Repo.one!(from(s in Space, where: s.id == ^embed.space_id, lock: "FOR UPDATE"))
      fun.(space, Repo.get!(Embed, embed.id))
    end)
  end

  defp broadcast({:ok, %Embed{} = embed} = result) do
    Events.broadcast_updated(embed.space_id, embed.id)
    result
  end

  defp broadcast(result), do: result

  defp current_video(%Embed{asset: %{current_video: %Video{} = video}}), do: video
  defp current_video(_embed), do: nil

  defp name(%Embed{asset: %{name: name}}, _video) when is_binary(name) and name != "", do: name

  defp name(_embed, %Video{file_name: name}) when is_binary(name) and name != "", do: name
  defp name(%Embed{hash: hash}, _video), do: hash

  defp filetype(%Video{file_name: file_name}) when is_binary(file_name) and file_name != "" do
    case file_name |> Path.extname() |> String.trim_leading(".") do
      "" -> "mp4"
      ext -> String.downcase(ext)
    end
  end

  defp filetype(_video), do: "mp4"
end
