defmodule MaveCore.SpacesWebhookRegistrationTest do
  use MaveCore.DataCase, async: false

  import Plug.Conn
  alias MaveCore.{Accounts, Repo, Spaces}
  alias MaveCore.Spaces.{Webhook, WebhookDelivery}
  alias MaveCore.Workers.WebhookDeliveryWorker

  setup {Req.Test, :verify_on_exit!}

  setup do
    {:ok, user} =
      Accounts.create_user(
        "webhook-registration-#{System.unique_integer([:positive])}@example.com"
      )

    resolver = Application.get_env(:mave_core, :public_http_url_resolver)
    req_options = Req.default_options()

    Application.put_env(:mave_core, :public_http_url_resolver, fn _ ->
      {:ok, [{93, 184, 216, 34}]}
    end)

    on_exit(fn ->
      Req.default_options(req_options)

      if resolver,
        do: Application.put_env(:mave_core, :public_http_url_resolver, resolver),
        else: Application.delete_env(:mave_core, :public_http_url_resolver)
    end)

    %{space: user.current_space_membership.space}
  end

  test "canonical registrations share an ID while different signing secrets stay separate", %{
    space: space
  } do
    {:ok, {first, :created}} = Spaces.register_webhook(space, registration())

    reversed =
      Map.put(registration(), "enabled_events", [
        "video_uploaded",
        "video_ready",
        "video_uploaded"
      ])

    assert {:ok, {same, :existing}} = Spaces.register_webhook(space, reversed)
    assert first.id == same.id

    {:ok, {different, :created}} =
      Spaces.register_webhook(
        space,
        Map.put(registration(), "secret", "synthetic-other-signing-key")
      )

    refute first.id == different.id
  end

  test "delete preserves outbox history, cancels queued retries and does not affect another registration",
       %{space: space} do
    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, {webhook, :created}} = Spaces.register_webhook(space, registration())

      {:ok, {other, :created}} =
        Spaces.register_webhook(
          space,
          Map.put(registration(), "url", "https://example.com/other")
        )

      {:ok, deliveries} = Spaces.enqueue_webhook_event(space, :video_ready)
      delivery = Enum.find(deliveries, &(&1.webhook_id == webhook.id))
      other_delivery = Enum.find(deliveries, &(&1.webhook_id == other.id))

      assert {:ok, _} = Spaces.unregister_webhook(space, webhook.id)

      assert %{state: :canceled, attempts: 0, next_attempt_at: nil} =
               Repo.get!(WebhookDelivery, delivery.id)

      assert %{state: :pending} = Repo.get!(WebhookDelivery, other_delivery.id)
      assert Repo.get!(Webhook, webhook.id).deleted_at
      assert Spaces.get_webhook_for_space(space, webhook.id) == nil
      assert [remaining] = Spaces.list_webhooks(space)
      assert remaining.id == other.id

      job =
        Repo.one!(
          from(j in Oban.Job, where: fragment("?->>'delivery_id'", j.args) == ^delivery.id)
        )

      assert job.state == "cancelled"
      assert {:ok, :canceled} = Spaces.process_webhook_delivery(delivery.id)

      assert {:ok, [next]} =
               Spaces.enqueue_webhook_event(space, :video_ready, %{}, %{enqueue: false})

      assert next.webhook_id == other.id
    end)
  end

  test "a removed webhook cannot be re-enabled using a stale struct", %{space: space} do
    {:ok, {webhook, :created}} = Spaces.register_webhook(space, registration())
    {:ok, _} = Spaces.delete_webhook(webhook)
    assert {:error, :not_found} = Spaces.update_webhook(webhook, %{enabled: true})
    {:ok, {replacement, :created}} = Spaces.register_webhook(space, registration())
    refute replacement.id == webhook.id
  end

  test "an in-flight failed request cannot schedule retries after unsubscribe", %{space: space} do
    {:ok, {webhook, :created}} = Spaces.register_webhook(space, registration())
    {:ok, [delivery]} = Spaces.enqueue_webhook_event(space, :video_ready, %{}, %{enqueue: false})
    Req.default_options(plug: {Req.Test, __MODULE__})

    Req.Test.expect(__MODULE__, fn conn ->
      assert Repo.get!(WebhookDelivery, delivery.id).state == :processing
      {:ok, _} = Spaces.unregister_webhook(space, webhook.id)
      send_resp(conn, 500, "failed")
    end)

    assert :ok = WebhookDeliveryWorker.perform(%Oban.Job{args: %{"delivery_id" => delivery.id}})

    assert %{state: :canceled, attempts: 1, next_attempt_at: nil} =
             Repo.get!(WebhookDelivery, delivery.id)

    assert {:ok, :canceled} = Spaces.process_webhook_delivery(delivery.id)
  end

  test "delivery keeps its original raw-body signing algorithm for registered secrets", %{
    space: space
  } do
    {:ok, {_webhook, :created}} = Spaces.register_webhook(space, registration())

    {:ok, [delivery]} =
      Spaces.enqueue_webhook_event(space, :video_ready, %{"title" => "Unicode café"}, %{
        enqueue: false
      })

    Req.default_options(plug: {Req.Test, __MODULE__})

    Req.Test.expect(__MODULE__, fn conn ->
      {:ok, body, conn} = read_body(conn)
      [header] = get_req_header(conn, "mave-signature")
      [_, timestamp, signature] = Regex.run(~r/^t=(\d+),v1=([a-f0-9]{64})$/, header)

      expected =
        :crypto.mac(:hmac, :sha256, timestamp <> "." <> registration()["secret"], body)
        |> Base.encode16(case: :lower)

      assert Plug.Crypto.secure_compare(signature, expected)
      assert Jason.decode!(body)["type"] == "video.ready"
      send_resp(conn, 200, "ok")
    end)

    assert {:ok, :succeeded} = Spaces.process_webhook_delivery(delivery.id)
  end

  test "a retried job can recover a processing delivery after its previous worker exited", %{
    space: space
  } do
    {:ok, {_webhook, :created}} = Spaces.register_webhook(space, registration())
    {:ok, [delivery]} = Spaces.enqueue_webhook_event(space, :video_ready, %{}, %{enqueue: false})
    delivery |> Ecto.Changeset.change(state: :processing, attempts: 1) |> Repo.update!()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.expect(__MODULE__, &send_resp(&1, 200, "ok"))

    assert {:ok, :succeeded} = Spaces.process_webhook_delivery(delivery.id)
    assert Repo.get!(WebhookDelivery, delivery.id).attempts == 2
  end

  defp registration do
    %{
      "url" => "https://example.com/hook",
      "secret" => "synthetic-registration-signing-key",
      "enabled_events" => ["video_ready", "video_uploaded"]
    }
  end
end
