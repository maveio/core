defmodule MaveCore.K8sAPITestPlug do
  @moduledoc false

  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{method: "POST"} = conn, opts) do
    {:ok, body, conn} = read_body(conn)
    probe = Keyword.fetch!(opts, :probe)
    notify(probe, conn, body)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(201, Jason.encode!(%{"metadata" => %{"name" => "runner-test"}}))
  end

  def call(
        %Plug.Conn{
          method: "GET",
          request_path: "/api/v1/namespaces/default/pods/parent-test"
        } = conn,
        opts
      ) do
    probe = Keyword.fetch!(opts, :probe)
    notify(probe, conn, nil)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{"metadata" => %{"name" => "parent-test", "uid" => "parent-uid"}})
    )
  end

  def call(%Plug.Conn{method: "GET"} = conn, opts) do
    probe = Keyword.fetch!(opts, :probe)

    %{owner: owner, parent_ref: parent_ref, remote_terminator_pid: remote_terminator_pid} =
      Agent.get(probe, & &1)

    notify(probe, conn, nil)
    send(owner, {parent_ref, {:remote_up, remote_terminator_pid}})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{
        "metadata" => %{"name" => "runner-test"},
        "status" => %{"podIP" => "127.0.0.1"}
      })
    )
  end

  def call(%Plug.Conn{method: "DELETE"} = conn, opts) do
    probe = Keyword.fetch!(opts, :probe)
    notify(probe, conn, nil)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{"status" => "Success"}))
  end

  defp notify(probe, conn, body) do
    %{owner: owner} = Agent.get(probe, & &1)

    send(
      owner,
      {:k8s_api_request, conn.method, conn.request_path,
       List.first(get_req_header(conn, "authorization")), body}
    )
  end
end
