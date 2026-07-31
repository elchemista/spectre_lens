defmodule SpectreLens.RequestGuardContractTest do
  use ExUnit.Case, async: true

  alias SpectreLens.CDP.RequestGuard
  alias SpectreLens.CDPError
  alias SpectreLens.Tab
  alias SpectreLens.TestCDP

  test "paused subrequests are continued or blocked from the persisted network policy" do
    {:ok, conn} = TestCDP.start()

    resolver = fn
      _hostname, :inet -> {:ok, [{8, 8, 8, 8}]}
      _hostname, :inet6 -> {:ok, []}
    end

    tab = %Tab{
      conn: conn,
      session_id: "session-1",
      url_policy: [
        network_policy: :public,
        allowed_ports: [80, 443],
        resolver: resolver
      ]
    }

    assert {:ok, guard} = RequestGuard.start(tab)

    on_exit(fn ->
      RequestGuard.stop(guard)
      if Process.alive?(conn), do: GenServer.stop(conn)
    end)

    TestCDP.emit(conn, "Fetch.requestPaused", "session-1", %{
      "requestId" => "public",
      "request" => %{"url" => "https://public.example/script.js"}
    })

    TestCDP.emit(conn, "Fetch.requestPaused", "session-1", %{
      "requestId" => "loopback",
      "request" => %{"url" => "http://127.0.0.1/private"}
    })

    TestCDP.emit(conn, "Fetch.requestPaused", "session-1", %{
      "requestId" => "metadata",
      "request" => %{"url" => "http://metadata/"}
    })

    TestCDP.emit(conn, "Fetch.requestPaused", "session-1", %{
      "requestId" => "browser-local",
      "request" => %{"url" => "data:text/plain,safe"}
    })

    TestCDP.emit(conn, "Fetch.requestPaused", "session-1", %{"requestId" => "malformed"})

    TestCDP.emit(conn, "Fetch.requestPaused", "other-session", %{
      "requestId" => "wrong-session",
      "request" => %{"url" => "https://public.example/"}
    })

    assert wait_until(fn ->
             decisions =
               conn
               |> TestCDP.commands()
               |> Enum.filter(&String.starts_with?(&1.method, "Fetch."))

             Enum.count(decisions, &(&1.method == "Fetch.continueRequest")) == 2 and
               Enum.count(decisions, &(&1.method == "Fetch.failRequest")) == 2
           end)

    commands = TestCDP.commands(conn)

    assert Enum.any?(commands, fn command ->
             command.method == "Fetch.continueRequest" and
               command.params == %{"requestId" => "public"}
           end)

    assert Enum.any?(commands, fn command ->
             command.method == "Fetch.continueRequest" and
               command.params == %{"requestId" => "browser-local"}
           end)

    for request_id <- ["loopback", "metadata"] do
      assert Enum.any?(commands, fn command ->
               command.method == "Fetch.failRequest" and
                 command.params == %{
                   "requestId" => request_id,
                   "errorReason" => "BlockedByClient"
                 }
             end)
    end

    refute Enum.any?(commands, &(&1.params["requestId"] == "wrong-session"))
    send(guard, :unrelated)
    assert Process.alive?(guard)
  end

  test "normal shutdown disables interception while target closure avoids dead-target traffic" do
    {:ok, conn} = TestCDP.start()
    tab = %Tab{conn: conn, session_id: "session-1"}

    assert {:ok, guard} = RequestGuard.start(tab, network_policy: :public)
    assert :ok = RequestGuard.stop(guard)

    assert wait_until(fn ->
             Enum.any?(TestCDP.commands(conn), &(&1.method == "Fetch.disable"))
           end)

    assert {:ok, target_guard} = RequestGuard.start(tab, network_policy: :public)
    before_disable = Enum.count(TestCDP.commands(conn), &(&1.method == "Fetch.disable"))
    monitor = Process.monitor(target_guard)
    assert :ok = RequestGuard.target_closed(target_guard)
    assert_receive {:DOWN, ^monitor, :process, ^target_guard, :normal}

    after_disable = Enum.count(TestCDP.commands(conn), &(&1.method == "Fetch.disable"))
    assert after_disable == before_disable

    assert :ok = RequestGuard.stop(nil)
    assert :ok = RequestGuard.target_closed(nil)
    assert :ok = RequestGuard.stop(target_guard)
    assert :ok = RequestGuard.target_closed(target_guard)
    GenServer.stop(conn)
  end

  test "guard initialization reports Fetch failures and cleans its subscription" do
    {:ok, conn} = TestCDP.start()
    assert :ok = TestCDP.queue_reply(conn, "Fetch.enable", {:error, -32_601, "unsupported"})
    tab = %Tab{conn: conn, session_id: "session-1"}

    assert {:error,
            {:request_guard_unavailable, %CDPError{code: -32_601, method: "Fetch.enable"}}} =
             RequestGuard.start(tab, network_policy: :public)

    assert {:error, {:invalid_network_policy, :private}} =
             RequestGuard.start(tab, network_policy: :private)

    assert {:ok, nil} = RequestGuard.start(tab, network_policy: :any)
    GenServer.stop(conn)
  end

  test "a lost CDP connection takes the guard down with the transport reason" do
    {:ok, conn} = TestCDP.start()
    tab = %Tab{conn: conn, session_id: "session-1"}
    assert {:ok, guard} = RequestGuard.start(tab, network_policy: :public)

    monitor = Process.monitor(guard)
    GenServer.stop(conn, :connection_lost)

    assert_receive {:DOWN, ^monitor, :process, ^guard, {:connection_down, :connection_lost}}, 500
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
end
