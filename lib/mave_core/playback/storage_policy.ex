defmodule MaveCore.Playback.StoragePolicy do
  @moduledoc false
  import Ecto.Query
  alias MaveCore.Embeds.Embed
  alias MaveCore.Media.Storage
  alias MaveCore.Repo
  alias MaveCore.Spaces.Space

  def apply_visibility(embed, visibility, backend) do
    with :ok <- write_policy(embed.space, {embed.id, visibility}, backend),
         :ok <- backend.purge(embed) do
      verify_origin(embed, visibility, backend)
    end
  end

  @doc false
  def sync_space_domain_cors(%Space{} = space, backend) do
    # Access configuration changes must never republish protected media.
    Repo.transaction(fn ->
      Repo.one!(from(s in Space, where: s.id == ^space.id, lock: "FOR UPDATE"))

      result =
        if Repo.exists?(
             from(e in Embed,
               where:
                 e.space_id == ^space.id and
                   (e.playback_visibility == :private or e.playback_status != :public)
             )
           ) do
          write_policy(space, nil, backend)
        else
          Storage.sync_space_domain_cors(space)
        end

      case result do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_policy(space, override, backend) do
    bucket = Storage.bucket_for_space(space.hash, space.region)
    embeds = Repo.all(from(e in Embed, where: e.space_id == ^space.id and is_nil(e.deleted_at)))

    public_hashes =
      Enum.filter(embeds, fn embed ->
        case override do
          {id, visibility} when id == embed.id -> visibility == :public
          _ -> embed.playback_visibility == :public and embed.playback_status == :public
        end
      end)
      |> Enum.map(& &1.hash)

    with {:ok, policy} <- backend.policy_for(bucket, public_hashes, space.region),
         :ok <- Storage.put_bucket_policy_document(bucket, policy, space.region) do
      backend.put_cors(bucket, space.region)
    end
  end

  defp verify_origin(embed, visibility, backend) do
    bucket = Storage.bucket_for_space(embed.space.hash, embed.space.region)
    path = embed.hash <> "/manifest.json"

    url = backend.object_url(bucket, path)

    with {:ok, _info} <- Storage.object_info(bucket, path, embed.space.region),
         {:ok, %{status: unsigned}} <- Req.head(url, retry: false, redirect: false) do
      if (visibility == :private and unsigned in [401, 403, 404]) or
           (visibility == :public and unsigned in 200..299),
         do: :ok,
         else: {:error, :playback_public_access_not_converged}
    else
      {:error, :not_found} when visibility == :private ->
        if is_nil(Repo.preload(embed, :asset).asset.current_video_id),
          do: :ok,
          else: {:error, :playback_storage_verification_failed}

      _ ->
        {:error, :playback_storage_verification_failed}
    end
  end
end
