defmodule MaveCore.LiveStreams.Session do
  @moduledoc """
  One encoder connection: feeds the incoming media to FFmpeg, which repackages
  it as HLS segments without re-encoding, and publishes each finished segment
  to the space's storage.

  FFmpeg reads FLV from standard input, so it runs inside the media sandbox
  like every other parser of customer media. Segments are written to a scratch
  directory and listed in the stream's playlist only after they are stored.
  """

  use GenServer, restart: :temporary

  require Logger

  alias MaveCore.LiveStreams
  alias MaveCore.LiveStreams.{Config, FLV, LiveStream}
  alias MaveCore.Media.Command
  alias MaveCore.SafeFile

  @registry MaveCore.LiveStreams.Registry
  @supervisor MaveCore.LiveStreams.SessionSupervisor
  @scan_interval 500
  @heartbeat_interval 5_000
  @finalize_timeout 10_000
  @stop_timeout 30_000
  # Segments wait here while storage is slow. Beyond this the session ends
  # instead of filling the disk.
  @max_pending_segments 30
  # FFmpeg's own playlist only tells which segments are complete. It must hold
  # more entries than may be pending.
  @local_playlist_segments 40
  # Without audio or video in the first tags, both tracks are announced.
  @probe_tags 8

  # ---------------------------------------------------------------------------
  # API
  # ---------------------------------------------------------------------------

  @doc """
  Starts publishing for the stream that owns `stream_key`. The session ends
  when `publisher` exits. A session that is still running for the same stream,
  for example on a connection the network dropped, is replaced.
  """
  @spec start(String.t(), pid()) :: {:ok, pid()} | {:error, atom()}
  def start(stream_key, publisher \\ self()) do
    with {:ok, stream} <- LiveStreams.authenticate(stream_key) do
      stop_existing(stream.id)

      case DynamicSupervisor.start_child(@supervisor, {__MODULE__, {stream, publisher}}) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, _pid}} -> {:error, :already_publishing}
        {:error, _reason} -> {:error, :unavailable}
      end
    end
  end

  @doc "Writes one audio or video message. Blocks while FFmpeg is busy."
  def write(session, type, timestamp, payload) when type in [:audio, :video] do
    GenServer.call(session, {:write, type, timestamp, payload}, @stop_timeout)
  catch
    :exit, _reason -> {:error, :closed}
  end

  @doc "Passes on the encoder's `onMetaData` properties."
  def metadata(session, %{} = metadata), do: GenServer.cast(session, {:metadata, metadata})

  @doc "Ends the session after publishing the segments that are complete."
  def stop(session) do
    GenServer.call(session, :stop, @stop_timeout)
  catch
    :exit, _reason -> :ok
  end

  @doc "Whether this node runs a session for a stream."
  def running?(stream_id), do: Registry.lookup(@registry, stream_id) != []

  def start_link({%LiveStream{} = stream, publisher}) do
    GenServer.start_link(__MODULE__, {stream, publisher},
      name: {:via, Registry, {@registry, stream.id}}
    )
  end

  defp stop_existing(stream_id) do
    case Registry.lookup(@registry, stream_id) do
      [{pid, _value}] ->
        ref = Process.monitor(pid)
        stop(pid)

        receive do
          {:DOWN, ^ref, :process, _pid, _reason} -> :ok
        after
          @stop_timeout -> :ok
        end

      [] ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  @impl true
  def init({stream, publisher}) do
    Process.flag(:trap_exit, true)
    Process.monitor(publisher)
    LiveStreams.subscribe_control(stream.id)

    {:ok, stream, position} = LiveStreams.begin_session(stream)
    dir = Path.join(scratch_root(), "#{stream.hash}-#{System.unique_integer([:positive])}")

    with :ok <- File.mkdir_p(dir),
         :ok <- ensure_bucket(stream) do
      Process.send_after(self(), :scan, @scan_interval)
      Process.send_after(self(), :heartbeat, @heartbeat_interval)

      {:ok,
       %{
         stream: stream,
         dir: dir,
         port: nil,
         # Tags held back until the tracks are known and FFmpeg starts.
         probe: [],
         metadata: nil,
         next_sequence: position.next_sequence,
         discontinuity?: position.discontinuity?,
         discontinuity_sequence: position.discontinuity_sequence,
         # Entries of FFmpeg's playlist that are already published.
         published: 0,
         upload: nil,
         error: nil
       }}
    else
      error ->
        Logger.warning("Live session could not start: #{inspect(error)}")
        LiveStreams.end_session(stream, "Storage is unavailable")
        {:stop, :normal}
    end
  end

  @impl true
  def handle_call({:write, type, timestamp, payload}, _from, state) do
    case accept(type, payload, state) do
      :ok ->
        state = feed(state, {type, timestamp, payload})
        {:reply, :ok, state}

      {:error, message} ->
        {:stop, :normal, {:error, :unsupported}, %{state | error: message}}
    end
  end

  def handle_call(:stop, _from, state), do: {:stop, :normal, :ok, state}

  @impl true
  def handle_cast({:metadata, metadata}, state) do
    LiveStreams.put_ingest(state.stream, ingest(metadata))
    {:noreply, %{state | metadata: metadata}}
  end

  @impl true
  def handle_info(:scan, state) do
    Process.send_after(self(), :scan, @scan_interval)
    pending = pending_entries(state)

    cond do
      length(pending) > @max_pending_segments or missed?(pending, state) ->
        {:stop, :normal, %{state | error: "Storage could not keep up with the stream"}}

      state.upload == nil and pending != [] ->
        {:noreply, start_upload(state, pending)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(:heartbeat, state) do
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
    LiveStreams.heartbeat(state.stream)
    {:noreply, state}
  end

  def handle_info({ref, {:published, result}}, %{upload: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, apply_published(%{state | upload: nil}, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{upload: %Task{ref: ref}} = state),
    do: {:noreply, %{state | upload: nil}}

  # The encoder's connection ended.
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:stop, :normal, state}

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("Live packager exited with status #{status}")
    {:stop, :normal, %{state | port: nil, error: "The stream could not be processed"}}
  end

  def handle_info({port, {:data, _output}}, %{port: port} = state), do: {:noreply, state}
  def handle_info(:live_stream_deleted, state), do: {:stop, :normal, %{state | error: :deleted}}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state =
      try do
        finalize(state)
      rescue
        error ->
          Logger.warning("Live session did not finish cleanly: #{Exception.message(error)}")
          state
      end

    File.rm_rf(state.dir)

    unless state.error == :deleted do
      LiveStreams.end_session(state.stream, state.error)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Media
  # ---------------------------------------------------------------------------

  # HLS players and the MPEG-TS segments used here expect H.264.
  defp accept(:video, payload, _state) do
    case FLV.video_codec(payload) do
      :h264 -> :ok
      _other -> {:error, "Unsupported video codec. Set the encoder to H.264."}
    end
  end

  defp accept(:audio, _payload, _state), do: :ok

  defp feed(%{port: nil} = state, tag) do
    probe = [tag | state.probe]
    types = Enum.map(probe, &elem(&1, 0))

    if (:audio in types and :video in types) or length(probe) >= @probe_tags do
      start_packager(%{state | probe: []}, Enum.reverse(probe))
    else
      %{state | probe: probe}
    end
  end

  defp feed(%{port: port} = state, {type, timestamp, payload}) do
    Port.command(port, FLV.tag(type, timestamp, payload))
    state
  end

  defp start_packager(state, tags) do
    types = Enum.map(tags, &elem(&1, 0))
    announced = announced_tracks(state.metadata)

    tracks = [
      audio: :audio in types or (announced.audio and :video not in types),
      video: :video in types or (announced.video and :audio not in types)
    ]

    case open_port(state.dir) do
      {:ok, port} ->
        Port.command(port, FLV.header(tracks))

        Enum.each(tags, fn {type, timestamp, payload} ->
          Port.command(port, FLV.tag(type, timestamp, payload))
        end)

        %{state | port: port}

      {:error, reason} ->
        Logger.warning("Live packager could not start: #{inspect(reason)}")
        send(self(), {:packager_failed, reason})
        %{state | error: "The stream could not be processed"}
    end
  end

  defp announced_tracks(%{} = metadata) do
    %{
      audio: is_map_key(metadata, "audiocodecid") or is_map_key(metadata, "audiodatarate"),
      video: is_map_key(metadata, "videocodecid") or is_map_key(metadata, "width")
    }
  end

  defp announced_tracks(_metadata), do: %{audio: true, video: true}

  # sobelow_skip ["CI.System"]
  defp open_port(dir) do
    with executable when is_binary(executable) <- System.find_executable("ffmpeg"),
         {:ok, command, args} <- Command.prepare(executable, ffmpeg_args(dir), scratch_root()) do
      port =
        Port.open({:spawn_executable, command}, [
          :binary,
          :exit_status,
          :use_stdio,
          {:args, args},
          {:env,
           Enum.map(Command.environment(), fn {key, value} ->
             {String.to_charlist(key), if(value, do: String.to_charlist(value), else: false)}
           end)}
        ])

      {:ok, port}
    else
      nil -> {:error, :ffmpeg_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # Stream copy keeps the encoder's quality and costs almost no CPU. Segments
  # are cut at the encoder's keyframes, at or after the configured duration.
  defp ffmpeg_args(dir) do
    [
      "-hide_banner",
      "-loglevel",
      "error",
      "-nostats",
      "-analyzeduration",
      "2000000",
      "-f",
      "flv",
      "-i",
      "pipe:0",
      "-map",
      "0:v:0?",
      "-map",
      "0:a:0?",
      "-c",
      "copy",
      "-f",
      "hls",
      "-hls_time",
      Integer.to_string(Config.get(:segment_seconds)),
      "-hls_list_size",
      Integer.to_string(@local_playlist_segments),
      "-hls_segment_type",
      "mpegts",
      "-hls_flags",
      "program_date_time+temp_file",
      "-hls_segment_filename",
      Path.join(dir, "%06d.ts"),
      Path.join(dir, "index.m3u8")
    ]
  end

  # ---------------------------------------------------------------------------
  # Publishing
  # ---------------------------------------------------------------------------

  # Segment files are numbered from zero, so the number of published files is
  # also the number of the next file.
  defp pending_entries(state) do
    state.dir
    |> local_entries()
    |> Enum.filter(&(&1.number >= state.published))
  end

  # FFmpeg replaces its playlist atomically and lists a segment once it is
  # complete, so every listed file can be published.
  defp local_entries(dir) do
    case File.read(Path.join(dir, "index.m3u8")) do
      {:ok, body} -> parse_entries(String.split(body, "\n", trim: true), nil, nil, [])
      {:error, _reason} -> []
    end
  end

  defp parse_entries([], _duration, _time, acc), do: Enum.reverse(acc)

  defp parse_entries(["#EXTINF:" <> value | rest], _duration, time, acc) do
    duration =
      case Float.parse(value) do
        {duration, _rest} -> duration
        :error -> nil
      end

    parse_entries(rest, duration, time, acc)
  end

  defp parse_entries(["#EXT-X-PROGRAM-DATE-TIME:" <> value | rest], duration, _time, acc) do
    time =
      case DateTime.from_iso8601(String.trim(value)) do
        {:ok, time, _offset} -> DateTime.add(time, 0, :microsecond)
        _ -> nil
      end

    parse_entries(rest, duration, time, acc)
  end

  defp parse_entries(["#" <> _tag | rest], duration, time, acc),
    do: parse_entries(rest, duration, time, acc)

  defp parse_entries([file | rest], duration, time, acc) when is_float(duration) do
    file = Path.basename(String.trim(file))

    case Integer.parse(file) do
      {number, ".ts"} ->
        entry = %{file: file, number: number, duration: duration, time: time}
        parse_entries(rest, nil, nil, [entry | acc])

      _ ->
        parse_entries(rest, nil, nil, acc)
    end
  end

  defp parse_entries([_line | rest], _duration, time, acc),
    do: parse_entries(rest, nil, time, acc)

  # A pending segment already left FFmpeg's playlist.
  defp missed?([%{number: number} | _], state), do: number > state.published
  defp missed?([], _state), do: false

  defp start_upload(state, entries) do
    job =
      Map.take(state, [:stream, :dir, :next_sequence, :discontinuity?, :discontinuity_sequence])

    task =
      Task.Supervisor.async_nolink(MaveCore.LiveStreams.TaskSupervisor, fn ->
        {:published, publish(job, entries)}
      end)

    %{state | upload: task}
  end

  defp apply_published(state, result) do
    %{
      state
      | stream: result.stream,
        published: state.published + result.count,
        next_sequence: result.next_sequence,
        discontinuity?: result.discontinuity?,
        discontinuity_sequence: result.discontinuity_sequence
    }
  end

  # Publishes in order and stops at the first failure, which is retried on the
  # next scan.
  defp publish(job, entries) do
    initial = Map.put(job, :count, 0)

    Enum.reduce_while(entries, initial, fn entry, acc ->
      case publish_segment(acc, entry) do
        {:ok, acc} ->
          {:cont, acc}

        {:error, reason} ->
          Logger.warning("Live segment was not published: #{inspect(reason)}")
          {:halt, acc}
      end
    end)
  end

  defp publish_segment(acc, entry) do
    %{stream: stream} = acc
    path = Path.join(acc.dir, entry.file)
    key = LiveStreams.broadcast_prefix(stream, stream.broadcast) <> "#{acc.next_sequence}.ts"
    discontinuity_sequence = acc.discontinuity_sequence + if(acc.discontinuity?, do: 1, else: 0)

    with {:ok, %{size: size}} <- SafeFile.stat_regular(path),
         {:ok, _response} <-
           LiveStreams.storage().put_file_public(
             LiveStreams.bucket(stream.space),
             key,
             path,
             "video/mp2t",
             stream.space.region
           ) do
      {:ok, stream, _segment} =
        LiveStreams.record_segment(stream, %{
          sequence: acc.next_sequence,
          duration: entry.duration,
          key: key,
          size_bytes: size,
          discontinuity: acc.discontinuity?,
          discontinuity_sequence: discontinuity_sequence,
          program_date_time: entry.time
        })

      File.rm(path)

      {:ok,
       %{
         acc
         | stream: stream,
           count: acc.count + 1,
           next_sequence: acc.next_sequence + 1,
           discontinuity?: false,
           discontinuity_sequence: discontinuity_sequence
       }}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  # Closing standard input makes FFmpeg write its last segment and playlist.
  defp finalize(state) do
    state = await_upload(state)

    if state.port do
      if Port.info(state.port), do: Port.close(state.port)
      await_endlist(state.dir, System.monotonic_time(:millisecond) + @finalize_timeout)
    end

    case pending_entries(state) do
      [] ->
        state

      entries ->
        job =
          Map.take(state, [
            :stream,
            :dir,
            :next_sequence,
            :discontinuity?,
            :discontinuity_sequence
          ])

        apply_published(state, publish(job, entries))
    end
  end

  defp await_upload(%{upload: %Task{} = task} = state) do
    case Task.yield(task, @finalize_timeout) || Task.shutdown(task) do
      {:ok, {:published, result}} -> apply_published(%{state | upload: nil}, result)
      _ -> %{state | upload: nil}
    end
  end

  defp await_upload(state), do: state

  defp await_endlist(dir, deadline) do
    finished? =
      case File.read(Path.join(dir, "index.m3u8")) do
        {:ok, body} -> String.contains?(body, "#EXT-X-ENDLIST")
        {:error, _reason} -> false
      end

    cond do
      finished? ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :timeout

      true ->
        Process.sleep(100)
        await_endlist(dir, deadline)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp ensure_bucket(%LiveStream{space: space}) do
    bucket = LiveStreams.bucket(space)

    with :ok <- LiveStreams.storage().ensure_bucket(bucket, space.region) do
      # Applies the space's browser access rules to a bucket created here.
      _ = MaveCore.Spaces.sync_bucket_access_for_space_hash(space.hash, space.region)
      :ok
    end
  end

  defp ingest(metadata) do
    %{
      "width" => integer(metadata["width"]),
      "height" => integer(metadata["height"]),
      "framerate" => number(metadata["framerate"]),
      "video_bitrate" => integer(metadata["videodatarate"]),
      "audio_bitrate" => integer(metadata["audiodatarate"]),
      "video_codec" => codec(metadata["videocodecid"], %{7 => "h264"}),
      "audio_codec" => codec(metadata["audiocodecid"], %{10 => "aac", 2 => "mp3"}),
      "encoder" => text(metadata["encoder"])
    }
  end

  defp integer(value) when is_number(value), do: round(value)
  defp integer(_value), do: nil
  defp number(value) when is_number(value), do: Float.round(value * 1.0, 3)
  defp number(_value), do: nil

  defp codec(value, names) when is_number(value), do: Map.get(names, round(value))
  defp codec(value, _names) when is_binary(value), do: text(value)
  defp codec(_value, _names), do: nil

  defp text(value) when is_binary(value) do
    if String.valid?(value), do: String.slice(value, 0, 120)
  end

  defp text(_value), do: nil

  defp scratch_root, do: Path.expand(Path.join(System.tmp_dir!(), "mave-live"))
end
