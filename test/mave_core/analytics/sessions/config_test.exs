defmodule MaveCore.Analytics.Sessions.ConfigTest do
  use ExUnit.Case, async: true

  alias MaveCore.Analytics.Sessions.Config

  test "unset rollout settings leave application defaults intact" do
    assert Config.from_env!(%{}) == []
  end

  test "processing can be enabled independently of a scoped reader" do
    settings =
      Config.from_env!(%{
        "MAVE_ANALYTICS_SESSIONS" => "false",
        "MAVE_ANALYTICS_PROCESSOR_ENABLED" => "true",
        "MAVE_ANALYTICS_READ_SPACES" => "AAAAA, BBBBB,AAAAA",
        "MAVE_ANALYTICS_BUILD_MEMORY_BYTES" => "2147483648",
        "MAVE_ANALYTICS_REFRESH_BUCKET_LIMIT" => "4",
        "MAVE_ANALYTICS_CLEANUP_SPACE_LIMIT" => "32"
      })

    assert settings[:enabled] == false
    assert settings[:processor_enabled] == true
    assert settings[:read_spaces] == ["AAAAA", "BBBBB"]
    assert settings[:build_memory_bytes] == 2_147_483_648
    assert settings[:refresh_bucket_limit] == 4
    assert settings[:cleanup_space_limit] == 32
    assert Config.from_env!(%{"MAVE_ANALYTICS_READ_SPACES" => ""}) == [read_spaces: []]
    assert Config.from_env!(%{"MAVE_ANALYTICS_READ_SPACES" => "*"}) == [read_spaces: :all]

    assert Config.from_env!(%{"MAVE_ANALYTICS_PROCESS_SPACES" => "AAAAA,AAAAA"}) ==
             [process_spaces: ["AAAAA"]]

    assert Config.from_env!(%{"MAVE_ANALYTICS_PROCESS_SPACES" => "*"}) == [process_spaces: :all]
    assert Config.from_env!(%{"MAVE_ANALYTICS_PROCESS_SPACES" => ""}) == [process_spaces: []]
  end

  test "invalid rollout settings fail startup instead of enabling an unintended scope" do
    for env <- [
          %{"MAVE_ANALYTICS_SESSIONS" => "yes"},
          %{"MAVE_ANALYTICS_PROCESSOR_ENABLED" => "typo"},
          %{"MAVE_ANALYTICS_QUERY_THREADS" => "0"},
          %{"MAVE_ANALYTICS_READ_MEMORY_BYTES" => "-1"},
          %{"MAVE_ANALYTICS_READER_GRACE_SECONDS" => "119"},
          %{"MAVE_ANALYTICS_READ_SPACES" => "invalid"},
          %{"MAVE_ANALYTICS_PROCESS_SPACES" => "invalid"}
        ] do
      assert_raise ArgumentError, fn -> Config.from_env!(env) end
    end
  end
end
