defmodule MaveCore.IntegrationSeeds do
  @moduledoc false

  require Logger

  alias MaveCore.Media.Storage

  @space_hash "ubg50"
  @embed_hash "LeDE9v86ye"

  def maybe_seed! do
    cond do
      not minio_available?() ->
        {:skipped, "MinIO not reachable at #{s3_endpoint()}"}

      not ffmpeg_available?() ->
        {:skipped, "ffmpeg not found in PATH"}

      true ->
        seed_minio!()
        :ok
    end
  end

  def minio_available? do
    endpoint = s3_endpoint()

    case Req.get(endpoint, connect_options: [timeout: 250], receive_timeout: 250) do
      {:ok, %{status: status}} when status in 200..499 -> true
      _ -> false
    end
  end

  def ffmpeg_available? do
    System.find_executable("ffmpeg") != nil
  end

  def seed_minio! do
    {:ok, _} = Application.ensure_all_started(:mave_core)
    {:ok, _} = Application.ensure_all_started(:req)
    {:ok, _} = Application.ensure_all_started(:req_s3)

    bucket = Storage.bucket_for_space(@space_hash)

    ensure_bucket!(bucket)

    manifest_path = "#{@embed_hash}/manifest.json"

    if Storage.exists?(bucket, manifest_path) do
      Logger.info("MinIO already seeded (#{manifest_path} exists)")
      :ok
    else
      Logger.info("Seeding MinIO with sample video data...")

      manifest_json = manifest_json()

      tmp_dir = Path.join(System.tmp_dir(), "mave_seed_#{System.unique_integer()}")
      File.mkdir_p!(tmp_dir)

      File.write!(Path.join(tmp_dir, "playlist.m3u8"), root_playlist())

      hls_dir = Path.join(tmp_dir, "h264_sd_hls")
      File.mkdir_p!(hls_dir)

      args = [
        "-y",
        "-f",
        "lavfi",
        "-i",
        "testsrc=duration=10:size=640x360:rate=30",
        "-c:v",
        "libx264",
        "-g",
        "30",
        "-sc_threshold",
        "0",
        "-f",
        "hls",
        "-hls_time",
        "6",
        "-hls_list_size",
        "0",
        "-hls_segment_type",
        "fmp4",
        Path.join(hls_dir, "playlist.m3u8")
      ]

      {_output, 0} = System.cmd("ffmpeg", args, stderr_to_stdout: true)

      upload_content!(bucket, manifest_path, manifest_json, "application/json")
      upload_file!(bucket, Path.join(tmp_dir, "playlist.m3u8"), "#{@embed_hash}/playlist.m3u8")

      for file <- File.ls!(hls_dir) do
        local_path = Path.join(hls_dir, file)
        remote_path = "#{@embed_hash}/h264_sd_hls/#{file}"
        upload_file!(bucket, local_path, remote_path)
      end

      Logger.info("MinIO seeding complete.")
      :ok
    end
  end

  defp s3_endpoint do
    config = Application.get_env(:mave_core, :s3) || []
    Keyword.get(config, :endpoint, "http://localhost:9000")
  end

  defp aws_sigv4_config do
    config = Application.get_env(:mave_core, :s3) || []

    [
      access_key_id: Keyword.get(config, :access_key_id, "minioadmin"),
      secret_access_key: Keyword.get(config, :secret_access_key, "minioadmin"),
      region: Keyword.get(config, :region, "us-east-1"),
      service: "s3"
    ]
  end

  defp ensure_bucket!(bucket) do
    base_url = s3_endpoint()

    req =
      Req.new(base_url: base_url)
      |> ReqS3.attach()
      |> Req.merge(aws_sigv4: aws_sigv4_config())

    case Req.put(req, url: "/#{bucket}") do
      {:ok, %{status: status}} when status in [200, 204] ->
        :ok

      {:ok, %{status: 409}} ->
        # BucketAlreadyOwnedByYou / BucketAlreadyExists
        :ok

      {:ok, resp} ->
        raise "Failed to create bucket #{bucket}: status=#{resp.status}"

      {:error, reason} ->
        raise "Failed to create bucket #{bucket}: #{inspect(reason)}"
    end
  end

  defp upload_file!(bucket, local_path, remote_path) do
    content = File.read!(local_path)
    upload_content!(bucket, remote_path, content, "application/octet-stream")
  end

  defp upload_content!(bucket, remote_path, content, content_type) do
    case Storage.put(bucket, remote_path, content, content_type) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "Failed to upload #{remote_path}: #{inspect(reason)}"
    end
  end

  defp root_playlist do
    """
    #EXTM3U
    #EXT-X-VERSION:3
    #EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=842x480
    h264_sd_hls/playlist.m3u8
    """
  end

  defp manifest_json do
    """
    {
        "audio_tracks": [],
        "created_at": 1700000000,
        "id": "ubg50LeDE9v86ye",
        "metrics_key": "AAAAAAAAAAAAAAAAAAAAAA==",
        "name": "Sample video",
        "poster": {
            "image_src": "https://image.mave.io/ubg50LeDE9v86ye.webp",
            "initial_frame_src": "https://image.mave.io/ubg50LeDE9v86ye.webp?time=0",
            "renditions": [],
            "type": null,
            "video_src": null
        },
        "settings": { "aspect_ratio": "16 / 9" },
        "space_id": "ubg50",
        "subtitles": [],
        "video": {
            "aspect_ratio": "16 / 9",
            "duration": 10.0,
            "filetype": "mp4",
            "id": "1111111111111111111111",
            "renditions": [],
            "size": 1000000,
            "version": 8
        }
    }
    """
  end
end
