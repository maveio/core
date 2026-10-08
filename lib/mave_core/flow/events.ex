defmodule MaveCore.Flow.Events do
  @moduledoc false

  @topic "flow:runs"

  def subscribe do
    Phoenix.PubSub.subscribe(MaveCore.PubSub, @topic)
  end

  def unsubscribe do
    Phoenix.PubSub.unsubscribe(MaveCore.PubSub, @topic)
  end

  def broadcast_updated(flow_run_id, payload \\ %{})
      when is_binary(flow_run_id) and is_map(payload) do
    Phoenix.PubSub.broadcast(
      MaveCore.PubSub,
      @topic,
      {:flow_run_updated, Map.put(payload, "flow_run_id", flow_run_id)}
    )
  end
end
