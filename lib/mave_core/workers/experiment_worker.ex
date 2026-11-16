defmodule MaveCore.Workers.ExperimentWorker do
  @moduledoc """
  Evaluates A/B tests whose period is over.

  Scheduled without arguments it evaluates every due test. With a
  `publish_embed_id` it retries publishing an embed page after a storage error.
  """
  use Oban.Worker, queue: :flow_low, max_attempts: 10

  alias MaveCore.Embeds.Embed
  alias MaveCore.Experiments
  alias MaveCore.Repo

  @impl true
  def perform(%Oban.Job{args: %{"publish_embed_id" => embed_id}}) do
    case Repo.get(Embed, embed_id) do
      %Embed{deleted_at: nil} = embed -> Experiments.publish_player(embed)
      _gone -> :ok
    end
  end

  def perform(_job), do: Experiments.evaluate_due()
end
