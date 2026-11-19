defmodule MaveCore.LiveStreams do
  @moduledoc """
  Live streams: an encoder such as OBS publishes over RTMP, Core repackages the
  stream as HLS segments in the space's storage, and viewers play it through a
  public playlist. See `docs/live_streaming.md`.

  A stream is a reusable channel with a stable stream key and playback URL. A
  broadcast starts when an encoder connects and ends when it stays away longer
  than the reconnect window. Its recording remains playable until the next
  broadcast starts.
  """

  import Ecto.Query

  alias MaveCore.Embeds.SettingsSerializer
  alias MaveCore.LiveStreams.{Config, LiveStream, Playlist, Segment}
  alias MaveCore.Media.Storage
  alias MaveCore.Repo
  alias MaveCore.Spaces.Space
  alias MaveCore.UsageLimits

  @hash_chars "abcdefghijklmnopqrstuvwxyz0123456789"
  @hash_length 10
  @stale_heartbeat_seconds 45
  @ingest_fields ~w(width height framerate video_codec audio_codec video_bitrate audio_bitrate encoder)

  # ---------------------------------------------------------------------------
  # Availability
  # ---------------------------------------------------------------------------

  @doc "Whether this installation accepts live streams."
  def enabled?, do: Config.enabled?()

  @doc "Whether a space may use live streaming: the installation and the host allow it."
  def available?(%Space{} = space),
    do: enabled?() and UsageLimits.can_use_live_streaming?(space) == :ok

  def available?(_space), do: false

  # ---------------------------------------------------------------------------
  # Management
  # ---------------------------------------------------------------------------

  def list(%Space{id: space_id}) do
    from(s in LiveStream, where: s.space_id == ^space_id, order_by: [desc: s.inserted_at])
    |> Repo.all()
    |> Enum.map(&refresh_status/1)
  end

  @doc "Fetches a stream of a space by its id, hash or public id."
  def get(%Space{id: space_id, hash: space_hash}, identifier) when is_binary(identifier) do
    hash = String.replace_prefix(identifier, space_hash, "")

    query =
      case MaveCore.LegacyShortUUID.cast(identifier) do
        {:ok, id} -> from(s in LiveStream, where: s.id == ^id or s.hash == ^hash)
        _ -> from(s in LiveStream, where: s.hash == ^hash)
      end

    case Repo.one(from(s in query, where: s.space_id == ^space_id, limit: 1)) do
      %LiveStream{} = stream -> refresh_status(stream)
      nil -> nil
    end
  end

  def get(_space, _identifier), do: nil

  @doc "Fetches a stream and its space by the public id used in playback URLs."
  def get_by_public_id(public_id) when is_binary(public_id) do
    with {:ok, %{space_hash: space_hash, embed_hash: hash}} <- MaveCore.EmbedId.split(public_id),
         %LiveStream{} = stream <-
           Repo.one(
             from(s in LiveStream,
               join: space in assoc(s, :space),
               where: s.hash == ^hash and space.hash == ^space_hash and is_nil(space.deleted_at),
               preload: [space: space]
             )
           ) do
      refresh_status(stream)
    else
      _ -> nil
    end
  end

  def get_by_public_id(_public_id), do: nil

  def create(%Space{} = space, attrs \\ %{}) do
    if available?(space) do
      %LiveStream{space_id: space.id, hash: generate_hash(), stream_key: generate_stream_key()}
      |> LiveStream.create_changeset(attrs)
      |> Repo.insert()
      |> broadcast_change()
    else
      {:error, :live_streaming_unavailable}
    end
  end

  def change(%LiveStream{} = stream, attrs \\ %{}), do: LiveStream.update_changeset(stream, attrs)

  def update(%LiveStream{} = stream, attrs) do
    stream
    |> LiveStream.update_changeset(attrs)
    |> Repo.update()
    |> broadcast_change()
  end

  @doc "Replaces the stream key. An encoder that is connected keeps publishing."
  def reset_stream_key(%LiveStream{} = stream) do
    stream
    |> Ecto.Changeset.change(stream_key: generate_stream_key())
    |> Repo.update()
    |> broadcast_change()
  end

  @doc "Deletes a stream, disconnects its encoder and removes its media."
  def delete(%LiveStream{} = stream) do
    stream = Repo.preload(stream, :space)

    with {:ok, deleted} <- Repo.delete(stream) do
      Phoenix.PubSub.broadcast(MaveCore.PubSub, control_topic(stream.id), :live_stream_deleted)
      delete_media(stream.space, "live/#{stream.hash}/")
      broadcast_change({:ok, deleted})
    end
  end

  # ---------------------------------------------------------------------------
  # Ingest lifecycle
  # ---------------------------------------------------------------------------

  @doc "Resolves the stream an encoder may publish to with `stream_key`."
  def authenticate(stream_key) when is_binary(stream_key) and byte_size(stream_key) in 16..128 do
    case Repo.one(from(s in LiveStream, where: s.stream_key == ^stream_key, preload: [:space])) do
      %LiveStream{space: %Space{deleted_at: nil} = space} = stream ->
        if available?(space), do: {:ok, stream}, else: {:error, :unavailable}

      _ ->
        {:error, :unauthorized}
    end
  end

  def authenticate(_stream_key), do: {:error, :unauthorized}

  @doc """
  Marks a stream live for a connecting encoder.

  A connection within the reconnect window resumes the broadcast, and its first
  segment is marked as a discontinuity. Otherwise a new broadcast starts and
  the previous recording is removed.

  Returns the stream and where its next segment continues the playlist.
  """
  def begin_session(%LiveStream{id: id}) do
    now = DateTime.utc_now()

    {:ok, {stream, previous_broadcast}} =
      Repo.transaction(fn ->
        stream =
          Repo.one!(
            from(s in LiveStream, where: s.id == ^id, lock: "FOR UPDATE", preload: :space)
          )

        resume? = effective_status(stream, now) in [:live, :disconnected]

        changes =
          if resume? do
            [status: :live, disconnected_at: nil, heartbeat_at: now, last_error: nil]
          else
            [
              status: :live,
              broadcast: stream.broadcast + 1,
              target_duration: nil,
              ingest: nil,
              started_at: now,
              disconnected_at: nil,
              ended_at: nil,
              heartbeat_at: now,
              last_error: nil
            ]
          end

        previous = if resume?, do: nil, else: stream.broadcast
        {stream |> Ecto.Changeset.change(changes) |> Repo.update!(), previous}
      end)

    if previous_broadcast do
      Repo.delete_all(
        from(s in Segment, where: s.live_stream_id == ^id and s.broadcast <= ^previous_broadcast)
      )

      if previous_broadcast > 0,
        do: delete_media(stream.space, broadcast_prefix(stream, previous_broadcast))
    end

    last =
      Repo.one(
        from(s in Segment,
          where: s.live_stream_id == ^id,
          order_by: [desc: s.sequence],
          limit: 1
        )
      )

    broadcast_change({:ok, stream})

    {:ok, stream,
     %{
       next_sequence: if(last, do: last.sequence + 1, else: 0),
       discontinuity?: not is_nil(last),
       discontinuity_sequence: if(last, do: last.discontinuity_sequence, else: 0)
     }}
  end

  @doc "Stores what the encoder reports about itself."
  def put_ingest(%LiveStream{} = stream, %{} = ingest) do
    ingest =
      ingest
      |> Map.take(@ingest_fields)
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    stream
    |> Ecto.Changeset.change(ingest: ingest)
    |> Repo.update()
    |> broadcast_change()
  end

  @doc "Records a segment that is stored and ready to be listed in the playlist."
  def record_segment(%LiveStream{} = stream, %{} = attrs) do
    segment =
      Repo.insert!(%Segment{
        live_stream_id: stream.id,
        broadcast: stream.broadcast,
        sequence: attrs.sequence,
        duration: attrs.duration,
        key: attrs.key,
        size_bytes: attrs.size_bytes,
        discontinuity: attrs.discontinuity,
        discontinuity_sequence: attrs.discontinuity_sequence,
        program_date_time: attrs[:program_date_time]
      })

    target = max(stream.target_duration || 0, ceil(attrs.duration))

    stream =
      if target != stream.target_duration do
        stream |> Ecto.Changeset.change(target_duration: target) |> Repo.update!()
      else
        stream
      end

    {:ok, stream, segment}
  end

  @doc "Shows other nodes that the ingest session is still running."
  def heartbeat(%LiveStream{id: id}) do
    Repo.update_all(
      from(s in LiveStream, where: s.id == ^id and s.status == :live),
      [set: [heartbeat_at: DateTime.utc_now()]],
      log: false
    )

    :ok
  end

  @doc "Marks the encoder as gone. The broadcast ends after the reconnect window."
  def end_session(%LiveStream{id: id}, error \\ nil) do
    from(s in LiveStream, where: s.id == ^id and s.status == :live)
    |> Repo.update_all(
      set: [status: :disconnected, disconnected_at: DateTime.utc_now(), last_error: error]
    )

    notify(id)
  end

  @doc "Ends a broadcast whose encoder is gone without waiting for the reconnect window."
  def end_broadcast(%LiveStream{id: id}) do
    now = DateTime.utc_now()

    from(s in LiveStream, where: s.id == ^id and s.status == :disconnected)
    |> Repo.update_all(set: [status: :ended, ended_at: now, updated_at: now])

    notify(id)
  end

  @doc """
  Ends broadcasts whose reconnect window passed and releases streams whose
  ingest session stopped reporting. `local_session?` tells whether this node
  still runs a session for a stream id.
  """
  def sweep(local_session? \\ fn _id -> false end) do
    now = DateTime.utc_now()
    stale = DateTime.add(now, -@stale_heartbeat_seconds, :second)

    # The sweep runs every few seconds; keep it out of the query log.
    from(s in LiveStream, where: s.status == :live and s.heartbeat_at < ^stale, select: s.id)
    |> Repo.all(log: false)
    |> Enum.reject(local_session?)
    |> Enum.each(fn id ->
      from(s in LiveStream, where: s.id == ^id and s.status == :live and s.heartbeat_at < ^stale)
      |> Repo.update_all(set: [status: :disconnected, disconnected_at: now])

      notify(id)
    end)

    expired = DateTime.add(now, -Config.get(:reconnect_seconds), :second)

    from(s in LiveStream,
      where: s.status == :disconnected and s.disconnected_at <= ^expired,
      select: s.id
    )
    |> Repo.all(log: false)
    |> Enum.each(fn id ->
      from(s in LiveStream,
        where: s.id == ^id and s.status == :disconnected and s.disconnected_at <= ^expired
      )
      |> Repo.update_all(set: [status: :ended, ended_at: now, updated_at: now])

      notify(id)
    end)
  end

  # The sweeper only runs on ingest nodes. Readers apply the reconnect window
  # themselves so playback and the dashboard never depend on it.
  defp refresh_status(%LiveStream{} = stream) do
    case effective_status(stream, DateTime.utc_now()) do
      :ended when stream.status != :ended ->
        %{stream | status: :ended, ended_at: stream.disconnected_at}

      _ ->
        stream
    end
  end

  defp effective_status(%LiveStream{status: :disconnected, disconnected_at: at}, now)
       when not is_nil(at) do
    if DateTime.diff(now, at, :second) >= Config.get(:reconnect_seconds),
      do: :ended,
      else: :disconnected
  end

  defp effective_status(%LiveStream{status: status}, _now), do: status

  # ---------------------------------------------------------------------------
  # Playback
  # ---------------------------------------------------------------------------

  @doc """
  The HLS media playlist of the current broadcast: a sliding window while the
  broadcast runs and the complete recording once it ended. Segments are listed
  at their public media address, like the renditions of a video.
  """
  def playlist(%LiveStream{status: :idle}), do: {:error, :not_started}

  def playlist(%LiveStream{} = stream) do
    ended? = stream.status == :ended

    segments =
      from(s in Segment,
        where: s.live_stream_id == ^stream.id and s.broadcast == ^stream.broadcast
      )

    segments =
      if ended? do
        Repo.all(from(s in segments, order_by: [asc: s.sequence]))
      else
        from(s in segments, order_by: [desc: s.sequence], limit: ^Config.get(:playlist_segments))
        |> Repo.all()
        |> Enum.reverse()
      end

    case segments do
      [] when ended? ->
        {:error, :no_recording}

      [] ->
        {:error, :not_started}

      segments ->
        bucket = bucket(Repo.preload(stream, :space).space)
        url = &SettingsSerializer.storage_object_url(bucket, &1.key)
        {:ok, Playlist.render(stream, segments, ended?: ended?, url: url)}
    end
  end

  def segment_count(%LiveStream{id: id, broadcast: broadcast}) do
    Repo.aggregate(
      from(s in Segment, where: s.live_stream_id == ^id and s.broadcast == ^broadcast),
      :count
    )
  end

  @doc "Seconds of media recorded in the current broadcast."
  def recorded_seconds(%LiveStream{id: id, broadcast: broadcast}) do
    Repo.aggregate(
      from(s in Segment, where: s.live_stream_id == ^id and s.broadcast == ^broadcast),
      :sum,
      :duration
    ) || 0.0
  end

  # ---------------------------------------------------------------------------
  # Addresses
  # ---------------------------------------------------------------------------

  def public_id(%Space{hash: space_hash}, %LiveStream{hash: hash}), do: space_hash <> hash

  @doc "The RTMP server address to enter in the encoder."
  def ingest_url do
    case Config.get(:rtmp_url) do
      url when is_binary(url) and url != "" ->
        url

      _ ->
        host = URI.parse(Application.get_env(:mave_core, :domain) || "http://localhost").host
        port = Config.get(:rtmp_port)
        "rtmp://#{host || "localhost"}#{if port == 1935, do: "", else: ":#{port}"}/live"
    end
  end

  def playback_url(%Space{} = space, %LiveStream{} = stream),
    do: "#{base_url(space, stream)}/index.m3u8"

  def player_url(%Space{} = space, %LiveStream{} = stream),
    do: "#{base_url(space, stream)}/embed"

  @doc "The page where viewers watch the stream and chat during a broadcast."
  def watch_url(%Space{} = space, %LiveStream{} = stream) do
    origin = Application.get_env(:mave_core, :domain) || MaveCoreWeb.Endpoint.url()
    "#{String.trim_trailing(origin, "/")}/watch/#{public_id(space, stream)}"
  end

  def embed_code(%Space{} = space, %LiveStream{} = stream) do
    ~s(<iframe src="#{player_url(space, stream)}" style="aspect-ratio: 16 / 9; width: 100%; border: 0" allow="autoplay; fullscreen"></iframe>)
  end

  defp base_url(space, stream) do
    endpoint = SettingsSerializer.component_runtime_config()["api"]["endpoint"]
    "#{String.trim_trailing(endpoint, "/")}/live/#{public_id(space, stream)}"
  end

  @doc "What the management API and webhooks expose about a stream."
  def response(%Space{} = space, %LiveStream{} = stream) do
    %{
      object: "live_stream",
      id: public_id(space, stream),
      name: stream.name,
      status: stream.status,
      created: DateTime.to_unix(stream.inserted_at),
      started_at: unix(stream.started_at),
      ended_at: unix(stream.ended_at),
      encoder: stream.ingest,
      error: stream.last_error,
      ingest: %{url: ingest_url(), stream_key: stream.stream_key},
      playback: %{
        hls: playback_url(space, stream),
        player: player_url(space, stream),
        watch: watch_url(space, stream),
        embed: embed_code(space, stream)
      }
    }
  end

  @doc "What anyone with the playback URL may know about a stream."
  def public_status(%LiveStream{} = stream) do
    segments = if stream.status == :idle, do: 0, else: segment_count(stream)

    %{
      name: stream.name,
      status: stream.status,
      broadcast: stream.broadcast,
      started_at: unix(stream.started_at),
      ended_at: unix(stream.ended_at),
      # A player needs a couple of segments before the live edge is stable.
      playable: segments >= if(stream.status == :ended, do: 1, else: 2)
    }
  end

  @doc "Origin that serves segments, for the player page's security policy."
  def storage_origin(%Space{} = space) do
    case SettingsSerializer.storage_object_url(bucket(space), "live") do
      url when is_binary(url) ->
        uri = URI.parse(url)
        URI.to_string(%URI{scheme: uri.scheme, host: uri.host, port: uri.port})

      nil ->
        nil
    end
  end

  defp unix(%DateTime{} = time), do: DateTime.to_unix(time)
  defp unix(_time), do: nil

  @doc "Object key prefix of one broadcast's segments."
  def broadcast_prefix(%LiveStream{hash: hash}, broadcast), do: "live/#{hash}/#{broadcast}/"

  def bucket(%Space{} = space), do: Storage.bucket_for_space(space.hash, space.region)

  @doc false
  def storage, do: Application.get_env(:mave_core, :live_streams_storage_adapter, Storage)

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @doc "Subscribes to `{:live_stream_updated, id}` for all streams of a space."
  def subscribe(space_id) when is_binary(space_id),
    do: Phoenix.PubSub.subscribe(MaveCore.PubSub, topic(space_id))

  @doc false
  def subscribe_control(stream_id),
    do: Phoenix.PubSub.subscribe(MaveCore.PubSub, control_topic(stream_id))

  @doc false
  def notify(%LiveStream{id: id, space_id: space_id}) do
    Phoenix.PubSub.broadcast(MaveCore.PubSub, topic(space_id), {:live_stream_updated, id})
  end

  def notify(id) when is_binary(id) do
    case Repo.one(from(s in LiveStream, where: s.id == ^id, select: s.space_id)) do
      nil -> :ok
      space_id -> notify(%LiveStream{id: id, space_id: space_id})
    end
  end

  defp broadcast_change({:ok, %LiveStream{} = stream} = result) do
    notify(stream)
    result
  end

  defp broadcast_change(result), do: result

  defp topic(space_id), do: "live_streams:space:" <> space_id
  defp control_topic(stream_id), do: "live_streams:control:" <> stream_id

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Removing media is best effort: the rows that made it reachable are gone.
  defp delete_media(%Space{} = space, prefix) do
    bucket = bucket(space)
    region = space.region
    storage = storage()

    Task.Supervisor.start_child(MaveCore.LiveStreams.TaskSupervisor, fn ->
      storage.delete_prefix(bucket, prefix, region)
    end)

    :ok
  end

  defp generate_hash do
    hash =
      for _ <- 1..@hash_length, into: "" do
        <<:binary.at(@hash_chars, :rand.uniform(byte_size(@hash_chars)) - 1)>>
      end

    if Repo.exists?(from(s in LiveStream, where: s.hash == ^hash)),
      do: generate_hash(),
      else: hash
  end

  defp generate_stream_key,
    do: "live_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
end
