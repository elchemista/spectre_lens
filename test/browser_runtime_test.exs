defmodule SpectreLens.BrowserRuntimeTest do
  use ExUnit.Case, async: true

  alias SpectreLens.Browser.Instance
  alias SpectreLens.Runtime
  alias SpectreLens.Tab

  defmodule FakeProtocol do
    @behaviour SpectreLens.Protocol

    @impl true
    def new_tab(instance, opts) do
      id = opts[:tab_id] || "tab-#{System.unique_integer([:positive, :monotonic])}"
      send(instance.owner, {:fake_tab_started, instance.id, id})

      {:ok,
       %Tab{
         id: id,
         handle: %{owner: instance.owner},
         protocol: instance.protocol,
         instance_id: instance.id,
         url_policy: SpectreLens.URLPolicy.take_options(opts)
       }}
    end

    @impl true
    def close_tab(%Tab{} = tab) do
      send(tab.handle.owner, {:fake_tab_stopped, tab.instance_id, tab.id})
      if is_pid(tab.runtime), do: Runtime.release_tab(tab.runtime, tab)
      :ok
    end

    @impl true
    def command(_tab, method, params, _opts), do: {:ok, %{method: method, params: params}}

    @impl true
    def navigate(%Tab{} = tab, url, _opts) do
      send(tab.handle.owner, {:fake_navigated, tab.instance_id, tab.id, url})
      :ok
    end

    @impl true
    def evaluate(_tab, _expression, _opts), do: {:ok, nil}

    @impl true
    def url(_tab), do: {:ok, "about:blank"}

    @impl true
    def title(_tab), do: {:ok, nil}

    @impl true
    def html(_tab, _opts), do: {:ok, "<html></html>"}

    @impl true
    def markdown(_tab, _opts), do: {:ok, ""}

    @impl true
    def semantic_tree(_tab, _opts), do: {:ok, %{"nodes" => []}}

    @impl true
    def interactive_elements(_tab, _opts), do: {:ok, []}

    @impl true
    def structured_data(_tab, _opts), do: {:ok, %{}}

    @impl true
    def page_map(_tab, _opts), do: {:error, :not_implemented}

    @impl true
    def focus(_tab, _ref, _opts), do: {:error, :not_implemented}

    @impl true
    def links(_tab, _opts), do: {:ok, []}

    @impl true
    def forms(_tab, _opts), do: {:ok, []}

    @impl true
    def screenshot(_tab, _opts), do: {:ok, ""}

    @impl true
    def pdf(_tab, _opts), do: {:ok, ""}

    @impl true
    def click(_tab, _ref, _opts), do: :ok

    @impl true
    def fill(_tab, _ref, _value, _opts), do: :ok

    @impl true
    def submit(_tab, _ref, _fields, _opts), do: :ok

    @impl true
    def wait_for_selector(_tab, _selector, _opts), do: :ok

    @impl true
    def wait_for_navigation(_tab, fun, _opts) do
      fun.()
      :ok
    end

    @impl true
    def scroll(_tab, _opts), do: :ok

    @impl true
    def subscribe(instance, subscriber) do
      send(instance.owner, {:fake_subscribed, instance.id, subscriber})
      :ok
    end

    @impl true
    def handle_info(
          {:fake_tab_closed, instance_id, tab_id},
          %Instance{id: instance_id}
        ),
        do: {:tab_closed, tab_id}

    def handle_info(_message, _instance), do: :ignore
  end

  defmodule FakeBackend do
    @behaviour SpectreLens.Browser

    @impl true
    def default_protocol, do: FakeProtocol

    @impl true
    def start_instance(index, opts) do
      owner = Keyword.fetch!(opts, :test_pid)
      send(owner, {:fake_instance_started, index})

      {:ok,
       %Instance{
         id: index,
         backend: __MODULE__,
         protocol: Keyword.fetch!(opts, :protocol),
         endpoint: opts[:endpoint],
         owner: owner,
         metadata: %{engine: :fake, token: "private", worker: self()}
       }}
    end

    @impl true
    def stop_instance(%Instance{id: id, owner: owner}) do
      send(owner, {:fake_instance_stopped, id})
      :ok
    end

    @impl true
    def max_tabs(_instance, opts), do: Keyword.get(opts, :max_tabs_per_instance, 2)

    @impl true
    def handle_info(
          {:fake_backend_down, instance_id, reason},
          %Instance{id: instance_id}
        ),
        do: {:instance_down, reason}

    def handle_info(_message, _instance), do: :ignore
  end

  defmodule InvalidCapacityBackend do
    @behaviour SpectreLens.Browser

    @impl true
    def default_protocol, do: FakeProtocol

    @impl true
    def start_instance(index, opts) do
      owner = Keyword.fetch!(opts, :test_pid)
      send(owner, {:invalid_capacity_started, index})

      {:ok,
       %Instance{
         id: index,
         backend: __MODULE__,
         protocol: Keyword.fetch!(opts, :protocol),
         owner: owner
       }}
    end

    @impl true
    def stop_instance(%Instance{id: id, owner: owner}) do
      send(owner, {:invalid_capacity_stopped, id})
      :ok
    end

    @impl true
    def max_tabs(_instance, _opts), do: 0
  end

  defmodule IncompleteProtocol do
    def new_tab(_instance, _opts), do: {:error, :unused}
  end

  defmodule IncompleteBackend do
    def start_instance(_index, _opts), do: {:error, :unused}
  end

  defmodule PartialProtocol do
    use SpectreLens.Protocol.Adapter

    @impl SpectreLens.Protocol
    def markdown(_tab, _opts), do: {:ok, "partial"}
  end

  defmodule AdapterBackend do
    use SpectreLens.Browser.Adapter,
      protocol: PartialProtocol,
      max_tabs: 3

    @impl SpectreLens.Browser
    def start_instance(_index, _opts), do: {:error, :unused}

    @impl SpectreLens.Browser
    def stop_instance(_instance), do: :ok
  end

  defmodule InvalidSubscriptionProtocol do
    use SpectreLens.Protocol.Adapter

    @impl SpectreLens.Protocol
    def subscribe(_instance, _subscriber), do: :invalid
  end

  defmodule InvalidTabProtocol do
    use SpectreLens.Protocol.Adapter

    @impl SpectreLens.Protocol
    def new_tab(instance, _opts) do
      {:ok,
       %Tab{
         handle: %{owner: instance.owner},
         protocol: __MODULE__,
         instance_id: instance.id
       }}
    end

    @impl SpectreLens.Protocol
    def close_tab(tab) do
      send(tab.handle.owner, :invalid_tab_cleaned)
      :ok
    end
  end

  test "runs without Lightpanda and reports the selected backend and protocol" do
    assert {:ok, runtime} =
             SpectreLens.open(
               backend: FakeBackend,
               protocol: FakeProtocol,
               instances: 2,
               endpoint: "wss://user:secret@example.test/browser/private?token=private",
               test_pid: self()
             )

    assert_receive {:fake_instance_started, 1}
    assert_receive {:fake_subscribed, 1, runtime_pid}
    assert runtime.pid == runtime_pid
    assert_receive {:fake_instance_started, 2}
    assert_receive {:fake_subscribed, 2, ^runtime_pid}

    assert %{
             backend: FakeBackend,
             protocol: FakeProtocol,
             instance_count: 2,
             instances: instances
           } = Runtime.info(runtime)

    assert Enum.map(instances, & &1.metadata) == [
             %{engine: :fake, token: "[REDACTED]", worker: "[RUNTIME VALUE]"},
             %{engine: :fake, token: "[REDACTED]", worker: "[RUNTIME VALUE]"}
           ]

    assert Enum.all?(instances, &(&1.endpoint == "wss://example.test"))
    assert Enum.all?(instances, &(&1.max_tabs == 2))
    assert SpectreLens.runtime_info(runtime) == Runtime.info(runtime)

    assert %{
             backend: FakeBackend,
             protocol: FakeProtocol,
             protocol_valid?: true,
             available?: true
           } =
             SpectreLens.doctor(
               backend: FakeBackend,
               protocol: FakeProtocol
             )

    assert :ok = SpectreLens.close(runtime)
    assert_receive {:fake_instance_stopped, 1}
    assert_receive {:fake_instance_stopped, 2}
  end

  test "balances capacity, releases tabs, and scopes close events to one instance" do
    assert {:ok, runtime} =
             SpectreLens.open(
               backend: FakeBackend,
               protocol: FakeProtocol,
               instances: 2,
               max_tabs_per_instance: 1,
               test_pid: self(),
               network_policy: :any
             )

    assert {:ok, first} =
             SpectreLens.new_tab(runtime, tab_id: "same", url: "https://one.example")

    assert {:ok, second} =
             SpectreLens.new_tab(runtime, tab_id: "same", url: "https://two.example")

    assert {first.instance_id, second.instance_id} == {1, 2}
    assert {:error, :tab_capacity_exceeded} = SpectreLens.new_tab(runtime)

    send(runtime.pid, {:fake_tab_closed, 1, "same"})

    assert {:ok, replacement} =
             SpectreLens.new_tab(runtime, tab_id: "replacement", url: "https://three.example")

    assert replacement.instance_id == 1
    assert :ok = SpectreLens.close_tab(second)

    assert {:ok, next} = SpectreLens.new_tab(runtime, tab_id: "next")
    assert next.instance_id == 2

    assert :ok = SpectreLens.close(runtime)
  end

  @tag capture_log: true
  test "stops the runtime and every owned instance when a backend reports failure" do
    previous = Process.flag(:trap_exit, true)

    on_exit(fn ->
      Process.flag(:trap_exit, previous)
    end)

    assert {:ok, runtime} =
             SpectreLens.open(
               backend: FakeBackend,
               protocol: FakeProtocol,
               instances: 2,
               test_pid: self()
             )

    monitor = Process.monitor(runtime.pid)
    send(runtime.pid, {:fake_backend_down, 2, :crashed})

    assert_receive {:DOWN, ^monitor, :process, _pid, {:browser_instance_down, 2, :crashed}}
    assert_receive {:fake_instance_stopped, 1}
    assert_receive {:fake_instance_stopped, 2}
  end

  test "validates adapters before allocation and cleans up invalid capacity" do
    assert {:error, {:invalid_network_policy, :internal}} =
             SpectreLens.open(
               backend: FakeBackend,
               protocol: FakeProtocol,
               network_policy: :internal,
               test_pid: self()
             )

    refute_receive {:fake_instance_started, _index}

    assert {:error, {:invalid_browser_backend, IncompleteBackend, _callbacks}} =
             SpectreLens.open(backend: IncompleteBackend)

    assert {:error, {:invalid_browser_protocol, IncompleteProtocol, _callbacks}} =
             SpectreLens.open(
               backend: FakeBackend,
               protocol: IncompleteProtocol,
               test_pid: self()
             )

    refute_receive {:fake_instance_started, _index}

    assert {:error, {:invalid_browser_capacity, InvalidCapacityBackend, 0}} =
             SpectreLens.open(
               backend: InvalidCapacityBackend,
               protocol: FakeProtocol,
               test_pid: self()
             )

    assert_receive {:invalid_capacity_started, 1}
    assert_receive {:invalid_capacity_stopped, 1}
  end

  test "adapter helpers provide explicit unsupported defaults and overridable capacity" do
    assert :ok = SpectreLens.Protocol.validate(PartialProtocol)
    assert :ok = SpectreLens.Browser.validate(AdapterBackend)
    assert AdapterBackend.default_protocol() == PartialProtocol

    instance = %Instance{
      id: 1,
      backend: AdapterBackend,
      protocol: PartialProtocol
    }

    assert AdapterBackend.max_tabs(instance, []) == 3
    assert AdapterBackend.max_tabs(instance, max_tabs_per_instance: 9) == 9
    assert {:ok, "partial"} = PartialProtocol.markdown(%Tab{}, [])

    assert {:error, %SpectreLens.UnsupportedError{feature: :click}} =
             PartialProtocol.click(%Tab{}, "#button", [])
  end

  test "rejects invalid subscriptions and live tabs without leaking backend resources" do
    assert {:error, {:invalid_browser_subscription_result, InvalidSubscriptionProtocol, :invalid}} =
             SpectreLens.open(
               backend: FakeBackend,
               protocol: InvalidSubscriptionProtocol,
               test_pid: self()
             )

    assert_receive {:fake_instance_started, 1}
    assert_receive {:fake_instance_stopped, 1}

    assert {:ok, runtime} =
             SpectreLens.open(
               backend: FakeBackend,
               protocol: InvalidTabProtocol,
               test_pid: self()
             )

    assert {:error, {:invalid_browser_tab, InvalidTabProtocol, 1, %Tab{}}} =
             SpectreLens.new_tab(runtime)

    assert_receive :invalid_tab_cleaned
    assert :ok = SpectreLens.close(runtime)
  end
end
