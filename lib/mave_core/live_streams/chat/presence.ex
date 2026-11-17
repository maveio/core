defmodule MaveCore.LiveStreams.Chat.Presence do
  @moduledoc false

  use Phoenix.Presence, otp_app: :mave_core, pubsub_server: MaveCore.PubSub
end
