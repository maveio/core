defmodule MaveCore.Workers.SubtitleJsonWorker do
  @moduledoc false
  use Oban.Worker, queue: :flow_low, max_attempts: 10

  @impl true
  def perform(%Oban.Job{args: %{"embed_id" => embed, "subtitle_id" => subtitle, "path" => path}}) do
    MaveCore.Assets.publish_subtitle_json(embed, subtitle, path)
  end
end
