defmodule MaveCore.LiveStreamsFixtures do
  @moduledoc false

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias MaveCore.LiveStreams
  alias MaveCore.LiveStreams.Segment
  alias MaveCore.Repo
  alias MaveCore.Spaces.Space

  defmodule Storage do
    @moduledoc false
    # Stands in for object storage so tests need no bucket.

    def delete_prefix(bucket, prefix, _region) do
      case Application.get_env(:mave_core, :live_streams_test_pid) do
        pid when is_pid(pid) -> send(pid, {:deleted_prefix, bucket, prefix})
        _ -> :ok
      end

      :ok
    end
  end

  @doc "Enables live streaming with stubbed storage until the test exits."
  def enable_live_streams(overrides \\ []) do
    previous = Application.get_env(:mave_core, :live_streams, [])
    previous_backend = Application.get_env(:mave_core, :usage_limits_backend)

    Application.put_env(
      :mave_core,
      :live_streams,
      Keyword.merge(previous, Keyword.merge([enabled: true], overrides))
    )

    Application.put_env(:mave_core, :live_streams_storage_adapter, Storage)
    Application.put_env(:mave_core, :live_streams_test_pid, self())

    on_exit(fn ->
      Application.put_env(:mave_core, :live_streams, previous)
      Application.delete_env(:mave_core, :live_streams_storage_adapter)
      Application.delete_env(:mave_core, :live_streams_test_pid)

      if previous_backend,
        do: Application.put_env(:mave_core, :usage_limits_backend, previous_backend),
        else: Application.delete_env(:mave_core, :usage_limits_backend)
    end)

    :ok
  end

  def space_fixture do
    hash = for _ <- 1..5, into: "", do: <<Enum.random(?a..?z)>>
    Repo.insert!(%Space{hash: hash, region: "eu"})
  end

  def live_stream_fixture(%Space{} = space, attrs \\ %{}) do
    {:ok, stream} = LiveStreams.create(space, attrs)
    stream
  end

  @doc "Starts a broadcast and records `count` two-second segments for it."
  def broadcast_fixture(stream, count) do
    {:ok, stream, position} = LiveStreams.begin_session(stream)

    Enum.reduce(0..(count - 1)//1, stream, fn offset, stream ->
      {:ok, stream, %Segment{}} =
        LiveStreams.record_segment(stream, %{
          sequence: position.next_sequence + offset,
          duration: 2.0,
          key:
            "#{LiveStreams.broadcast_prefix(stream, stream.broadcast)}#{position.next_sequence + offset}.ts",
          size_bytes: 1_000,
          discontinuity: position.discontinuity? and offset == 0,
          discontinuity_sequence:
            position.discontinuity_sequence + if(position.discontinuity?, do: 1, else: 0)
        })

      stream
    end)
  end
end
