defmodule MaveCore.MultiRegion.Cache do
  @moduledoc """
  Short-lived node-local cache for multi-region lookups on hot paths, and the
  listener that turns embed changes into replication requests.
  """
  use GenServer

  alias MaveCore.MultiRegion

  @table :mave_core_multi_region
  @changes_topic "embeds:changes"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def changes_topic, do: @changes_topic

  @doc "Returns the cached value for `key`, computing and storing it when missing or expired."
  def fetch(key, ttl_ms, fun) when is_function(fun, 0) do
    case get(key) do
      {:ok, value} ->
        value

      :miss ->
        value = fun.()
        put(key, value, ttl_ms)
        value
    end
  end

  def get(key) do
    with true <- table?(),
         [{^key, value, expires_at}] <- :ets.lookup(@table, key),
         true <- expires_at > System.monotonic_time(:millisecond) do
      {:ok, value}
    else
      _miss -> :miss
    end
  end

  def put(key, value, ttl_ms) do
    if table?() do
      :ets.insert(@table, {key, value, System.monotonic_time(:millisecond) + ttl_ms})
    end

    :ok
  end

  def delete(key) do
    if table?(), do: :ets.delete(@table, key)
    :ok
  end

  @doc "Drops every entry whose key is a `{tag, _}` tuple."
  def delete_matching(tag) do
    if table?(), do: :ets.match_delete(@table, {{tag, :_}, :_, :_})
    :ok
  end

  defp table?, do: :ets.whereis(@table) != :undefined

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    if Keyword.get(opts, :listen, true) do
      Phoenix.PubSub.subscribe(MaveCore.PubSub, @changes_topic)
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info({:embed_changed, space_id, embed_id}, state) do
    # Outside this process: a database error must not take the cache table down.
    Task.start(fn -> MultiRegion.embed_changed(space_id, embed_id) end)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
