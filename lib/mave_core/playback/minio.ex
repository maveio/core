defmodule MaveCore.Playback.Minio do
  @moduledoc "Local MinIO implementation of private playback for development."
  @behaviour MaveCore.Playback.Adapter

  alias MaveCore.Media.Storage
  alias MaveCore.Playback.StoragePolicy
  alias MaveCore.Spaces.Space

  @impl true
  def available?(%Space{deleted_at: nil}),
    do: local_storage?()

  def available?(_space), do: false

  @impl true
  def apply_visibility(embed, visibility) do
    if local_storage?(),
      do: StoragePolicy.apply_visibility(embed, visibility, __MODULE__),
      else: {:error, :local_storage_required}
  end

  def sync_space_domain_cors(space) do
    if local_storage?(),
      do: StoragePolicy.sync_space_domain_cors(space, __MODULE__),
      else: {:error, :local_storage_required}
  end

  def policy_for(bucket, hashes, _region), do: bucket_policy(bucket, hashes)
  def purge(_embed), do: :ok

  def put_cors(bucket, region) do
    case Storage.put_bucket_cors(bucket, ["*"], region) do
      {:error, {:bucket_cors_failed, 501}} -> :ok
      result -> result
    end
  end

  @doc false
  def bucket_policy(bucket, hashes) do
    {:ok,
     %{
       "Version" => "2012-10-17",
       "Statement" => [
         %{
           "Sid" => "PublicMedia",
           "Effect" => "Allow",
           "Principal" => "*",
           "Action" => "s3:GetObject",
           "Resource" =>
             Enum.map(
               ["themes/*", "*/player.html"] ++
                 Enum.map(Enum.uniq(hashes), &(&1 <> "/*")),
               &("arn:aws:s3:::" <> bucket <> "/" <> &1)
             )
         }
       ]
     }}
  end

  def object_url(bucket, path),
    do: String.trim_trailing(s3()[:endpoint], "/") <> "/" <> bucket <> "/" <> path

  defdelegate get(bucket, path, profile), to: Storage
  defdelegate object_info(bucket, path, profile), to: Storage

  # Sign with the browser endpoint itself: rewriting a signed host invalidates
  # the signature. Reads from the application still use the internal endpoint.
  def presigned_get_url(bucket, path, _profile, opts) do
    if local_storage?() do
      config =
        Keyword.put(
          s3(),
          :endpoint,
          Application.get_env(:mave_core, :playback_public_storage_endpoint, s3()[:endpoint])
        )

      Storage.presigned_get_url(bucket, path, config, opts)
    else
      {:error, :local_storage_required}
    end
  end

  defp local_storage? do
    URI.parse(s3()[:endpoint] || "").host in ["localhost", "127.0.0.1", "::1", "cdn", "minio"] and
      Application.get_env(:mave_core, :storage_providers, %{}) == %{}
  end

  defp s3, do: Application.get_env(:mave_core, :s3, [])
end
