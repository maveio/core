defmodule MaveCore.Analytics.Sessions.Config do
  @moduledoc false

  def from_env!(env) do
    booleans = [
      {"MAVE_ANALYTICS_SESSIONS", :enabled},
      {"MAVE_ANALYTICS_PROCESSOR_ENABLED", :processor_enabled}
    ]

    integers = [
      {"MAVE_ANALYTICS_BUILD_MEMORY_BYTES", :build_memory_bytes},
      {"MAVE_ANALYTICS_READ_MEMORY_BYTES", :read_memory_bytes},
      {"MAVE_ANALYTICS_QUERY_THREADS", :query_threads},
      {"MAVE_ANALYTICS_REFRESH_BUCKET_LIMIT", :refresh_bucket_limit},
      {"MAVE_ANALYTICS_CLEANUP_SPACE_LIMIT", :cleanup_space_limit},
      {"MAVE_ANALYTICS_CLEANUP_GENERATION_LIMIT", :cleanup_generation_limit},
      {"MAVE_ANALYTICS_READER_GRACE_SECONDS", :reader_grace_seconds}
    ]

    Enum.flat_map(booleans, fn {name, key} ->
      case Map.get(env, name) do
        nil -> []
        value when value in ["true", "1"] -> [{key, true}]
        value when value in ["false", "0"] -> [{key, false}]
        _ -> raise ArgumentError, "#{name} must be true, false, 1 or 0"
      end
    end) ++
      Enum.flat_map(integers, fn {name, key} ->
        case Map.get(env, name) do
          nil -> []
          value -> [{key, integer_setting!(name, value)}]
        end
      end) ++ read_spaces(env)
  end

  defp integer_setting!("MAVE_ANALYTICS_READER_GRACE_SECONDS" = name, value) do
    seconds = positive_integer!(name, value)
    if seconds < 120, do: raise(ArgumentError, "#{name} must be at least 120 seconds")
    seconds
  end

  defp integer_setting!(name, value), do: positive_integer!(name, value)

  defp positive_integer!(name, value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _ -> raise ArgumentError, "#{name} must be a positive integer"
    end
  end

  defp read_spaces(env) do
    case Map.get(env, "MAVE_ANALYTICS_READ_SPACES") do
      nil ->
        []

      "*" ->
        [read_spaces: :all]

      value ->
        spaces = value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

        unless Enum.all?(spaces, &Regex.match?(~r/\A[A-Za-z0-9]{5}\z/, &1)),
          do: raise(ArgumentError, "MAVE_ANALYTICS_READ_SPACES must contain space hashes")

        [read_spaces: Enum.uniq(spaces)]
    end
  end
end
