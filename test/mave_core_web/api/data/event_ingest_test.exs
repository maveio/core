defmodule MaveCoreWeb.Api.Data.EventIngestTest do
  use ExUnit.Case, async: true
  alias MaveCoreWeb.Api.Data.EventIngest

  @session_id "12090000-0000-4000-8000-000000000001"

  describe "validate_and_enrich/2" do
    test "sanitizes source_url by removing query params and fragments" do
      now_ms = System.system_time(:millisecond)
      source_url = "https://example.com/page?token=secret#section"

      event = %{
        "name" => "test_event",
        "session_id" => @session_id,
        "timestamp" => now_ms,
        "source_url" => source_url
      }

      {:ok, [enriched_event]} = EventIngest.validate_and_enrich([event], "test-agent")

      expected_url = "https://example.com/page"
      assert enriched_event["source_url"] == expected_url
    end

    test "keeps source_url intact if no query params" do
      now_ms = System.system_time(:millisecond)
      source_url = "https://example.com/page"

      event = %{
        "name" => "test_event",
        "session_id" => @session_id,
        "timestamp" => now_ms,
        "source_url" => source_url
      }

      {:ok, [enriched_event]} = EventIngest.validate_and_enrich([event], "test-agent")

      assert enriched_event["source_url"] == source_url
    end

    test "handles nil source_url gracefully" do
      now_ms = System.system_time(:millisecond)

      event = %{
        "name" => "test_event",
        "session_id" => @session_id,
        "timestamp" => now_ms
      }

      {:ok, [enriched_event]} = EventIngest.validate_and_enrich([event], "test-agent")

      refute Map.has_key?(enriched_event, "source_url")
    end

    test "clamps future timestamps to now_ms" do
      now_ms = System.system_time(:millisecond)
      # ~16 minutes in future
      future_ts = now_ms + 1_000_000

      event = %{
        "name" => "future_event",
        "session_id" => @session_id,
        "timestamp" => future_ts
      }

      {:ok, [enriched_event]} = EventIngest.validate_and_enrich([event], "test-agent")

      assert enriched_event["timestamp"] >= now_ms
      assert enriched_event["timestamp"] <= System.system_time(:millisecond)
    end

    test "clamps too old timestamps to now_ms" do
      now_ms = System.system_time(:millisecond)
      # 25 hours ago (limit is 24h)
      old_ts = now_ms - 25 * 60 * 60 * 1000

      event = %{
        "name" => "old_event",
        "session_id" => @session_id,
        "timestamp" => old_ts
      }

      {:ok, [enriched_event]} = EventIngest.validate_and_enrich([event], "test-agent")

      assert enriched_event["timestamp"] >= now_ms
      assert enriched_event["timestamp"] <= System.system_time(:millisecond)
    end

    test "rejects an invalid session UUID before enqueueing" do
      event = %{
        "name" => "play",
        "session_id" => "not-a-uuid",
        "timestamp" => System.system_time(:millisecond)
      }

      assert {:error, {:invalid_event, 0, {:invalid, "session_id"}}} =
               EventIngest.validate_and_enrich([event], "test-agent")
    end
  end
end
