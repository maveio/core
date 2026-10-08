defmodule MaveCore.TestLoggerFilters do
  def db_connection_client_exit(%{level: :error, msg: msg}, _config) do
    message = logger_message_to_string(msg)

    if String.contains?(message, "Postgrex.Protocol") and
         String.contains?(message, "disconnected: ** (DBConnection.ConnectionError) client #PID") and
         String.contains?(message, " exited") do
      :stop
    else
      :ignore
    end
  end

  def db_connection_client_exit(_event, _config), do: :ignore

  defp logger_message_to_string({:string, message}), do: IO.iodata_to_binary(message)
  defp logger_message_to_string(message) when is_binary(message), do: message
  defp logger_message_to_string(message) when is_list(message), do: IO.iodata_to_binary(message)
  defp logger_message_to_string(message), do: inspect(message)
end

# Keep expected sandbox client-exit banners out of passing test output without hiding other DB errors.
_ = :logger.remove_primary_filter(:mave_core_test_db_connection_client_exit)

:ok =
  :logger.add_primary_filter(
    :mave_core_test_db_connection_client_exit,
    {&MaveCore.TestLoggerFilters.db_connection_client_exit/2, []}
  )

_ = Application.ensure_all_started(:mave_core)

if System.get_env("SKIP_INTEGRATION") in ["1", "true", "TRUE"] do
  ExUnit.configure(exclude: [integration: true])
else
  case MaveCore.IntegrationSeeds.maybe_seed!() do
    :ok ->
      :ok

    {:skipped, reason} ->
      raise """
      Integration tests are enabled by default, but required dependencies are missing: #{reason}

      Start local deps (see CONTRIBUTING.md) and ensure `ffmpeg` is installed,
      or opt out with `SKIP_INTEGRATION=true`.
      """
  end
end

ExUnit.start(capture_log: true)
Ecto.Adapters.SQL.Sandbox.mode(MaveCore.Repo, :manual)

# Only load support files if not already compiled (avoids warnings when run as dependency)
unless Code.ensure_loaded?(MaveCore.DataCase) do
  Code.require_file("test/support/data_case.ex")
end

unless Code.ensure_loaded?(MaveCoreWeb.ConnCase) do
  Code.require_file("test/support/conn_case.ex")
end

unless Code.ensure_loaded?(MaveCore.IntegrationSeeds) do
  File.ls!("test/support")
  |> Enum.filter(fn file -> file not in ["data_case.ex", "conn_case.ex"] end)
  |> Enum.each(fn file ->
    Code.require_file("test/support/#{file}")
  end)
end
