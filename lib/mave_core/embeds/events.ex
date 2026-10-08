defmodule MaveCore.Embeds.Events do
  @moduledoc false

  @topic_prefix "embeds:"
  @space_topic_prefix "embeds:space:"

  def subscribe_space(space_id) when is_binary(space_id) do
    Phoenix.PubSub.subscribe(MaveCore.PubSub, space_topic(space_id))
  end

  def unsubscribe_space(space_id) when is_binary(space_id) do
    Phoenix.PubSub.unsubscribe(MaveCore.PubSub, space_topic(space_id))
  end

  def subscribe(space_id, embed_id) when is_binary(space_id) and is_binary(embed_id) do
    Phoenix.PubSub.subscribe(MaveCore.PubSub, topic(space_id, embed_id))
  end

  def unsubscribe(space_id, embed_id) when is_binary(space_id) and is_binary(embed_id) do
    Phoenix.PubSub.unsubscribe(MaveCore.PubSub, topic(space_id, embed_id))
  end

  def broadcast_updated(space_id, embed_id, payload \\ %{})
      when is_binary(space_id) and is_binary(embed_id) and is_map(payload) do
    Phoenix.PubSub.broadcast(
      MaveCore.PubSub,
      topic(space_id, embed_id),
      {:embed_updated, Map.merge(%{"space_id" => space_id, "embed_id" => embed_id}, payload)}
    )

    Phoenix.PubSub.broadcast(
      MaveCore.PubSub,
      space_topic(space_id),
      {:space_embeds_updated,
       Map.merge(%{"space_id" => space_id, "embed_id" => embed_id}, payload)}
    )
  end

  defp space_topic(space_id), do: @space_topic_prefix <> space_id
  defp topic(space_id, embed_id), do: @topic_prefix <> space_id <> ":" <> embed_id
end
