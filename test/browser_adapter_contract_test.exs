defmodule SpectreLens.BrowserAdapterContractTest do
  use ExUnit.Case, async: true

  alias SpectreLens.Browser.Instance
  alias SpectreLens.Browsers.Lightpanda
  alias SpectreLens.Browsers.RemoteCDP
  alias SpectreLens.TestCDP

  defmodule BoundaryProtocol do
    use SpectreLens.Protocol.Adapter

    def subscribe(instance, _subscriber) do
      case instance.metadata[:subscribe] do
        :error -> {:error, :subscription_failed}
        :raise -> raise "subscription raised"
        :throw -> throw(:subscription_thrown)
        _other -> :ok
      end
    end

    def handle_info(:raise, _instance), do: raise("event raised")
    def handle_info(:throw, _instance), do: throw(:event_thrown)
    def handle_info(_message, _instance), do: :ignore
  end

  defmodule BoundaryBackend do
    @behaviour SpectreLens.Browser

    alias SpectreLens.Browser.Instance

    def default_protocol, do: BoundaryProtocol

    def start_instance(index, opts) do
      case opts[:mode] do
        :ok_invalid ->
          {:ok, :invalid}

        :raw_invalid ->
          :invalid

        :raise ->
          raise "start raised"

        :throw ->
          throw(:start_thrown)

        :wrong_identity ->
          {:ok, %Instance{id: :wrong, backend: __MODULE__, protocol: BoundaryProtocol}}

        _other ->
          {:ok,
           %Instance{
             id: index,
             backend: __MODULE__,
             protocol: BoundaryProtocol,
             metadata: %{stop: opts[:stop], subscribe: opts[:subscribe]}
           }}
      end
    end

    def stop_instance(instance) do
      case instance.metadata[:stop] do
        :error -> {:error, :stop_failed}
        :other -> :unexpected
        :raise -> raise "stop raised"
        :throw -> throw(:stop_thrown)
        _other -> :ok
      end
    end

    def max_tabs(_instance, opts) do
      case opts[:capacity] do
        :raise -> raise "capacity raised"
        :throw -> throw(:capacity_thrown)
        value when not is_nil(value) -> value
        nil -> 1
      end
    end

    def handle_info(:raise, _instance), do: raise("backend event raised")
    def handle_info(:throw, _instance), do: throw(:backend_event_thrown)
    def handle_info(_message, _instance), do: :ignore

    def doctor(opts), do: %{backend: __MODULE__, available?: opts[:available?]}
  end

  test "remote CDP owns only its connection and supports endpoint pools" do
    endpoint = start_websocket_server()

    assert RemoteCDP.default_protocol() == SpectreLens.Protocol.CDP

    assert {:ok, instance} =
             RemoteCDP.start_instance(2,
               endpoints: ["ws://127.0.0.1:1", endpoint],
               max_tabs_per_instance: 3
             )

    assert %Instance{
             id: 2,
             backend: RemoteCDP,
             protocol: SpectreLens.Protocol.CDP,
             endpoint: ^endpoint,
             owner: :external,
             metadata: %{ownership: :external}
           } = instance

    assert is_pid(instance.connection)
    assert RemoteCDP.max_tabs(instance, []) == 8
    assert RemoteCDP.max_tabs(instance, max_tabs_per_instance: 3) == 3

    assert {:instance_down, {:connection_down, :closed}} =
             RemoteCDP.handle_info({:EXIT, instance.connection, :closed}, instance)

    assert RemoteCDP.handle_info(:unrelated, instance) == :ignore

    monitor = Process.monitor(instance.connection)
    assert :ok = RemoteCDP.stop_instance(instance)
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}, 1_000
  end

  test "remote diagnostics distinguish missing, unreachable and reachable endpoints safely" do
    assert {:error, {:missing_browser_endpoint, 1}} = RemoteCDP.start_instance(1, [])

    assert {:error, {:missing_browser_endpoint, 2}} =
             RemoteCDP.start_instance(2, endpoints: ["ws://127.0.0.1:1"])

    assert %{
             backend: RemoteCDP,
             available?: false,
             reachable?: false,
             error: :missing_browser_endpoint
           } = RemoteCDP.doctor([])

    assert %{
             backend: RemoteCDP,
             available?: false,
             reachable?: false,
             endpoint: "ws://127.0.0.1:1",
             error: WebSockex.ConnError
           } =
             RemoteCDP.doctor(endpoint: "ws://agent:secret@127.0.0.1:1/private?token=secret")

    endpoint = start_websocket_server()

    assert %{
             backend: RemoteCDP,
             available?: true,
             reachable?: true,
             endpoint: diagnostic_endpoint
           } = RemoteCDP.doctor(endpoint: endpoint)

    assert diagnostic_endpoint == endpoint
  end

  test "local Lightpanda backend exposes fixed capacity and process lifecycle events" do
    assert Lightpanda.default_protocol() == SpectreLens.Protocol.Lightpanda
    placeholder = %Instance{id: 1, backend: Lightpanda, protocol: SpectreLens.Protocol.Lightpanda}
    assert Lightpanda.max_tabs(placeholder, max_tabs_per_instance: 99) == 1

    process_pid = spawn(fn -> Process.sleep(:infinity) end)
    os_pid = 12_345

    instance = %Instance{
      id: 1,
      backend: Lightpanda,
      protocol: SpectreLens.Protocol.Lightpanda,
      owner: %{process: {process_pid, os_pid}}
    }

    assert {:instance_down, {:lightpanda_down, :crashed}} =
             Lightpanda.handle_info(
               {:DOWN, os_pid, :process, process_pid, :crashed},
               instance
             )

    assert :ignore = Lightpanda.handle_info({:stdout, os_pid, "ready"}, instance)
    assert :ignore = Lightpanda.handle_info({:stderr, os_pid, "warning"}, instance)
    assert :ignore = Lightpanda.handle_info(:unrelated, instance)

    Process.exit(process_pid, :kill)
  end

  test "local backend validates Lightpanda before allocating a CDP connection" do
    directory = temporary_directory()
    invalid = Path.join(directory, "lightpanda")

    :ok =
      File.write(
        invalid,
        """
        #!/bin/sh
        echo "development"
        exit 0
        """
      )

    :ok = File.chmod(invalid, 0o755)

    assert {:error, {:invalid_lightpanda_version, "development"}} =
             Lightpanda.start_instance(1, binary: invalid)

    diagnostics = Lightpanda.doctor(binary: invalid, os: :linux, arch: "amd64")
    assert diagnostics.backend == Lightpanda
    assert diagnostics.detected?
    refute diagnostics.compatible?
  end

  test "stopping a local backend closes CDP even if the native process is already gone" do
    {:ok, conn} = TestCDP.start()
    dead = spawn(fn -> :ok end)
    monitor = Process.monitor(dead)
    assert_receive {:DOWN, ^monitor, :process, ^dead, _reason}

    instance = %Instance{
      id: 1,
      backend: Lightpanda,
      protocol: SpectreLens.Protocol.Lightpanda,
      connection: conn,
      owner: %{process: {dead, -1}, monitor_owner: dead}
    }

    assert :ok = Lightpanda.stop_instance(instance)
    assert wait_until(fn -> not Process.alive?(conn) end)
  end

  test "browser boundary normalizes malformed, raised and thrown adapter results" do
    alias SpectreLens.Browser

    assert {:error, {:invalid_browser_backend, nil}} = Browser.validate(nil)

    assert {:error, {:browser_backend_unavailable, SpectreLens.MissingBackend}} =
             Browser.validate(SpectreLens.MissingBackend)

    assert {:error, {:invalid_browser_instance, :invalid}} =
             Browser.start_instance(BoundaryBackend, 1, mode: :ok_invalid)

    assert {:error, {:invalid_browser_start_result, BoundaryBackend, :invalid}} =
             Browser.start_instance(BoundaryBackend, 1, mode: :raw_invalid)

    assert {:error, {:browser_backend_start_failed, BoundaryBackend, %RuntimeError{}}} =
             Browser.start_instance(BoundaryBackend, 1, mode: :raise)

    assert {:error, {:browser_backend_start_failed, BoundaryBackend, {:throw, :start_thrown}}} =
             Browser.start_instance(BoundaryBackend, 1, mode: :throw)

    assert {:error, {:invalid_browser_instance, BoundaryBackend, 1, %Instance{id: :wrong}}} =
             Browser.start_instance(BoundaryBackend, 1, mode: :wrong_identity)

    assert {:error, {:browser_backend_capacity_failed, BoundaryBackend, %RuntimeError{}}} =
             Browser.start_instance(BoundaryBackend, 1, capacity: :raise)

    assert {:error,
            {:browser_backend_capacity_failed, BoundaryBackend, {:throw, :capacity_thrown}}} =
             Browser.start_instance(BoundaryBackend, 1, capacity: :throw)

    for stop <- [:error, :other, :raise, :throw] do
      instance = %Instance{
        id: 1,
        backend: BoundaryBackend,
        protocol: BoundaryProtocol,
        metadata: %{stop: stop}
      }

      assert :ok = Browser.stop_instance(instance)
    end

    subscription_instance = fn subscribe ->
      %Instance{
        id: 1,
        backend: BoundaryBackend,
        protocol: BoundaryProtocol,
        metadata: %{subscribe: subscribe}
      }
    end

    assert {:error, :subscription_failed} =
             Browser.subscribe(subscription_instance.(:error), self())

    assert {:error, {:browser_subscription_failed, BoundaryProtocol, %RuntimeError{}}} =
             Browser.subscribe(subscription_instance.(:raise), self())

    assert {:error,
            {:browser_subscription_failed, BoundaryProtocol, {:throw, :subscription_thrown}}} =
             Browser.subscribe(subscription_instance.(:throw), self())

    instance = %Instance{
      id: 1,
      backend: BoundaryBackend,
      protocol: BoundaryProtocol
    }

    assert {:instance_down, {:browser_event_failed, %RuntimeError{}}} =
             Browser.handle_info(:raise, instance)

    assert {:instance_down, {:browser_event_failed, {:throw, :backend_event_thrown}}} =
             Browser.handle_info(:throw, instance)

    assert %{backend: BoundaryBackend, available?: false} =
             Browser.doctor(BoundaryBackend, available?: false)
  end

  defp start_websocket_server do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listener)

    {:ok, server} =
      Task.start(fn ->
        with {:ok, socket} <- :gen_tcp.accept(listener),
             {:ok, request} <- recv_headers(socket, ""),
             {:ok, key} <- websocket_key(request) do
          accept =
            :sha
            |> :crypto.hash(key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
            |> Base.encode64()

          :ok =
            :gen_tcp.send(socket, [
              "HTTP/1.1 101 Switching Protocols\r\n",
              "upgrade: websocket\r\n",
              "connection: Upgrade\r\n",
              "sec-websocket-accept: ",
              accept,
              "\r\n\r\n"
            ])

          hold_socket(socket)
        end

        :gen_tcp.close(listener)
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(server), do: Process.exit(server, :kill)
    end)

    "ws://127.0.0.1:#{port}"
  end

  defp recv_headers(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 2_000) do
        {:ok, chunk} -> recv_headers(socket, acc <> chunk)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp websocket_key(request) do
    case Regex.run(~r/sec-websocket-key:\s*([^\r\n]+)/i, request) do
      [_, key] -> {:ok, String.trim(key)}
      _other -> {:error, :missing_websocket_key}
    end
  end

  defp hold_socket(socket) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, _data} -> :gen_tcp.close(socket)
      {:error, _reason} -> :ok
    end
  end

  defp temporary_directory do
    path =
      Path.join(
        System.tmp_dir!(),
        "spectre-lens-adapter-#{System.unique_integer([:positive, :monotonic])}"
      )

    :ok = File.mkdir_p(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
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
