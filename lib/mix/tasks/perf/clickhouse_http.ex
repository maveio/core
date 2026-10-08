defmodule Mix.Tasks.Perf.ClickHouseHTTP do
  @moduledoc false

  @type conn_opts :: [
          host: String.t(),
          port: pos_integer(),
          scheme: String.t(),
          database: String.t(),
          username: String.t(),
          password: String.t()
        ]

  def conn_opts_from_env do
    [
      host: System.get_env("CLICKHOUSE_HOST") || "localhost",
      port: env_int("CLICKHOUSE_PORT", 8123),
      scheme: System.get_env("CLICKHOUSE_SCHEME") || "http",
      database: System.get_env("CLICKHOUSE_DATABASE") || "mave_metrics",
      username: System.get_env("CLICKHOUSE_USER") || "default",
      password: System.get_env("CLICKHOUSE_PASSWORD") || "password"
    ]
  end

  def execute!(sql, opts \\ []) when is_binary(sql) do
    ensure_req_started!()

    opts = Keyword.merge(conn_opts_from_env(), opts)

    url =
      "#{opts[:scheme]}://#{opts[:host]}:#{opts[:port]}/?database=#{URI.encode_www_form(opts[:database])}&user=#{URI.encode_www_form(opts[:username])}&password=#{URI.encode_www_form(opts[:password])}"

    resp =
      Req.post!(url,
        body: sql,
        headers: [
          {"content-type", "text/plain"}
        ],
        receive_timeout: 60_000
      )

    if resp.status not in 200..299 do
      raise "ClickHouse HTTP error status=#{resp.status}: #{inspect(resp.body)}"
    end

    resp
  end

  defp ensure_req_started! do
    _ = Application.ensure_all_started(:telemetry)
    _ = Application.ensure_all_started(:finch)
    _ = Application.ensure_all_started(:req)

    case Process.whereis(Req.Finch) do
      nil ->
        case Finch.start_link(name: Req.Finch) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> raise "failed to start Req.Finch: #{inspect(reason)}"
        end

      _pid ->
        :ok
    end
  end

  defp env_int(name, default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      value -> String.to_integer(value)
    end
  rescue
    _ -> default
  end
end
