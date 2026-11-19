# Seeds the drill: one space with a public and a private video on the primary.
#
#     mix run --no-start deploy/delivery-standby/drill/seed.exs
#
# Run by drill.sh against the drill's own database and storage. The media is
# generated with FFmpeg, so nothing here depends on real uploads.

Logger.configure(level: :warning)
{:ok, _started} = Application.ensure_all_started(:mave_core)

import Ecto.Query

alias MaveCore.{Accounts, Embeds, Repo}
alias MaveCore.Embeds.Embed
alias MaveCore.Media.Storage
alias MaveCore.Playback.Minio

defmodule DeliveryDrillSeed do
  @moduledoc false

  @content_types %{
    ".m3u8" => "application/vnd.apple.mpegurl",
    ".ts" => "video/mp2t",
    ".json" => "application/json",
    ".jpg" => "image/jpeg"
  }

  def embed(space, name) do
    query =
      from(e in Embed,
        join: a in assoc(e, :asset),
        where: e.space_id == ^space.id and a.name == ^name and is_nil(e.deleted_at)
      )

    case Repo.one(query) do
      nil ->
        {:ok, embed} = Embeds.create_video_embed(space, %{name: name})
        embed

      embed ->
        embed
    end
  end

  def upload_video(bucket, embed, name, source) do
    dir = Path.join(System.tmp_dir!(), "mave-delivery-drill-#{embed.hash}")
    File.rm_rf!(dir)
    File.mkdir_p!(Path.join(dir, "h264_360p"))

    ffmpeg([
      "-f",
      "lavfi",
      "-i",
      "#{source}=size=640x360:rate=25",
      "-f",
      "lavfi",
      "-i",
      "sine=frequency=440:sample_rate=48000",
      "-t",
      "180",
      "-c:v",
      "libx264",
      "-preset",
      "veryfast",
      "-b:v",
      "500k",
      "-pix_fmt",
      "yuv420p",
      "-g",
      "50",
      "-sc_threshold",
      "0",
      "-c:a",
      "aac",
      "-b:a",
      "64k",
      "-f",
      "hls",
      "-hls_time",
      "2",
      "-hls_playlist_type",
      "vod",
      "-hls_segment_filename",
      Path.join(dir, "h264_360p/segment-%03d.ts"),
      Path.join(dir, "h264_360p/playlist.m3u8")
    ])

    ffmpeg([
      "-f",
      "lavfi",
      "-i",
      "#{source}=size=640x360",
      "-frames:v",
      "1",
      Path.join(dir, "thumbnail.jpg")
    ])

    File.write!(Path.join(dir, "playlist.m3u8"), """
    #EXTM3U
    #EXT-X-VERSION:3
    #EXT-X-STREAM-INF:BANDWIDTH=620000,RESOLUTION=640x360,CODECS="avc1.64001e,mp4a.40.2"
    h264_360p/playlist.m3u8
    """)

    File.write!(
      Path.join(dir, "manifest.json"),
      Jason.encode!(%{id: embed.hash, name: name, video: %{duration: 180, version: 0}})
    )

    for path <- Path.wildcard(Path.join(dir, "**/*")), File.regular?(path) do
      key = "#{embed.hash}/#{Path.relative_to(path, dir)}"
      type = Map.get(@content_types, Path.extname(path), "application/octet-stream")
      {:ok, _response} = Storage.put(bucket, key, File.read!(path), type)
    end

    File.rm_rf!(dir)
  end

  defp ffmpeg(args) do
    {_output, 0} =
      System.cmd("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y" | args],
        stderr_to_stdout: true
      )
  end
end

email = "delivery-drill@example.com"

user =
  case Accounts.get_user_by_email(email) do
    nil ->
      {:ok, user} = Accounts.create_user(email, %{skip_email_validation: true})
      user

    user ->
      Repo.preload(user, current_space_membership: [space: [:domains]])
  end

space = user.current_space_membership.space
bucket = Storage.bucket_for_space(space.hash)
:ok = Storage.ensure_bucket(bucket)

public = DeliveryDrillSeed.embed(space, "Launch film")
private = DeliveryDrillSeed.embed(space, "Board update")

private
|> Ecto.Changeset.change(playback_visibility: :private, playback_status: :private)
|> Repo.update!()

unless Storage.exists?(bucket, "#{public.hash}/manifest.json") do
  DeliveryDrillSeed.upload_video(bucket, public, "Launch film", "testsrc2")
  DeliveryDrillSeed.upload_video(bucket, private, "Board update", "smptebars")
end

# Same read rules as a deployment with private playback: only the public
# embed is readable without a signed URL.
{:ok, policy} = Minio.bucket_policy(bucket, [public.hash])
:ok = Storage.put_bucket_policy_document(bucket, policy, nil)

state = System.get_env("MAVE_DRILL_STATE") || raise "MAVE_DRILL_STATE is required"

File.write!(Path.join(state, "seed.env"), """
DRILL_SPACE=#{space.hash}
DRILL_PUBLIC_EMBED=#{public.hash}
DRILL_PRIVATE_EMBED=#{private.hash}
""")

IO.puts("Seeded space #{space.hash}: public #{public.hash}, private #{private.hash}")
