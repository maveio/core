defmodule MaveCore.Workers.TimecodeThumbnailWorker do
  @moduledoc false
  use Oban.Worker, queue: :flow_media, max_attempts: 20

  @impl true
  def perform(%Oban.Job{args: %{"embed_id" => embed, "video_id" => video, "seconds" => seconds}}) do
    MaveCore.Assets.finish_timecode_thumbnail(embed, video, seconds)
  end
end
