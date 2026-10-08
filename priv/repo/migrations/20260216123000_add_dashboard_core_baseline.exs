defmodule MaveCore.Repo.Migrations.AddDashboardCoreBaseline do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS citext", ""
    execute "CREATE EXTENSION IF NOT EXISTS pg_trgm", ""

    execute "CREATE TYPE space_role AS ENUM ('owner', 'admin', 'member')",
            "DROP TYPE space_role"

    execute "CREATE TYPE region AS ENUM ('eu', 'eu_2', 'eu_3', 'world', 'custom')",
            "DROP TYPE region"

    execute """
            CREATE TYPE mave_event AS ENUM (
              'video_created',
              'video_uploaded',
              'video_deleted',
              'video_archived',
              'video_unarchived',
              'video_processing',
              'video_ready'
            )
            """,
            "DROP TYPE mave_event"

    execute """
            CREATE TYPE webhook_delivery_state AS ENUM (
              'pending',
              'processing',
              'succeeded',
              'failed',
              'canceled'
            )
            """,
            "DROP TYPE webhook_delivery_state"

    execute """
            CREATE TYPE video_status AS ENUM (
              'waiting',
              'playable',
              'uploading',
              'preparing',
              'ready',
              'errored'
            )
            """,
            "DROP TYPE video_status"

    execute """
            CREATE TYPE rendition_type AS ENUM (
              'audio',
              'video',
              'poster',
              'thumbnail',
              'placeholder',
              'storyboard',
              'segments',
              'clip_keyframes',
              'clip',
              'custom_thumbnail'
            )
            """,
            "DROP TYPE rendition_type"

    execute """
            CREATE TYPE rendition_codec AS ENUM (
              'webp',
              'webm',
              'jpg',
              'h264',
              'hevc',
              'av1',
              'mp3',
              'aac'
            )
            """,
            "DROP TYPE rendition_codec"

    execute """
            CREATE TYPE rendition_container AS ENUM (
              'webp',
              'webm',
              'jpg',
              'mp4',
              'avif',
              'hls',
              'mp3'
            )
            """,
            "DROP TYPE rendition_container"

    execute "CREATE TYPE rendition_size AS ENUM ('sd', 'hd', 'fhd', 'qhd', 'uhd')",
            "DROP TYPE rendition_size"

    execute """
            CREATE TYPE language_code AS ENUM (
              'af', 'am', 'ar', 'as', 'az', 'ba', 'be', 'bg', 'bn', 'bo', 'br', 'bs', 'ca',
              'cs', 'cy', 'da', 'de', 'el', 'en', 'es', 'et', 'eu', 'fa', 'fi', 'fo', 'fr',
              'gl', 'gu', 'ha', 'haw', 'hi', 'hr', 'ht', 'hu', 'hy', 'id', 'is', 'it', 'iw',
              'ja', 'jw', 'ka', 'kk', 'km', 'kn', 'ko', 'la', 'lb', 'ln', 'lo', 'lt', 'lv',
              'mg', 'mi', 'mk', 'ml', 'mn', 'mr', 'ms', 'mt', 'my', 'ne', 'nl', 'nn', 'no',
              'oc', 'pa', 'pl', 'ps', 'pt', 'ro', 'ru', 'sa', 'sd', 'si', 'sk', 'sl', 'sn',
              'so', 'sq', 'sr', 'su', 'sv', 'sw', 'ta', 'te', 'tg', 'th', 'tk', 'tl', 'tr',
              'tt', 'uk', 'ur', 'uz', 'vi', 'yi', 'yo', 'zh'
            )
            """,
            "DROP TYPE language_code"

    execute "CREATE TYPE audio_track_codec AS ENUM ('aac', 'flac', 'mp3', 'ogg', 'wav')",
            "DROP TYPE audio_track_codec"

    execute "CREATE TYPE settings_aspect_ratio AS ENUM ('r16_9', 'r1_1', 'r4_3', 'auto')",
            "DROP TYPE settings_aspect_ratio"

    execute "CREATE TYPE settings_controls AS ENUM ('full', 'big', 'none')",
            "DROP TYPE settings_controls"

    execute "CREATE TYPE settings_autoplay AS ENUM ('always', 'on_show')",
            "DROP TYPE settings_autoplay"

    execute "CREATE TYPE poster_type AS ENUM ('upload', 'timecode')", "DROP TYPE poster_type"

    execute "CREATE TYPE collection_type AS ENUM ('folder', 'showcase')",
            "DROP TYPE collection_type"

    execute "CREATE TYPE embed_type AS ENUM ('video', 'collection')", "DROP TYPE embed_type"

    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :citext, null: false
      add :confirmed_at, :utc_datetime_usec
      add :deleted_at, :utc_datetime_usec
      add :google_uid, :string
      add :google_uid_pending_since, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:email])
    create index(:users, [:google_uid])

    create table(:user_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      add :context, :string, null: false
      add :sent_to, :string
      add :attempts, :integer, null: false, default: 0
      add :last_attempt_at, :utc_datetime_usec
      add :invalidated_at, :utc_datetime_usec
      add :login_token_id, references(:user_tokens, type: :binary_id, on_delete: :delete_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:user_tokens, [:context, :token])
    create index(:user_tokens, [:user_id])
    create index(:user_tokens, [:login_token_id])

    create table(:spaces, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :hash, :string, null: false
      add :region, :region, null: false, default: "eu"

      add :public_sharing_enabled, :boolean, null: false, default: false
      add :hotlink_protection_enabled, :boolean, null: false, default: false

      add :deleted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:spaces, [:hash], where: "hash <> 'trial'", name: :spaces_hash_index)
    create index(:spaces, [:region])

    create table(:space_membership_invites, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: true
      add :email, :citext, null: true

      add :created_by_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false

      add :accepted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:space_membership_invites, [:user_id])
    create index(:space_membership_invites, [:created_by_id])
    create index(:space_membership_invites, [:email])

    create table(:space_memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: true
      add :space_id, references(:spaces, type: :binary_id, on_delete: :delete_all), null: false

      add :owner_space_id, references(:spaces, type: :binary_id, on_delete: :delete_all),
        null: true

      add :role, :space_role, null: false, default: "owner"

      add :invite_id,
          references(:space_membership_invites, type: :binary_id, on_delete: :nilify_all),
          null: true

      timestamps(type: :utc_datetime_usec)
    end

    create index(:space_memberships, [:user_id])
    create index(:space_memberships, [:space_id])
    create index(:space_memberships, [:owner_space_id])
    create index(:space_memberships, [:invite_id])
    create unique_index(:space_memberships, [:user_id, :space_id])

    create unique_index(:space_memberships, [:owner_space_id, :space_id],
             where: "owner_space_id IS NOT NULL",
             name: :space_memberships_unique_owner_space_id_index
           )

    create unique_index(:space_memberships, [:invite_id],
             where: "invite_id IS NOT NULL",
             name: :space_memberships_unique_invite_id_index
           )

    alter table(:users) do
      add :current_space_membership_id,
          references(:space_memberships, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:users, [:current_space_membership_id])

    create table(:space_domains, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :space_id, references(:spaces, type: :binary_id, on_delete: :delete_all), null: false
      add :domain, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:space_domains, [:space_id])
    create index(:space_domains, [:domain])
    create unique_index(:space_domains, [:space_id, :domain])

    create table(:space_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :space_id, references(:spaces, type: :binary_id, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :secret, :string, null: false
      add :description, :string
      add :last_used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:space_keys, [:space_id])
    create unique_index(:space_keys, [:key])

    create table(:space_webhooks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :space_id, references(:spaces, type: :binary_id, on_delete: :delete_all), null: false
      add :description, :string
      add :enabled, :boolean, null: false, default: true
      add :url, :text, null: false
      add :secret, :string, null: false
      add :enabled_events, {:array, :mave_event}, null: false, default: []

      timestamps(type: :utc_datetime_usec)
    end

    create index(:space_webhooks, [:space_id])
    create index(:space_webhooks, [:enabled])

    create table(:space_webhook_deliveries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :space_id, references(:spaces, type: :binary_id, on_delete: :delete_all), null: false

      add :webhook_id, references(:space_webhooks, type: :binary_id, on_delete: :delete_all),
        null: false

      add :event_type, :mave_event, null: false
      add :payload, :map, null: false, default: %{}
      add :state, :webhook_delivery_state, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :next_attempt_at, :utc_datetime_usec
      add :delivered_at, :utc_datetime_usec
      add :failed_at, :utc_datetime_usec
      add :response_code, :integer
      add :response_headers, :map
      add :response_body, :text
      add :error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:space_webhook_deliveries, [:space_id, :state])
    create index(:space_webhook_deliveries, [:webhook_id, :inserted_at])
    create index(:space_webhook_deliveries, [:next_attempt_at])

    create table(:assets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :space_id, references(:spaces, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:assets, [:space_id])

    execute "CREATE INDEX assets_name_trgm_idx ON assets USING GIN (name gin_trgm_ops)",
            "DROP INDEX assets_name_trgm_idx"

    create table(:videos, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :asset_id, references(:assets, type: :binary_id, on_delete: :delete_all), null: false
      add :status, :video_status, null: false, default: "waiting"
      add :file_name, :string
      add :source_url, :text

      add :max_width, :integer
      add :max_height, :integer
      add :max_frame_rate, :float
      add :max_bitrate, :bigint
      add :duration, :float
      add :aspect_ratio, :string
      add :original_file_size, :bigint
      add :language, :language_code

      timestamps(type: :utc_datetime_usec)
    end

    create index(:videos, [:asset_id])
    create index(:videos, [:status])

    execute "CREATE INDEX videos_file_name_trgm_idx ON videos USING GIN (file_name gin_trgm_ops)",
            "DROP INDEX videos_file_name_trgm_idx"

    alter table(:assets) do
      add :current_video_id, references(:videos, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:assets, [:current_video_id])

    create table(:renditions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :video_id, references(:videos, type: :binary_id, on_delete: :delete_all), null: false
      add :rendition_key, :string, null: false
      add :type, :rendition_type, null: false
      add :codec, :rendition_codec
      add :container, :rendition_container
      add :size, :rendition_size
      add :progress, :float
      add :file_size, :bigint

      timestamps(type: :utc_datetime_usec)
    end

    create index(:renditions, [:video_id])
    create unique_index(:renditions, [:rendition_key])

    create table(:subtitles, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :video_id, references(:videos, type: :binary_id, on_delete: :delete_all), null: false
      add :language, :language_code
      add :path, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:subtitles, [:video_id])

    create table(:audio_tracks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :video_id, references(:videos, type: :binary_id, on_delete: :delete_all), null: false
      add :label, :string
      add :language, :language_code
      add :default, :boolean, null: false, default: false
      add :codec, :audio_track_codec
      add :file_size, :bigint
      add :filename, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:audio_tracks, [:video_id])
    create unique_index(:audio_tracks, [:video_id, :filename])

    create table(:embed_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :space_id, references(:spaces, type: :binary_id, on_delete: :delete_all)

      add :width, :string, null: false, default: "100%"
      add :height, :string, null: false, default: "100%"
      add :aspect_ratio_enabled, :boolean, null: false, default: true
      add :aspect_ratio, :settings_aspect_ratio, null: false, default: "r16_9"
      add :color, :string
      add :opacity, :integer, null: false, default: 100

      add :controls_enabled, :boolean, null: false, default: true
      add :controls, :settings_controls, null: false, default: "full"

      add :autoplay_enabled, :boolean, null: false, default: false
      add :autoplay, :settings_autoplay, null: false, default: "on_show"

      add :loop_enabled, :boolean, null: false, default: false

      add :poster, :poster_type, null: false, default: "upload"
      add :poster_time_seconds, :float
      add :external_poster, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:embed_settings, [:space_id])

    create table(:collections, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :space_id, references(:spaces, type: :binary_id, on_delete: :delete_all)
      add :name, :string
      add :type, :collection_type, null: false, default: "folder"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:collections, [:space_id])

    create table(:embeds, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :hash, :string, null: false
      add :space_id, references(:spaces, type: :binary_id, on_delete: :delete_all)
      add :asset_id, references(:assets, type: :binary_id, on_delete: :nilify_all)

      add :embed_settings_id,
          references(:embed_settings, type: :binary_id, on_delete: :nilify_all)

      add :collection_id, references(:collections, type: :binary_id, on_delete: :nilify_all)

      add :type, :embed_type, null: false, default: "video"
      add :version, :integer, null: false, default: 1
      add :external_url, :string
      add :archived, :boolean, null: false, default: false
      add :replacing, :boolean, null: false, default: false
      add :deleted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:embeds, [:hash])
    create index(:embeds, [:space_id])
    create index(:embeds, [:asset_id])
    create index(:embeds, [:collection_id])
    create index(:embeds, [:external_url])

    create table(:collection_embeds, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :embed_id, references(:embeds, type: :binary_id, on_delete: :delete_all), null: false

      add :collection_id, references(:collections, type: :binary_id, on_delete: :delete_all),
        null: false

      add :position, :float

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:collection_embeds, [:collection_id, :embed_id])
    create index(:collection_embeds, [:embed_id])
  end
end
