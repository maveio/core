defmodule MaveCoreWeb.Plugs.EventIngestRateLimitTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias MaveCoreWeb.Plugs.EventIngestRateLimit

  setup do
    previous = Application.get_env(:mave_core, EventIngestRateLimit)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:mave_core, EventIngestRateLimit)
      else
        Application.put_env(:mave_core, EventIngestRateLimit, previous)
      end
    end)

    Application.delete_env(:mave_core, EventIngestRateLimit)
    :ok
  end

  test "ignores spoofed forwarding headers by default" do
    opts = opts()

    first =
      request_conn({10, 0, 0, 1})
      |> put_req_header("x-real-ip", "203.0.113.10")
      |> put_req_header("x-forwarded-for", "203.0.113.10")
      |> EventIngestRateLimit.call(opts)

    second =
      request_conn({10, 0, 0, 1})
      |> put_req_header("x-real-ip", "203.0.113.11")
      |> put_req_header("x-forwarded-for", "203.0.113.11")
      |> EventIngestRateLimit.call(opts)

    third =
      request_conn({10, 0, 0, 2})
      |> put_req_header("x-forwarded-for", "203.0.113.11")
      |> EventIngestRateLimit.call(opts)

    refute first.halted
    assert second.halted
    assert second.status == 429
    refute third.halted
  end

  test "uses a sanitized forwarded chain only for a configured trusted proxy" do
    trust(["10.0.0.0/24"])
    opts = opts()

    first =
      request_conn({10, 0, 0, 1})
      |> put_req_header("x-forwarded-for", "203.0.113.20, 10.0.0.2")
      |> EventIngestRateLimit.call(opts)

    second =
      request_conn({10, 0, 0, 1})
      |> put_req_header("x-forwarded-for", "203.0.113.20, 10.0.0.2")
      |> EventIngestRateLimit.call(opts)

    third =
      request_conn({10, 0, 0, 1})
      |> put_req_header("x-forwarded-for", "203.0.113.21, 10.0.0.2")
      |> EventIngestRateLimit.call(opts)

    refute first.halted
    assert second.halted
    assert second.status == 429
    refute third.halted
  end

  test "ignores x-real-ip even when the immediate peer is trusted" do
    trust(["10.0.0.1/32"])
    opts = opts()

    first =
      request_conn({10, 0, 0, 1})
      |> put_req_header("x-real-ip", "203.0.113.30")
      |> EventIngestRateLimit.call(opts)

    second =
      request_conn({10, 0, 0, 1})
      |> put_req_header("x-real-ip", "203.0.113.31")
      |> EventIngestRateLimit.call(opts)

    refute first.halted
    assert second.halted
    assert second.status == 429
  end

  test "fails closed for malformed or duplicate forwarded chains" do
    trust(["10.0.0.1/32"])
    opts = opts()

    first =
      request_conn({10, 0, 0, 1})
      |> put_req_header("x-forwarded-for", "203.0.113.40, invalid")
      |> EventIngestRateLimit.call(opts)

    duplicate_headers =
      request_conn({10, 0, 0, 1})
      |> Map.update!(:req_headers, fn headers ->
        [
          {"x-forwarded-for", "203.0.113.41"},
          {"x-forwarded-for", "203.0.113.42"}
          | headers
        ]
      end)

    second = EventIngestRateLimit.call(duplicate_headers, opts)

    refute first.halted
    assert second.halted
    assert second.status == 429
  end

  test "normalizes IPv4-mapped IPv6 peers before checking trust" do
    trust(["10.0.0.1/32"])
    opts = opts()
    mapped_proxy = {0, 0, 0, 0, 0, 65_535, 2560, 1}

    first =
      request_conn(mapped_proxy)
      |> put_req_header("x-forwarded-for", "2001:db8::1")
      |> EventIngestRateLimit.call(opts)

    second =
      request_conn(mapped_proxy)
      |> put_req_header("x-forwarded-for", "2001:db8::1")
      |> EventIngestRateLimit.call(opts)

    refute first.halted
    assert second.halted
    assert second.status == 429
  end

  defp request_conn(remote_ip) do
    :post
    |> conn("/v1/events", %{})
    |> Map.put(:remote_ip, remote_ip)
  end

  defp trust(cidrs) do
    Application.put_env(:mave_core, EventIngestRateLimit, trusted_proxy_cidrs: cidrs)
  end

  defp opts do
    [
      bucket: "events-test-#{System.unique_integer([:positive])}",
      interval_ms: 60_000,
      max_requests: 1
    ]
  end
end
