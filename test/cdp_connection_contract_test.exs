defmodule SpectreLens.CDPConnectionContractTest do
  use ExUnit.Case, async: true

  alias SpectreLens.CDP.Connection
  alias SpectreLens.CDPError
  alias SpectreLens.ConnectionError
  alias SpectreLens.TestCDP
  alias SpectreLens.TimeoutError

  test "send_command preserves protocol errors and cancels timed out work" do
    {:ok, conn} = TestCDP.start(owner: self())
    on_exit(fn -> if Process.alive?(conn), do: GenServer.stop(conn) end)

    assert :ok = TestCDP.queue_reply(conn, "Runtime.fail", {:error, -32_001, "not ready"})

    assert {:error, %CDPError{code: -32_001, method: "Runtime.fail", message: message}} =
             Connection.send_command(conn, "Runtime.fail")

    assert message =~ "not ready"

    assert :ok = TestCDP.queue_reply(conn, "Runtime.odd", {:error, %{reason: :bad_shape}})

    assert {:error, %CDPError{code: 0, method: "Runtime.odd", message: odd_message}} =
             Connection.send_command(conn, "Runtime.odd")

    assert odd_message =~ "bad_shape"

    assert :ok =
             TestCDP.queue_reply(conn, "Runtime.echo", fn method, params, session_id ->
               {:ok, %{"method" => method, "params" => params, "session" => session_id}}
             end)

    assert {:ok,
            %{
              "method" => "Runtime.echo",
              "params" => %{value: 7},
              "session" => "session-7"
            }} =
             Connection.send_command(
               conn,
               "Runtime.echo",
               %{value: 7},
               100,
               "session-7"
             )

    assert :ok = TestCDP.queue_reply(conn, "Runtime.slow", :ignore)

    assert {:error, %TimeoutError{operation: "Runtime.slow", timeout_ms: 0}} =
             Connection.send_command(conn, "Runtime.slow", %{}, 0)

    assert_receive {:test_cdp_command, "Runtime.fail", %{}, nil}
    assert_receive {:test_cdp_command, "Runtime.odd", %{}, nil}
    assert_receive {:test_cdp_command, "Runtime.echo", %{value: 7}, "session-7"}
    assert_receive {:test_cdp_command, "Runtime.slow", %{}, nil}
  end

  test "event waiters support scoped delivery, errors, cancellation and bare refs" do
    {:ok, conn} = TestCDP.start()
    on_exit(fn -> if Process.alive?(conn), do: GenServer.stop(conn) end)

    waiter = Connection.register_event_waiter(conn, "Page.ready", "session-1")
    TestCDP.emit(conn, "Page.ready", "other-session", %{"wrong" => true})
    TestCDP.emit(conn, "Page.ready", "session-1", %{"ready" => true})
    assert {:ok, %{"ready" => true}} = Connection.await_event(waiter, 100)

    task =
      Task.async(fn ->
        Connection.wait_for_event(conn, "Page.fallback", 100, nil)
      end)

    assert wait_until(fn ->
             :sys.get_state(conn).waiters
             |> Map.has_key?({"Page.fallback", nil})
           end)

    TestCDP.emit(conn, "Page.fallback", "session-2", %{"fallback" => true})
    assert {:ok, %{"fallback" => true}} = Task.await(task)

    cancelled = Connection.register_event_waiter(conn, "Page.never")
    assert :ok = Connection.cancel_event_waiter(cancelled)
    assert {:error, %TimeoutError{timeout_ms: 0}} = Connection.await_event(cancelled, 0)

    tuple_error_ref = make_ref()
    send(self(), {:spectre_lens_cdp_event_error, tuple_error_ref, :closed})

    assert {:error, %ConnectionError{reason: :closed}} =
             Connection.await_event({conn, tuple_error_ref}, 10)

    bare_success_ref = make_ref()
    send(self(), {:spectre_lens_cdp_event, bare_success_ref, %{value: 1}})
    assert {:ok, %{value: 1}} = Connection.await_event(bare_success_ref, 10)

    bare_error_ref = make_ref()
    send(self(), {:spectre_lens_cdp_event_error, bare_error_ref, :detached})

    assert {:error, %ConnectionError{reason: :detached}} =
             Connection.await_event(bare_error_ref, 10)

    assert {:error, %TimeoutError{operation: :await_event, timeout_ms: 0}} =
             Connection.await_event(make_ref(), 0)
  end

  test "subscriptions are persistent, de-duplicated and removable" do
    {:ok, conn} = TestCDP.start()
    on_exit(fn -> if Process.alive?(conn), do: GenServer.stop(conn) end)

    assert :ok = Connection.subscribe_event(conn, "Network.request", nil)
    assert :ok = Connection.subscribe_event(conn, "Network.request", nil)
    assert :ok = Connection.subscribe_event(conn, "Network.request", "session-1")

    TestCDP.emit(conn, "Network.request", "session-1", %{"url" => "https://example.com"})

    assert_receive {:spectre_lens_cdp_event, ^conn, "Network.request", "session-1",
                    %{"url" => "https://example.com"}}

    refute_receive {:spectre_lens_cdp_event, ^conn, "Network.request", "session-1", _}, 10

    assert :ok = Connection.unsubscribe_event(conn, "Network.request", nil)
    assert :ok = Connection.unsubscribe_event(conn, "Network.request", "session-1")
    TestCDP.emit(conn, "Network.request", "session-1", %{})
    refute_receive {:spectre_lens_cdp_event, ^conn, "Network.request", _, _}, 10
  end

  test "callback routing correlates command responses and ignores unrelated frames" do
    command_ref = make_ref()

    assert {:reply, {:text, encoded}, state} =
             Connection.handle_cast(
               {:send_command, "Runtime.evaluate", %{expression: "1 + 1"}, nil, self(),
                command_ref},
               connection_state()
             )

    assert %{
             "id" => 1,
             "method" => "Runtime.evaluate",
             "params" => %{"expression" => "1 + 1"}
           } = Jason.decode!(encoded)

    refute Map.has_key?(Jason.decode!(encoded), "sessionId")

    assert {:ok, state} =
             Connection.handle_frame(
               {:text, Jason.encode!(%{"id" => 1, "result" => %{"value" => 2}})},
               state
             )

    assert_receive {:spectre_lens_cdp_response, ^command_ref, %{"value" => 2}}
    assert state.pending == %{}
    assert state.pending_refs == %{}
    assert state.monitors == %{}

    error_ref = make_ref()

    assert {:reply, {:text, encoded}, state} =
             Connection.handle_cast(
               {:send_command, "Page.navigate", %{url: "bad:"}, "session-1", self(), error_ref},
               state
             )

    assert %{"id" => 2, "sessionId" => "session-1"} = Jason.decode!(encoded)
    protocol_error = %{"code" => -32_602, "message" => "invalid URL"}

    assert {:ok, state} =
             Connection.handle_frame(
               {:text, Jason.encode!(%{"id" => 2, "error" => protocol_error})},
               state
             )

    assert_receive {:spectre_lens_cdp_error, ^error_ref, ^protocol_error}

    assert {:ok, ^state} =
             Connection.handle_frame(
               {:text, Jason.encode!(%{"id" => 999, "result" => %{}})},
               state
             )

    assert {:ok, ^state} =
             Connection.handle_frame({:text, Jason.encode!(%{"other" => true})}, state)

    assert {:ok, ^state} = Connection.handle_frame({:text, "not-json"}, state)
    assert {:ok, ^state} = Connection.handle_frame({:binary, <<1, 2, 3>>}, state)
    assert {:ok, ^state} = Connection.handle_info(:unrelated, state)
  end

  test "callback event routing prefers exact waiters and falls back to unscoped ones" do
    exact_ref = make_ref()
    fallback_ref = make_ref()
    first_ref = make_ref()
    second_ref = make_ref()

    {:ok, state} =
      Connection.handle_cast(
        {:wait_event, "Page.ready", "session-1", self(), exact_ref},
        connection_state()
      )

    {:ok, state} =
      Connection.handle_cast({:wait_event, "Page.ready", nil, self(), fallback_ref}, state)

    {:ok, state} =
      Connection.handle_cast({:subscribe_event, "Page.ready", nil, self()}, state)

    {:ok, state} =
      Connection.handle_cast({:subscribe_event, "Page.ready", nil, self()}, state)

    {:ok, state} =
      Connection.handle_cast({:subscribe_event, "Page.ready", "session-1", self()}, state)

    params = %{"sequence" => 1}

    assert {:ok, state} =
             Connection.handle_frame(
               {:text,
                Jason.encode!(%{
                  "method" => "Page.ready",
                  "sessionId" => "session-1",
                  "params" => params
                })},
               state
             )

    assert_receive {:spectre_lens_cdp_event, ^exact_ref, ^params}
    assert_receive {:spectre_lens_cdp_event, _connection, "Page.ready", "session-1", ^params}
    refute_receive {:spectre_lens_cdp_event, _connection, "Page.ready", "session-1", ^params}, 10

    assert {:ok, state} =
             Connection.handle_frame(
               {:text,
                Jason.encode!(%{
                  "method" => "Page.ready",
                  "sessionId" => "session-2",
                  "params" => %{"sequence" => 2}
                })},
               state
             )

    assert_receive {:spectre_lens_cdp_event, ^fallback_ref, %{"sequence" => 2}}

    {:ok, state} =
      Connection.handle_cast({:wait_event, "Page.batch", nil, self(), first_ref}, state)

    {:ok, state} =
      Connection.handle_cast({:wait_event, "Page.batch", nil, self(), second_ref}, state)

    assert {:ok, state} =
             Connection.handle_frame(
               {:text, Jason.encode!(%{"method" => "Page.batch", "params" => %{index: 1}})},
               state
             )

    assert_receive {:spectre_lens_cdp_event, ^second_ref, %{"index" => 1}}
    assert Map.has_key?(state.event_waiters, {"Page.batch", nil})

    assert {:ok, state} =
             Connection.handle_frame(
               {:text, Jason.encode!(%{"method" => "Page.batch", "params" => %{index: 2}})},
               state
             )

    assert_receive {:spectre_lens_cdp_event, ^first_ref, %{"index" => 2}}
    refute Map.has_key?(state.event_waiters, {"Page.batch", nil})

    assert {:ok, state} =
             Connection.handle_frame(
               {:text, Jason.encode!(%{"method" => "Page.unobserved"})},
               state
             )

    assert {:ok, state} =
             Connection.handle_cast({:unsubscribe_event, "Page.ready", nil, self()}, state)

    assert {:ok, state} =
             Connection.handle_cast(
               {:unsubscribe_event, "Page.ready", "session-1", self()},
               state
             )

    assert state.subscribers == %{}
  end

  test "owner monitors clean every kind of abandoned registration" do
    pending_owner = sleeping_process()
    pending_ref = make_ref()

    {:reply, _frame, state} =
      Connection.handle_cast(
        {:send_command, "Runtime.evaluate", %{}, nil, pending_owner, pending_ref},
        connection_state()
      )

    pending_monitor = state.pending[1].monitor
    Process.exit(pending_owner, :kill)
    assert_receive {:DOWN, ^pending_monitor, :process, ^pending_owner, :killed}

    assert {:ok, state} =
             Connection.handle_info(
               {:DOWN, pending_monitor, :process, pending_owner, :killed},
               state
             )

    assert state.pending == %{}
    assert state.pending_refs == %{}

    waiter_owner = sleeping_process()
    waiter_ref = make_ref()
    other_waiter_ref = make_ref()

    {:ok, state} =
      Connection.handle_cast(
        {:wait_event, "Page.ready", nil, waiter_owner, waiter_ref},
        state
      )

    {:ok, state} =
      Connection.handle_cast(
        {:wait_event, "Page.ready", nil, self(), other_waiter_ref},
        state
      )

    waiter_monitor =
      state.monitors
      |> Enum.find_value(fn {monitor, registration} ->
        if registration == {:waiter, {"Page.ready", nil}, waiter_owner, waiter_ref},
          do: monitor
      end)

    Process.exit(waiter_owner, :kill)
    assert_receive {:DOWN, ^waiter_monitor, :process, ^waiter_owner, :killed}

    assert {:ok, state} =
             Connection.handle_info(
               {:DOWN, waiter_monitor, :process, waiter_owner, :killed},
               state
             )

    assert [%{ref: ^other_waiter_ref}] = state.event_waiters[{"Page.ready", nil}]

    subscriber = sleeping_process()

    {:ok, state} =
      Connection.handle_cast({:subscribe_event, "Page.ready", nil, subscriber}, state)

    {:ok, unchanged} =
      Connection.handle_cast({:subscribe_event, "Page.ready", nil, subscriber}, state)

    assert unchanged == state

    subscriber_monitor = state.subscribers[{"Page.ready", nil}][subscriber]
    Process.exit(subscriber, :kill)
    assert_receive {:DOWN, ^subscriber_monitor, :process, ^subscriber, :killed}

    assert {:ok, state} =
             Connection.handle_info(
               {:DOWN, subscriber_monitor, :process, subscriber, :killed},
               state
             )

    refute Map.has_key?(state.subscribers, {"Page.ready", nil})

    assert {:ok, ^state} =
             Connection.handle_info({:DOWN, make_ref(), :process, self(), :normal}, state)
  end

  test "cancellation is idempotent even when indexes and registrations race" do
    unknown_ref = make_ref()
    state = connection_state()
    assert {:ok, ^state} = Connection.handle_cast({:cancel_command, self(), unknown_ref}, state)

    assert {:ok, ^state} =
             Connection.handle_cast({:cancel_event_waiter, self(), unknown_ref}, state)

    missing_command_ref = make_ref()

    indexed_command = %{
      state
      | pending_refs: %{{self(), missing_command_ref} => 77}
    }

    assert {:ok, cancelled} =
             Connection.handle_cast(
               {:cancel_command, self(), missing_command_ref},
               indexed_command
             )

    assert cancelled.pending_refs == %{}

    missing_waiter_ref = make_ref()

    indexed_waiter = %{
      state
      | waiter_refs: %{{self(), missing_waiter_ref} => {"Page.ready", nil}},
        event_waiters: %{{"Page.ready", nil} => []}
    }

    assert {:ok, cancelled} =
             Connection.handle_cast(
               {:cancel_event_waiter, self(), missing_waiter_ref},
               indexed_waiter
             )

    assert cancelled.waiter_refs == %{}
    assert cancelled.event_waiters == %{}
  end

  test "termination wakes pending callers and event waiters with useful reasons" do
    command_ref = make_ref()
    waiter_ref = make_ref()

    state = %{
      connection_state()
      | pending: %{1 => %{from: self(), ref: command_ref}},
        event_waiters: %{
          {"Page.ready", nil} => [%{from: self(), ref: waiter_ref}]
        }
    }

    assert :ok = Connection.terminate(:transport_closed, state)

    assert_receive {:spectre_lens_cdp_error, ^command_ref,
                    %{
                      "code" => -32_000,
                      "message" => "CDP connection closed: :transport_closed"
                    }}

    assert_receive {:spectre_lens_cdp_event_error, ^waiter_ref, :transport_closed}
  end

  test "open handles direct websocket URLs and HTTP discovery responses" do
    assert {:error, _reason} = Connection.open("ws://127.0.0.1:1")
    assert {:error, _reason} = Connection.open("wss://127.0.0.1:1")

    version_port =
      start_http_server(
        200,
        Jason.encode!(%{"webSocketDebuggerUrl" => "ws://127.0.0.1:1"})
      )

    assert {:error, _reason} = Connection.open("http://127.0.0.1:#{version_port}/")

    invalid_port = start_http_server(503, Jason.encode!(%{"status" => "starting"}))

    assert {:error,
            %ConnectionError{
              reason: {:unexpected_version_response, 503, %{"status" => "starting"}}
            }} = Connection.open("http://127.0.0.1:#{invalid_port}")
  end

  test "close is safe for live and already terminated transports" do
    {:ok, conn} = TestCDP.start()
    monitor = Process.monitor(conn)
    assert :ok = Connection.close(conn)
    assert_receive {:DOWN, ^monitor, :process, ^conn, :normal}
    assert :ok = Connection.close(conn)
  end

  defp connection_state do
    %{
      id: 1,
      pending: %{},
      pending_refs: %{},
      event_waiters: %{},
      waiter_refs: %{},
      subscribers: %{},
      monitors: %{}
    }
  end

  defp sleeping_process do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(1)
      wait_until(fun, attempts - 1)
    end
  end

  defp start_http_server(status, body) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listener)

    {:ok, server} =
      Task.start(fn ->
        serve_http_once(listener, status, body)
        :gen_tcp.close(listener)
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(server), do: Process.exit(server, :kill)
    end)

    port
  end

  defp serve_http_once(listener, status, body) do
    with {:ok, socket} <- :gen_tcp.accept(listener),
         {:ok, _request} <- :gen_tcp.recv(socket, 0, 5_000) do
      reason = if status == 200, do: "OK", else: "Service Unavailable"

      response = [
        "HTTP/1.1 #{status} #{reason}\r\n",
        "content-type: application/json\r\n",
        "content-length: #{byte_size(body)}\r\n",
        "connection: close\r\n\r\n",
        body
      ]

      :ok = :gen_tcp.send(socket, response)
      :gen_tcp.close(socket)
    end
  end
end
