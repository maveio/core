defmodule MaveCore.SpacesWebhookDeliveryTest do
  use MaveCore.DataCase, async: false

  import Plug.Conn

  alias MaveCore.{Accounts, Embeds, Repo, Spaces}
  alias MaveCore.Spaces.WebhookDelivery
  alias MaveCore.Workers.WebhookDeliveryWorker
  alias Oban.Job

  setup {Req.Test, :verify_on_exit!}

  setup do
    email = "webhook-delivery-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(email)
    previous_req_options = Req.default_options()
    old_resolver = Application.get_env(:mave_core, :public_http_url_resolver)

    Application.put_env(:mave_core, :public_http_url_resolver, fn _host ->
      {:ok, [{93, 184, 216, 34}]}
    end)

    on_exit(fn ->
      Req.default_options(previous_req_options)
      restore_env(:public_http_url_resolver, old_resolver)
    end)

    %{space: user.current_space_membership.space}
  end

  test "enqueue_webhook_event creates deliveries only for enabled matching webhooks", %{
    space: space
  } do
    matching_webhook =
      create_webhook(space, %{
        "enabled_events" => [:video_uploaded]
      })

    _disabled_webhook =
      create_webhook(space, %{
        "enabled" => false,
        "enabled_events" => [:video_uploaded]
      })

    _different_event_webhook =
      create_webhook(space, %{
        "enabled_events" => [:video_ready]
      })

    assert {:ok, [delivery]} =
             Spaces.enqueue_webhook_event(
               space,
               :video_uploaded,
               %{"id" => "trialabc123", "embed_hash" => "abc123"},
               %{enqueue: false}
             )

    assert delivery.webhook_id == matching_webhook.id
    assert delivery.state == :pending
    assert delivery.payload["id"] == "trialabc123"
    assert delivery.payload["embed_hash"] == "abc123"

    assert [listed] = Spaces.list_webhook_deliveries(space)
    assert listed.id == delivery.id
    assert listed.webhook.id == matching_webhook.id
  end

  test "enqueue_webhook_event_for_embed stores the old-mave-style public payload", %{space: space} do
    _webhook = create_webhook(space, %{"enabled_events" => [:video_uploaded]})
    embed = create_video_embed(space, "Webhook video")

    assert {:ok, [delivery]} =
             Spaces.enqueue_webhook_event_for_embed(
               space,
               embed,
               :video_uploaded,
               %{enqueue: false}
             )

    payload = delivery.payload |> Jason.encode!() |> Jason.decode!()

    assert payload["id"] == "#{space.hash}#{embed.hash}"
    assert payload["name"] == "Webhook video"
    assert payload["object"] == "video"
    assert payload["subtitles"] == []
    assert payload["renditions"] == []
    refute Map.has_key?(payload, "embed_id")
    refute Map.has_key?(payload, "embed_hash")
    refute Map.has_key?(payload, "space_hash")
    refute Map.has_key?(payload, "audio_tracks")
  end

  test "enqueue_webhook_event_by_hash resolves the embed owner when trial hashes are duplicated",
       %{
         space: target_space
       } do
    target_space = force_space_hash!(target_space, "trial")

    email = "webhook-trial-decoy-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(email)
    decoy_space = force_space_hash!(user.current_space_membership.space, "trial")

    _decoy_webhook = create_webhook(decoy_space, %{"enabled_events" => [:video_uploaded]})
    _target_webhook = create_webhook(target_space, %{"enabled_events" => [:video_uploaded]})
    embed = create_video_embed(target_space, "Trial webhook video")

    assert {:ok, [delivery]} =
             Spaces.enqueue_webhook_event_by_hash(
               "trial",
               embed.hash,
               :video_uploaded,
               %{},
               %{enqueue: false}
             )

    assert delivery.space_id == target_space.id

    payload = delivery.payload |> Jason.encode!() |> Jason.decode!()
    assert payload["id"] == "trial#{embed.hash}"
  end

  test "video.created webhook payload has no poster image before a video exists", %{
    space: space
  } do
    _webhook = create_webhook(space, %{"enabled_events" => [:video_created]})
    embed = create_video_embed(space, "Created webhook video")

    assert {:ok, [delivery]} =
             Spaces.enqueue_webhook_event_for_embed(
               space,
               embed,
               :video_created,
               %{enqueue: false}
             )

    payload = delivery.payload |> Jason.encode!() |> Jason.decode!()

    assert payload["id"] == "#{space.hash}#{embed.hash}"
    assert payload["object"] == "video"
    assert is_nil(payload["poster_image"])
  end

  test "enqueue_webhook_event_for_embed omits HLS master rows from public renditions", %{
    space: space
  } do
    _webhook = create_webhook(space, %{"enabled_events" => [:video_ready]})
    embed = create_video_embed(space, "Ready webhook video")

    assert {:ok, embed} =
             Embeds.begin_video_upload(space.hash, embed.hash, %{
               "title" => "Ready webhook video.mp4",
               "source_url" => "https://example.com/ready.mp4",
               "upload_size" => 1_849_672
             })

    video =
      embed.asset.current_video
      |> Ecto.Changeset.change(%{
        status: "ready",
        duration: 8.0,
        max_width: 1280,
        max_height: 720
      })
      |> Repo.update!()

    insert_renditions(video.id, [
      %{key: "#{embed.hash}/h264_sd_hls/playlist.m3u8", container: "hls", size: "sd"},
      %{key: "#{embed.hash}/h264_hd_hls/playlist.m3u8", container: "hls", size: "hd"},
      %{key: "#{embed.hash}/playlist.m3u8", container: "hls", size: nil}
    ])

    assert {:ok, [delivery]} =
             Spaces.enqueue_webhook_event_for_embed(
               space,
               embed,
               :video_ready,
               %{enqueue: false}
             )

    payload = delivery.payload |> Jason.encode!() |> Jason.decode!()
    assert payload["renditions"] == ["sd", "hd"]
  end

  test "process_webhook_delivery marks delivery as succeeded", %{space: space} do
    Req.default_options(plug: {Req.Test, __MODULE__})
    embed = create_video_embed(space, "Processed webhook video")

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert [_signature] = get_req_header(conn, "mave-signature")

      payload = conn |> Req.Test.raw_body() |> Jason.decode!()
      send(self(), {:webhook_payload, payload})

      Req.Test.json(conn, %{"ok" => true})
    end)

    _webhook = create_webhook(space, %{"enabled_events" => [:video_uploaded]})

    assert {:ok, [delivery]} =
             Spaces.enqueue_webhook_event_for_embed(
               space,
               embed,
               :video_uploaded,
               %{enqueue: false}
             )

    assert {:ok, :succeeded} = Spaces.process_webhook_delivery(delivery.id)
    assert_received {:webhook_payload, payload}
    assert payload["id"] == delivery.id
    assert payload["type"] == "video.uploaded"
    assert payload["object"] == "event"
    assert payload["data"]["id"] == "#{space.hash}#{embed.hash}"
    assert payload["data"]["name"] == "Processed webhook video"
    assert payload["data"]["object"] == "video"
    refute Map.has_key?(payload["data"], "embed_id")
    refute Map.has_key?(payload["data"], "embed_hash")
    refute Map.has_key?(payload["data"], "space_hash")
    refute Map.has_key?(payload["data"], "audio_tracks")

    persisted = Repo.get!(WebhookDelivery, delivery.id)
    assert persisted.state == :succeeded
    assert persisted.attempts == 1
    assert persisted.response_code == 200
    assert persisted.delivered_at
    assert is_nil(persisted.error)
  end

  test "successful webhook delivery stops and marks oversized response diagnostics", %{
    space: space
  } do
    Req.default_options(plug: {Req.Test, __MODULE__})

    Req.Test.stub(__MODULE__, fn conn ->
      conn =
        Enum.reduce(1..80, conn, fn index, conn ->
          put_resp_header(conn, "x-diagnostic-#{index}", String.duplicate("\"", 2_048))
        end)

      conn =
        prepend_resp_headers(
          conn,
          Enum.map(1..7, fn _index ->
            {"x-mave-response-truncated", String.duplicate("\"", 2_048)}
          end)
        )

      conn = send_chunked(conn, 200)
      {:ok, conn} = chunk(conn, String.duplicate("a", 12_000))
      {:ok, conn} = chunk(conn, String.duplicate("b", 12_000))
      {:ok, conn} = chunk(conn, String.duplicate("c", 12_000))
      conn
    end)

    _webhook = create_webhook(space, %{"enabled_events" => [:video_uploaded]})

    assert {:ok, [delivery]} =
             Spaces.enqueue_webhook_event(
               space,
               :video_uploaded,
               %{"id" => "trialabc123"},
               %{enqueue: false}
             )

    assert {:ok, :succeeded} = Spaces.process_webhook_delivery(delivery.id)

    persisted = Repo.get!(WebhookDelivery, delivery.id)
    assert persisted.response_code == 200
    assert byte_size(persisted.response_body) <= 16 * 1_024
    assert String.ends_with?(persisted.response_body, "[mave: response body truncated]")
    assert persisted.response_headers["x-mave-response-truncated"] =~ "body"
    assert persisted.response_headers["x-mave-response-truncated"] =~ "headers"
    assert byte_size(Jason.encode!(persisted.response_headers)) <= 20 * 1_024
  end

  test "process_webhook_delivery retries and then marks as failed", %{space: space} do
    Req.default_options(plug: {Req.Test, __MODULE__})

    Req.Test.expect(__MODULE__, 2, fn conn ->
      send_resp(conn, 500, "internal error")
    end)

    _webhook = create_webhook(space, %{"enabled_events" => [:video_uploaded]})

    assert {:ok, [delivery]} =
             Spaces.enqueue_webhook_event(
               space,
               :video_uploaded,
               %{"id" => "trialabc123", "embed_hash" => "abc123"},
               %{enqueue: false}
             )

    assert {:retry, 2} = Spaces.process_webhook_delivery(delivery.id, %{max_attempts: 2})

    first_attempt = Repo.get!(WebhookDelivery, delivery.id)
    assert first_attempt.state == :pending
    assert first_attempt.attempts == 1
    assert first_attempt.response_code == 500
    assert first_attempt.next_attempt_at

    assert {:ok, :failed} = Spaces.process_webhook_delivery(delivery.id, %{max_attempts: 2})

    second_attempt = Repo.get!(WebhookDelivery, delivery.id)
    assert second_attempt.state == :failed
    assert second_attempt.attempts == 2
    assert second_attempt.response_code == 500
    assert second_attempt.failed_at
    assert is_nil(second_attempt.next_attempt_at)
  end

  test "retryable webhook failure persists only bounded response diagnostics", %{space: space} do
    Req.default_options(plug: {Req.Test, __MODULE__})

    Req.Test.expect(__MODULE__, fn conn ->
      conn =
        Enum.reduce(1..80, conn, fn index, conn ->
          put_resp_header(conn, "x-failure-#{index}", String.duplicate("\"", 2_048))
        end)

      conn = send_chunked(conn, 500)
      {:ok, conn} = chunk(conn, String.duplicate("failure", 6_000))
      conn
    end)

    _webhook = create_webhook(space, %{"enabled_events" => [:video_uploaded]})

    assert {:ok, [delivery]} =
             Spaces.enqueue_webhook_event(
               space,
               :video_uploaded,
               %{"id" => "trialabc123"},
               %{enqueue: false}
             )

    assert {:retry, 2} = Spaces.process_webhook_delivery(delivery.id, %{max_attempts: 2})

    persisted = Repo.get!(WebhookDelivery, delivery.id)
    assert persisted.state == :pending
    assert persisted.response_code == 500
    assert byte_size(persisted.response_body) <= 16 * 1_024
    assert String.ends_with?(persisted.response_body, "[mave: response body truncated]")
    assert persisted.response_headers["x-mave-response-truncated"] =~ "body"
    assert persisted.response_headers["x-mave-response-truncated"] =~ "headers"
    assert byte_size(Jason.encode!(persisted.response_headers)) <= 20 * 1_024
  end

  test "webhook delivery changeset rejects oversized response snapshots" do
    delivery = %WebhookDelivery{}

    body_changeset =
      WebhookDelivery.update_changeset(delivery, %{
        response_body: String.duplicate("b", 16 * 1_024 + 1)
      })

    headers_changeset =
      WebhookDelivery.update_changeset(delivery, %{
        response_headers: %{"x-large" => String.duplicate("h", 20 * 1_024)}
      })

    refute body_changeset.valid?
    assert {"should be at most %{count} byte(s)", _opts} = body_changeset.errors[:response_body]
    refute headers_changeset.valid?
    assert {"is too large", _opts} = headers_changeset.errors[:response_headers]
  end

  test "process_webhook_delivery rejects internal webhook urls without retrying", %{space: space} do
    webhook =
      create_webhook(space, %{
        "url" => "https://127.0.0.1/webhook",
        "enabled_events" => [:video_uploaded]
      })

    assert webhook.url == "https://127.0.0.1/webhook"

    assert {:ok, [delivery]} =
             Spaces.enqueue_webhook_event(
               space,
               :video_uploaded,
               %{"id" => "trialabc123", "embed_hash" => "abc123"},
               %{enqueue: false}
             )

    assert {:ok, :failed} = Spaces.process_webhook_delivery(delivery.id)

    persisted = Repo.get!(WebhookDelivery, delivery.id)
    assert persisted.state == :failed
    assert persisted.attempts == 1
    assert is_nil(persisted.response_code)
    assert is_nil(persisted.next_attempt_at)
    assert persisted.error =~ "unsafe_webhook_url"
    assert persisted.error =~ "blocked_address"
  end

  test "process_webhook_delivery cancels when webhook becomes disabled", %{space: space} do
    webhook = create_webhook(space, %{"enabled_events" => [:video_uploaded]})

    assert {:ok, [delivery]} =
             Spaces.enqueue_webhook_event(
               space,
               :video_uploaded,
               %{"id" => "trialabc123", "embed_hash" => "abc123"},
               %{enqueue: false}
             )

    assert {:ok, _} = Spaces.update_webhook(webhook, %{"enabled" => false})

    assert {:ok, :canceled} = Spaces.process_webhook_delivery(delivery.id)

    persisted = Repo.get!(WebhookDelivery, delivery.id)
    assert persisted.state == :canceled
    assert persisted.failed_at
  end

  test "webhook delivery worker snoozes when delivery is retryable", %{space: space} do
    Req.default_options(plug: {Req.Test, __MODULE__})

    Req.Test.stub(__MODULE__, fn conn ->
      send_resp(conn, 500, "internal error")
    end)

    _webhook = create_webhook(space, %{"enabled_events" => [:video_uploaded]})

    assert {:ok, [delivery]} =
             Spaces.enqueue_webhook_event(
               space,
               :video_uploaded,
               %{"id" => "trialabc123", "embed_hash" => "abc123"},
               %{enqueue: false}
             )

    assert {:snooze, 2} =
             WebhookDeliveryWorker.perform(%Job{args: %{"delivery_id" => delivery.id}})

    assert {:error, "missing delivery_id"} = WebhookDeliveryWorker.perform(%Job{args: %{}})
  end

  defp create_webhook(space, attrs) do
    unique_suffix = System.unique_integer([:positive])

    assert {:ok, webhook} =
             Spaces.create_webhook(space, %{
               "url" => "https://example.com/webhook-#{unique_suffix}",
               "description" => "Delivery webhook #{unique_suffix}"
             })

    case Spaces.update_webhook(webhook, attrs) do
      {:ok, updated_webhook} -> updated_webhook
      {:error, changeset} -> flunk("failed to update webhook: #{inspect(changeset.errors)}")
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)

  defp create_video_embed(space, name) do
    {:ok, embed} = Embeds.create_video_embed(space, %{"name" => name})
    embed
  end

  defp force_space_hash!(space, hash) do
    space
    |> Ecto.Changeset.change(%{hash: hash})
    |> Repo.update!()
  end

  defp insert_renditions(video_id, renditions) do
    video_id_db = MaveCore.LegacyShortUUID.dump!(video_id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(renditions, fn rendition ->
        %{
          id: MaveCore.LegacyShortUUID.dump!(Ecto.UUID.generate()),
          video_id: video_id_db,
          rendition_key: rendition.key,
          type: "video",
          codec: "h264",
          container: rendition.container,
          size: rendition.size,
          progress: 100,
          file_size: 12_345,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all("renditions", rows)
  end
end
