defmodule MaveCore.Playback.Adapter do
  @moduledoc """
  Deployment boundary for private-media storage and availability.

  `apply_visibility/2` must protect every existing and future object under the
  embed prefix, invalidate cached public copies, and verify unsigned reads are
  denied before returning `:ok` for private visibility. Errors are retried and
  must never restore public access as a fallback.

  Storage synchronization must preserve this boundary on subsequent uploads,
  replacement, settings publication, and domain/CORS updates.
  """
  @callback available?(MaveCore.Spaces.Space.t()) :: boolean()
  @callback apply_visibility(MaveCore.Embeds.Embed.t(), :public | :private) ::
              :ok | {:error, term()}
  @callback token_endpoint() :: module()
  @optional_callbacks token_endpoint: 0
end
