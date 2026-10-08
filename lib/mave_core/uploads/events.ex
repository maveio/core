defmodule MaveCore.Uploads.Events do
  @moduledoc false

  @topic_prefix "uploads:"

  def subscribe(upload_id) when is_binary(upload_id) do
    Phoenix.PubSub.subscribe(MaveCore.PubSub, topic(upload_id))
  end

  def unsubscribe(upload_id) when is_binary(upload_id) do
    Phoenix.PubSub.unsubscribe(MaveCore.PubSub, topic(upload_id))
  end

  def broadcast(event, data, upload_id) when is_binary(upload_id) do
    Phoenix.PubSub.broadcast(MaveCore.PubSub, topic(upload_id), {event, data})
  end

  defp topic(upload_id), do: @topic_prefix <> upload_id
end
