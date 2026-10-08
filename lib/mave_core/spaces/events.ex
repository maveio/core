defmodule MaveCore.Spaces.Events do
  @moduledoc false

  @topic_prefix "spaces:"

  def subscribe_access_changes do
    Phoenix.PubSub.subscribe(MaveCore.PubSub, "space_access_changes")
  end

  def broadcast_access_changed do
    Phoenix.PubSub.broadcast(MaveCore.PubSub, "space_access_changes", :space_access_changed)
  end

  def subscribe(space_id) when is_binary(space_id) do
    Phoenix.PubSub.subscribe(MaveCore.PubSub, topic(space_id))
  end

  def unsubscribe(space_id) when is_binary(space_id) do
    Phoenix.PubSub.unsubscribe(MaveCore.PubSub, topic(space_id))
  end

  def broadcast_updated(space_id) when is_binary(space_id) do
    Phoenix.PubSub.broadcast(MaveCore.PubSub, topic(space_id), {:space_updated, space_id})
  end

  defp topic(space_id), do: @topic_prefix <> space_id
end
