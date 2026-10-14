defmodule MaveCore.WebhookRegistrationConcurrencyTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MaveCore.{Repo, Spaces}
  alias MaveCore.Spaces.Space

  test "independent concurrent registrations return one persisted subscription" do
    supervisor = start_supervised!(Task.Supervisor)
    resolver = Application.get_env(:mave_core, :public_http_url_resolver)

    Application.put_env(:mave_core, :public_http_url_resolver, fn _ ->
      {:ok, [{93, 184, 216, 34}]}
    end)

    on_exit(fn ->
      if resolver,
        do: Application.put_env(:mave_core, :public_http_url_resolver, resolver),
        else: Application.delete_env(:mave_core, :public_http_url_resolver)
    end)

    Sandbox.unboxed_run(Repo, fn ->
      space =
        Repo.insert!(%Space{hash: "webhook-race-#{Ecto.UUID.generate()}", region: "default"})

      try do
        owner = self()

        tasks =
          for events <- [["video_ready", "video_uploaded"], ["video_uploaded", "video_ready"]] do
            Task.Supervisor.async(supervisor, fn ->
              Sandbox.unboxed_run(Repo, fn ->
                send(owner, {:ready, self()})
                receive do: (:register -> Spaces.register_webhook(space, registration(events)))
              end)
            end)
          end

        assert_receive {:ready, first}
        assert_receive {:ready, second}
        send(first, :register)
        send(second, :register)

        results = Enum.map(tasks, &Task.await/1)
        assert Enum.count(results, &match?({:ok, {_, :created}}, &1)) == 1
        assert Enum.count(results, &match?({:ok, {_, :existing}}, &1)) == 1
        assert [webhook] = Spaces.list_webhooks(space)
        assert Enum.all?(results, fn {:ok, {registered, _}} -> registered.id == webhook.id end)
      after
        # Delete only the synthetic committed fixture, including its webhook rows.
        Repo.delete!(space)
      end
    end)
  end

  defp registration(events) do
    %{
      "url" => "https://example.com/parallel-hook",
      "enabled_events" => events,
      "secret" => "synthetic-parallel-signing-key"
    }
  end
end
