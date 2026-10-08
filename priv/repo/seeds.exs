# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories. In fact, some of them are already loaded.
#
#     MaveCore.Repo.insert!(%MaveCore.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

# Seeding MinIO for Local Development
if Mix.env() == :dev do
  require Logger
  alias MaveCore.Media.Storage

  Logger.info("Seeding MinIO with sample data...")

  # Ensure app is started to use Storage config
  {:ok, _} = Application.ensure_all_started(:mave_core)
  {:ok, _} = Application.ensure_all_started(:req)
  {:ok, _} = Application.ensure_all_started(:req_s3)

  bucket = "space-ubg50"
  embed_hash = "LeDE9v86ye"

  # Synthetic metadata; fixed routing IDs match the integration fixtures.
  manifest_json = """
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

  # 2. Generate Real Video Segments with FFmpeg
  tmp_dir = Path.join(System.tmp_dir(), "mave_seed_#{System.unique_integer()}")
  File.mkdir_p!(tmp_dir)

  # Generate master playlist
  File.write!(Path.join(tmp_dir, "playlist.m3u8"), """
  #EXTM3U
  #EXT-X-VERSION:3
  #EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=842x480
  h264_sd_hls/playlist.m3u8
  """)

  # Generate content
  hls_dir = Path.join(tmp_dir, "h264_sd_hls")
  File.mkdir_p!(hls_dir)

  Logger.info("Generating test video segments with ffmpeg...")
  # Generate 10 seconds of video, fragmented
  # -f hls -hls_time 6 -hls_list_size 0 -hls_segment_type fmp4
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

  {_, 0} = System.cmd("ffmpeg", args, stderr_to_stdout: true)

  # 3. Upload to MinIO using Storage module
  upload = fn local_path, remote_path ->
    content = File.read!(local_path)

    case Storage.put(bucket, remote_path, content) do
      {:ok, _} -> Logger.info("Uploaded #{remote_path}")
      {:error, e} -> Logger.error("Failed to upload #{remote_path}: #{inspect(e)}")
    end
  end

  # Upload Manifest
  upload_content = fn content, remote_path ->
    case Storage.put(bucket, remote_path, content) do
      {:ok, _} -> Logger.info("Uploaded #{remote_path}")
      {:error, e} -> Logger.error("Failed to upload #{remote_path}: #{inspect(e)}")
    end
  end

  upload_content.(manifest_json, "#{embed_hash}/manifest.json")

  # Upload HLS files
  upload.(Path.join(tmp_dir, "playlist.m3u8"), "#{embed_hash}/playlist.m3u8")

  # Iterate generated HLS files
  hls_files = File.ls!(hls_dir)

  for file <- hls_files do
    local_path = Path.join(hls_dir, file)
    remote_path = "#{embed_hash}/h264_sd_hls/#{file}"
    upload.(local_path, remote_path)
  end

  Logger.info("Seeding complete.")
end
