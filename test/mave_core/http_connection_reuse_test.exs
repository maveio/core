defmodule MaveCore.HTTPConnectionReuseTest do
  use ExUnit.Case, async: true

  for status <- [206, 409], partial_body? <- [false, true] do
    @tag status: status, partial_body?: partial_body?
    test "a timeout before #{status} with partial body #{partial_body?} cannot contaminate the next request",
         %{status: status, partial_body?: partial_body?} do
      parent = self()

      server =
        start_supervised!({Task,
         fn ->
           {:ok, listener} =
             :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

           {:ok, port} = :inet.port(listener)
           send(parent, {:listening, port})
           {:ok, first} = :gen_tcp.accept(listener, 5_000)
           {:ok, _request} = :gen_tcp.recv(first, 0, 5_000)

           if partial_body? do
             :ok = :gen_tcp.send(first, response(status, "stale", false))
           end

           # The server stays silent until the client times out. On broken
           # clients it receives the next request on this unfinished stream.
           case :gen_tcp.recv(first, 0, 5_000) do
             {:error, :closed} ->
               {:ok, second} = :gen_tcp.accept(listener, 5_000)
               {:ok, _request} = :gen_tcp.recv(second, 0, 5_000)
               :ok = :gen_tcp.send(second, response(200, "fresh", true))
               :gen_tcp.close(second)
               send(parent, :fresh_connection)

             {:ok, _next_request} ->
               late = if partial_body?, do: "stale", else: response(status, "stale", true)
               :gen_tcp.send(first, late <> response(200, "fresh", true))
               :gen_tcp.close(first)
               send(parent, :reused_unfinished_connection)
           end

           :gen_tcp.close(listener)
         end})

      monitor = Process.monitor(server)
      assert_receive {:listening, port}, 1_000
      # Each generated test has its own Finch registry and a single connection,
      # making reuse deterministic rather than relying on pool selection.
      name =
        unquote(
          String.to_atom("Elixir.MaveCore.HTTPConnectionReuseTest.Pool#{status}#{partial_body?}")
        )

      start_supervised!({Finch, name: name, pools: %{default: [size: 1, count: 1]}})
      request = Finch.build(:get, "http://127.0.0.1:#{port}/media")

      assert {:error, %{reason: :timeout}} = Finch.request(request, name, receive_timeout: 50)

      assert {:ok, %{status: 200, body: "fresh"}} =
               Finch.request(request, name, receive_timeout: 2_000)

      assert_receive :fresh_connection
      assert_receive {:DOWN, ^monitor, :process, ^server, :normal}
      refute_received :reused_unfinished_connection
    end
  end

  test "completed responses still reuse the connection" do
    parent = self()

    server =
      start_supervised!(
        {Task,
         fn ->
           {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
           {:ok, port} = :inet.port(listener)
           send(parent, {:listening, port})
           {:ok, socket} = :gen_tcp.accept(listener, 5_000)

           for _ <- 1..2 do
             {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)
             :ok = :gen_tcp.send(socket, response(200, "fresh", true))
           end

           :gen_tcp.close(socket)
           :gen_tcp.close(listener)
         end}
      )

    monitor = Process.monitor(server)
    assert_receive {:listening, port}, 1_000
    name = __MODULE__.SuccessfulPool
    start_supervised!({Finch, name: name, pools: %{default: [size: 1, count: 1]}})
    request = Finch.build(:get, "http://127.0.0.1:#{port}/media")

    for _ <- 1..2 do
      assert {:ok, %{status: 200, body: "fresh"}} = Finch.request(request, name)
    end

    assert_receive {:DOWN, ^monitor, :process, ^server, :normal}
  end

  defp response(status, body, complete?) do
    "HTTP/1.1 #{status} Response\r\nContent-Length: #{byte_size(body)}\r\n\r\n" <>
      if(complete?, do: body, else: "")
  end
end
