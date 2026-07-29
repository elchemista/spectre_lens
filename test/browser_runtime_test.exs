defmodule SpectreLens.BrowserRuntimeTest do
  use ExUnit.Case, async: true

  alias SpectreLens.Browser.Instance
  alias SpectreLens.Runtime
  alias SpectreLens.Session
  alias SpectreLens.Tab
  alias SpectreLens.TabRef

  defmodule FakeProtocol do
    @behaviour SpectreLens.Protocol

    @impl true
    def new_tab(instance, opts) do
      if opts[:wait_for_continue] do
        send(instance.owner, {:fake_tab_worker_waiting, self()})

        receive do
          :continue -> :ok
        end
      end

      if opts[:worker_exit], do: exit(opts[:worker_exit])

      id = opts[:tab_id] || "tab-#{System.unique_integer([:positive, :monotonic])}"
      send(instance.owner, {:fake_tab_started, instance.id, id})

      {:ok,
       %Tab{
         id: id,
         handle: %{owner: instance.owner},
         protocol: instance.protocol,
         instance_id: instance.id,
         browser_context_id: if(opts[:session_key], do: "context-#{id}"),
         session_key: opts[:session_key],
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

      if url == "https://navigation-error.test" do
        {:error, :navigation_failed}
      else
        :ok
      end
    end

    @impl true
    def evaluate(_tab, expression, _opts), do: {:ok, %{expression: expression}}

    @impl true
    def url(_tab), do: {:ok, "https://example.test/root"}

    @impl true
    def title(_tab), do: {:ok, "Fake page"}

    @impl true
    def html(_tab, _opts), do: {:ok, "<html><body>Fake page</body></html>"}

    @impl true
    def markdown(_tab, _opts), do: {:ok, "# Fake page"}

    @impl true
    def semantic_tree(_tab, _opts),
      do: {:ok, %{"nodes" => [%{"role" => "main", "name" => "Fake page"}]}}

    @impl true
    def interactive_elements(_tab, _opts),
      do: {:ok, [%{"role" => "button", "name" => "Save", "selector" => "#save"}]}

    @impl true
    def structured_data(_tab, _opts), do: {:ok, %{"title" => "Fake page"}}

    @impl true
    def page_map(_tab, _opts) do
      {:ok,
       %SpectreLens.PageMap{
         description: "A fake main region.",
         regions: [
           %SpectreLens.Region{
             id: "main",
             kind: :main,
             selector: "#main",
             purpose: "Fake content"
           }
         ]
       }}
    end

    @impl true
    def focus(tab, _ref, opts), do: page_map(tab, opts)

    @impl true
    def links(_tab, _opts),
      do: {:ok, [%{"href" => "https://example.test/docs", "text" => "Docs"}]}

    @impl true
    def forms(_tab, _opts), do: {:ok, [%{"selector" => "#search"}]}

    @impl true
    def screenshot(_tab, _opts), do: {:ok, "png"}

    @impl true
    def pdf(_tab, _opts), do: {:ok, "pdf"}

    @impl true
    def click(tab, ref, opts) do
      send(tab.handle.owner, {:fake_clicked, tab.id, ref, opts})
      :ok
    end

    @impl true
    def fill(tab, ref, value, opts) do
      send(tab.handle.owner, {:fake_filled, tab.id, ref, value, opts})
      :ok
    end

    @impl true
    def submit(tab, ref, fields, opts) do
      send(tab.handle.owner, {:fake_submitted, tab.id, ref, fields, opts})
      :ok
    end

    @impl true
    def wait_for_selector(_tab, _selector, _opts), do: :ok

    @impl true
    def wait_for_navigation(_tab, fun, _opts) do
      fun.()
      :ok
    end

    @impl true
    def scroll(tab, opts) do
      send(tab.handle.owner, {:fake_scrolled, tab.id, opts})
      :ok
    end

    @impl true
    def capture_session(%Tab{} = tab, opts) do
      send(tab.handle.owner, {:fake_session_captured, tab.id, opts})

      if opts[:capture_error] do
        {:error, :capture_failed}
      else
        {:ok,
         Session.new(
           cookies: [%{"name" => "sid", "value" => "fresh"}],
           local_storage: %{"https://example.test" => %{"fresh" => "1"}},
           metadata: %{source: "fake"}
         )}
      end
    end

    @impl true
    def restore_session(%Tab{} = tab, %Session{} = session, opts) do
      send(tab.handle.owner, {:fake_session_restored, tab.id, session, opts})
      if opts[:restore_error], do: {:error, :restore_failed}, else: :ok
    end

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

    def handle_info(
          {:fake_instance_updated, instance_id, metadata},
          %Instance{id: instance_id} = instance
        ),
        do: {:ok, %{instance | metadata: metadata}}

    def handle_info(
          {:fake_invalid_event, instance_id},
          %Instance{id: instance_id}
        ),
        do: :invalid_backend_event

    def handle_info(_message, _instance), do: :ignore
  end

  defmodule FakeBackend do
    @behaviour SpectreLens.Browser

    @impl true
    def default_protocol, do: FakeProtocol

    @impl true
    def start_instance(index, opts) do
      owner = Keyword.get(opts, :test_pid, self())
      send(owner, {:fake_instance_started, index})

      if opts[:report_opts], do: send(owner, {:fake_instance_opts, index, opts})

      if opts[:fail_instance] == index do
        {:error, {:fake_instance_failed, index}}
      else
        {:ok,
         %Instance{
           id: index,
           backend: __MODULE__,
           protocol: Keyword.fetch!(opts, :protocol),
           endpoint: opts[:endpoint],
           owner: owner,
           metadata: opts[:test_metadata] || %{engine: :fake, token: "private", worker: self()}
         }}
      end
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

  defmodule ConfigurablePolicy do
    @moduledoc false

    def authorize(_operation, _args, opts), do: Keyword.fetch!(opts, :reply)
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

  test "session snapshots remain portable across runtime storage, restore and capture" do
    assert {:ok, runtime} =
             SpectreLens.open(
               backend: FakeBackend,
               protocol: FakeProtocol,
               test_pid: self(),
               network_policy: :any,
               max_tabs_per_instance: 3
             )

    original =
      Session.new(
        cookies: [%{name: "sid", value: "old"}],
        local_storage: %{"https://example.test" => %{"old" => "1"}},
        metadata: %{owner: "agent"}
      )

    assert {:ok, %Session{} = stored} = SpectreLens.put_session(runtime, :login, original)
    assert {:ok, ^stored} = SpectreLens.get_session(runtime.pid, :login)

    assert {:ok, exported} = SpectreLens.export_session(runtime, :login)
    assert exported["version"] == 1
    assert [%{"name" => "sid", "value" => "old"}] = exported["cookies"]

    assert :ok = SpectreLens.delete_session(runtime.pid, :login)
    assert {:error, {:unknown_session, :login}} = SpectreLens.get_session(runtime, :login)

    assert {:ok, %Session{} = imported} =
             SpectreLens.import_session(runtime, :login, exported)

    assert imported.local_storage == %{"https://example.test" => %{"old" => "1"}}

    assert {:error, {:unsupported_session_version, 99}} =
             SpectreLens.put_session(runtime, :bad, %{"version" => 99})

    assert {:error, :invalid_session} = SpectreLens.put_session(runtime, :bad, :invalid)

    assert {:ok, tab} =
             SpectreLens.new_tab(
               runtime,
               tab_id: "session-tab",
               session: :login,
               url: "https://example.test/account"
             )

    assert tab.session_key == :login

    assert_receive {:fake_session_restored, "session-tab", ^imported, restore_opts}
    assert restore_opts[:session_key] == :login

    assert {:ok, merged} = SpectreLens.save_session(tab)
    assert_receive {:fake_session_captured, "session-tab", []}
    assert merged.metadata == %{"owner" => "agent", "source" => "fake"}

    assert merged.local_storage["https://example.test"] == %{
             "fresh" => "1",
             "old" => "1"
           }

    assert {:ok, replaced} = SpectreLens.save_session(tab, :replacement, replace?: true)
    assert replaced.local_storage == %{"https://example.test" => %{"fresh" => "1"}}

    assert {:error, :capture_failed} =
             SpectreLens.save_session(tab, :failed, capture_error: true)

    assert {:error, :missing_session_key} =
             Runtime.save_session(%{tab | session_key: nil}, nil, [])

    assert {:error, :missing_runtime} =
             Runtime.save_session(%{tab | runtime: nil}, :detached, [])

    assert {:ok, ref} = TabRef.new(tab)
    assert {:ok, ^tab} = SpectreLens.resolve_tab(runtime, ref)
    assert {:ok, ^tab} = Runtime.resolve_tab(runtime.pid, ref)

    missing_ref = %{ref | id: "missing"}

    assert {:error, {:unknown_lens_tab_ref, "missing"}} =
             SpectreLens.resolve_tab(runtime, missing_ref)

    assert :ok = SpectreLens.close(runtime)
  end

  test "session allocation distinguishes missing snapshots from exhausted contexts" do
    assert {:ok, runtime} =
             SpectreLens.open(
               backend: FakeBackend,
               protocol: FakeProtocol,
               test_pid: self(),
               network_policy: :any,
               max_tabs_per_instance: 1
             )

    assert {:error, {:unknown_session, :required}} =
             SpectreLens.new_tab(runtime, session: :required, require_session?: true)

    assert {:ok, tab} = SpectreLens.new_tab(runtime, tab_id: "plain", session: nil)

    assert {:error, :session_context_capacity_exceeded} =
             SpectreLens.new_tab(runtime, session: :fresh)

    assert {:error, :tab_capacity_exceeded} =
             SpectreLens.new_tab(runtime, session: nil)

    assert :ok = SpectreLens.close_tab(tab)

    assert {:ok, blank} =
             SpectreLens.new_tab(runtime,
               tab_id: "blank-session",
               session: :fresh,
               url: "about:blank"
             )

    refute_receive {:fake_session_restored, "blank-session", _, _}
    assert :ok = SpectreLens.close_tab(blank)

    assert {:ok, no_url} =
             SpectreLens.new_tab(runtime, tab_id: "nil-session", session: :fresh)

    refute_receive {:fake_session_restored, "nil-session", _, _}
    assert :ok = SpectreLens.close_tab(no_url)
    assert :ok = SpectreLens.close(runtime)
  end

  test "failed navigation, failed restore and worker exits release reservations" do
    previous = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous) end)

    assert {:ok, runtime} =
             SpectreLens.open(
               backend: FakeBackend,
               protocol: FakeProtocol,
               test_pid: self(),
               network_policy: :any,
               max_tabs_per_instance: 1
             )

    assert {:error, :navigation_failed} =
             SpectreLens.new_tab(
               runtime,
               tab_id: "bad-navigation",
               url: "https://navigation-error.test"
             )

    assert_receive {:fake_tab_stopped, 1, "bad-navigation"}

    assert {:ok, _session} = SpectreLens.put_session(runtime, :login, Session.new())

    assert {:error, :restore_failed} =
             SpectreLens.new_tab(
               runtime,
               tab_id: "bad-restore",
               session: :login,
               url: "https://example.test",
               restore_error: true
             )

    assert_receive {:fake_tab_stopped, 1, "bad-restore"}

    assert {:error, {:tab_worker_down, :worker_boom}} =
             SpectreLens.new_tab(runtime, worker_exit: :worker_boom)

    assert {:ok, replacement} = SpectreLens.new_tab(runtime, tab_id: "replacement")
    assert :ok = SpectreLens.close_tab(replacement)
    assert :ok = SpectreLens.close(runtime)
  end

  test "a caller disappearing during tab creation never leaks a live tab" do
    assert {:ok, runtime} =
             SpectreLens.open(
               backend: FakeBackend,
               protocol: FakeProtocol,
               test_pid: self(),
               network_policy: :any,
               max_tabs_per_instance: 1
             )

    caller =
      spawn(fn ->
        SpectreLens.new_tab(runtime, tab_id: "orphan", wait_for_continue: true)
      end)

    assert_receive {:fake_tab_worker_waiting, worker}
    caller_monitor = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}
    send(worker, :continue)

    assert_receive {:fake_tab_stopped, 1, "orphan"}
    assert_runtime_idle(runtime)

    assert {:ok, replacement} = SpectreLens.new_tab(runtime, tab_id: "after-orphan")
    assert :ok = SpectreLens.close_tab(replacement)
    assert :ok = SpectreLens.close(runtime)
  end

  test "target-close races are bounded and reject the late tab deterministically" do
    assert {:ok, runtime} =
             SpectreLens.open(
               backend: FakeBackend,
               protocol: FakeProtocol,
               test_pid: self(),
               network_policy: :any,
               max_tabs_per_instance: 1
             )

    caller =
      Task.async(fn ->
        SpectreLens.new_tab(runtime,
          tab_id: "late-target",
          wait_for_continue: true
        )
      end)

    assert_receive {:fake_tab_worker_waiting, worker}

    Enum.each(1..130, fn index ->
      send(runtime.pid, {:fake_tab_closed, 1, "stale-#{index}"})
    end)

    send(runtime.pid, {:fake_tab_closed, 1, "late-target"})
    state = :sys.get_state(runtime.pid)
    assert MapSet.size(state.destroyed_tabs) <= 128
    assert MapSet.member?(state.destroyed_tabs, {1, "late-target"})

    send(worker, :continue)
    assert {:error, :target_closed} = Task.await(caller)
    assert_receive {:fake_tab_stopped, 1, "late-target"}
    assert_runtime_idle(runtime)
    assert :ok = SpectreLens.close(runtime)
  end

  @tag capture_log: true
  test "runtime accepts instance refresh events and rejects malformed backend events" do
    previous = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous) end)

    assert {:ok, runtime} =
             SpectreLens.open(
               backend: FakeBackend,
               protocol: FakeProtocol,
               test_pid: self(),
               network_policy: :any
             )

    send(runtime.pid, {:unknown_task_result, :ignored})
    send(runtime.pid, {make_ref(), :late_task_result})
    send(runtime.pid, {:DOWN, make_ref(), :process, self(), :normal})
    send(runtime.pid, {:fake_instance_updated, 1, %{health: :ready}})

    assert [%{metadata: %{health: :ready}}] = Runtime.info(runtime).instances

    monitor = Process.monitor(runtime.pid)
    send(runtime.pid, {:fake_invalid_event, 1})

    assert_receive {:DOWN, ^monitor, :process, _pid,
                    {:invalid_browser_backend_event, FakeBackend, :invalid_backend_event}}

    assert_receive {:fake_instance_stopped, 1}
  end

  test "runtime startup validates pool size, ports and partial allocation cleanup" do
    assert {:error, {:invalid_browser_instance_count, 0}} =
             SpectreLens.open(
               backend: FakeBackend,
               protocol: FakeProtocol,
               test_pid: self(),
               instances: 0
             )

    assert {:error, {:invalid_browser_instance_count, "two"}} =
             SpectreLens.open(
               backend: FakeBackend,
               protocol: FakeProtocol,
               test_pid: self(),
               instances: "two"
             )

    assert {:error, {:fake_instance_failed, 2}} =
             SpectreLens.open(
               backend: FakeBackend,
               protocol: FakeProtocol,
               test_pid: self(),
               instances: 3,
               fail_instance: 2
             )

    assert_receive {:fake_instance_started, 1}
    assert_receive {:fake_instance_started, 2}
    refute_receive {:fake_instance_started, 3}
    assert_receive {:fake_instance_stopped, 1}

    assert {:ok, runtime} =
             SpectreLens.open(
               backend: FakeBackend,
               protocol: FakeProtocol,
               test_pid: self(),
               instances: 2,
               ports: [9_301, 9_302],
               report_opts: true
             )

    assert_receive {:fake_instance_opts, 1, first_opts}
    assert_receive {:fake_instance_opts, 2, second_opts}
    assert first_opts[:port] == 9_301
    assert second_opts[:port] == 9_302
    assert :ok = SpectreLens.close(runtime)
  end

  test "runtime diagnostics redact nested secrets and process-local values" do
    metadata = %{
      {:unusual, :key} => "kept",
      api_key: "secret",
      nested: [%{password: "hidden"}, {:worker, self(), make_ref()}],
      safe: :visible
    }

    assert {:ok, runtime} =
             SpectreLens.open(
               backend: FakeBackend,
               protocol: FakeProtocol,
               test_pid: self(),
               endpoint: "not a valid endpoint",
               test_metadata: metadata
             )

    assert %{instances: [info]} = Runtime.info(runtime)
    assert info.endpoint == "[redacted-endpoint]"
    assert info.metadata.api_key == "[REDACTED]"
    assert info.metadata.safe == :visible

    assert info.metadata.nested == [
             %{password: "[REDACTED]"},
             {:worker, "[RUNTIME VALUE]", "[RUNTIME VALUE]"}
           ]

    assert info.metadata[{:unusual, :key}] == "kept"
    assert :ok = Runtime.close(runtime)
    assert :ok = Runtime.close(runtime)
  end

  test "Lens action provider executes portable browser operations through one runtime" do
    alias Spectre.Action
    alias Spectre.Context
    alias Spectre.Lens.ActionProvider
    alias SpectreLens.StackContractAgent

    assert {:ok, runtime} =
             SpectreLens.open(
               backend: FakeBackend,
               protocol: FakeProtocol,
               test_pid: self(),
               network_policy: :any,
               max_tabs_per_instance: 4
             )

    config = %{
      options: [planner_exposure: [:open, :act]],
      backend: nil,
      policy: nil
    }

    context = %Context{
      agent: StackContractAgent,
      opts: [
        lens_runtime: runtime,
        lens_opts: [network_policy: :any, include: [:markdown]]
      ]
    }

    specs = ActionProvider.actions(config: config)

    assert Enum.map(specs, &{&1.name, &1.visibility}) == [
             {:open, :both},
             {:look, :deterministic},
             {:discover, :deterministic},
             {:act, :both},
             {:export, :deterministic}
           ]

    open = Action.new(:open, via: :lens, args: %{"url" => "https://example.test"})
    assert {:ok, %TabRef{} = ref} = ActionProvider.execute(open, context, config: config)
    assert ActionProvider.schema_hash(open, config: config) == Enum.at(specs, 0).schema_hash

    assert nil ==
             ActionProvider.schema_hash(
               Action.new(:missing, via: :lens),
               config: config
             )

    look = Action.new(:look, via: :lens, args: %{tab: ref, opts: [include: [:markdown]]})

    assert {:ok, %SpectreLens.View{markdown: "# Fake page"}} =
             ActionProvider.execute(look, context, config: config)

    temporary_look =
      Action.new(:look,
        via: :lens,
        args: %{
          "url" => "https://example.test/temporary",
          "opts" => [:not_a_keyword]
        }
      )

    assert {:ok, %SpectreLens.View{url: "https://example.test/root"}} =
             ActionProvider.execute(temporary_look, context, config: config)

    assert_receive {:fake_tab_stopped, 1, temporary_id}
    assert is_binary(temporary_id)

    discover =
      Action.new(:discover,
        via: :lens,
        args: %{
          url: "https://example.test",
          goal: "docs",
          opts: [max_pages: 1, max_candidates: 2]
        }
      )

    assert {:ok, %SpectreLens.Discovery{}} =
             ActionProvider.execute(discover, context, config: config)

    act =
      Action.new(:act,
        via: :lens,
        args: %{"tab" => ref, "action" => {:click, "#save"}, "opts" => [timeout: 25]}
      )

    assert {:ok, :ok} = ActionProvider.execute(act, context, config: config)
    assert_receive {:fake_clicked, _id, "#save", click_opts}
    assert click_opts[:network_policy] == :any
    assert click_opts[:include] == [:markdown]
    assert click_opts[:timeout] == 25

    for {type, expected} <- [
          {:screenshot, "png"},
          {"html", "<html><body>Fake page</body></html>"},
          {"markdown", "# Fake page"},
          {"pdf", "pdf"}
        ] do
      export = Action.new(:export, via: :lens, args: %{tab: ref, type: type})
      assert {:ok, ^expected} = ActionProvider.execute(export, context, config: config)
    end

    assert {:ok, tab} = SpectreLens.resolve_tab(runtime, ref)
    assert :ok = SpectreLens.close_tab(tab)
    assert :ok = SpectreLens.close(runtime)
  end

  test "Lens action provider fails closed on policy, runtime and argument violations" do
    alias Spectre.Action
    alias Spectre.Context
    alias Spectre.Lens.ActionProvider
    alias SpectreLens.StackContractAgent

    base_config = %{options: [planner_exposure: :all], backend: nil, policy: nil}
    no_runtime = %Context{agent: StackContractAgent, opts: []}

    assert Enum.all?(
             ActionProvider.actions(config: base_config),
             &(&1.visibility == :both)
           )

    mismatch = Action.new(:look, via: :other, args: %{})

    assert {:error, {:lens_action_provider_mismatch, :other}} =
             ActionProvider.execute(mismatch, no_runtime, config: base_config)

    assert {:error, {:unsupported_lens_operation, :unknown}} =
             ActionProvider.execute(
               Action.new(:unknown, via: :lens),
               no_runtime,
               config: base_config
             )

    assert {:error, :lens_runtime_required} =
             ActionProvider.execute(
               Action.new(:look, via: :lens, args: %{url: "https://example.test"}),
               no_runtime,
               config: base_config
             )

    assert {:ok, runtime} =
             SpectreLens.open(
               backend: FakeBackend,
               protocol: FakeProtocol,
               test_pid: self(),
               network_policy: :any
             )

    context = %Context{
      agent: StackContractAgent,
      opts: [lens_runtime: runtime, lens_opts: [network_policy: :any]]
    }

    for {reply, expected} <- [
          {false, {:error, {:lens_policy_denied, :open}}},
          {{:error, :blocked}, {:error, :blocked}},
          {:unexpected, {:error, {:invalid_lens_policy_reply, ConfigurablePolicy, :unexpected}}}
        ] do
      config = %{
        base_config
        | policy: %{module: ConfigurablePolicy, options: [reply: reply]}
      }

      action = Action.new(:open, via: :lens, args: %{url: "https://example.test"})
      assert ActionProvider.execute(action, context, config: config) == expected
    end

    for reply <- [:ok, true] do
      config = %{
        base_config
        | policy: %{module: ConfigurablePolicy, options: [reply: reply]}
      }

      action = Action.new(:open, via: :lens, args: %{url: "https://example.test"})
      assert {:ok, ref} = ActionProvider.execute(action, context, config: config)
      assert {:ok, tab} = SpectreLens.resolve_tab(runtime, ref)
      assert :ok = SpectreLens.close_tab(tab)
    end

    assert {:error, {:missing_lens_argument, :url}} =
             ActionProvider.execute(
               Action.new(:open, via: :lens, args: %{}),
               context,
               config: base_config
             )

    assert {:error, :nonportable_lens_tab} =
             ActionProvider.execute(
               Action.new(:look, via: :lens, args: %{tab: %Tab{}}),
               context,
               config: base_config
             )

    assert {:error, {:invalid_lens_tab, :bad}} =
             ActionProvider.execute(
               Action.new(:look, via: :lens, args: %{tab: :bad}),
               context,
               config: base_config
             )

    assert {:ok, valid_tab} = SpectreLens.new_tab(runtime, tab_id: "argument-check")
    assert {:ok, valid_ref} = TabRef.new(valid_tab)

    assert {:error, {:missing_lens_argument, :action}} =
             ActionProvider.execute(
               Action.new(:act, via: :lens, args: %{tab: valid_ref}),
               context,
               config: base_config
             )

    assert {:error, :nonportable_lens_tab} =
             ActionProvider.execute(
               Action.new(:act, via: :lens, args: %{tab: %Tab{}, action: :click}),
               context,
               config: base_config
             )

    assert {:error, {:invalid_lens_tab_ref, :bad}} =
             ActionProvider.execute(
               Action.new(:act, via: :lens, args: %{tab: :bad, action: :click}),
               context,
               config: base_config
             )

    assert :ok = SpectreLens.close_tab(valid_tab)
    assert :ok = SpectreLens.close(runtime)
  end

  test "public facade keeps perception, action and export behavior backend-neutral" do
    assert {:ok, runtime} =
             SpectreLens.open(
               backend: FakeBackend,
               protocol: FakeProtocol,
               test_pid: self(),
               network_policy: :any,
               max_tabs_per_instance: 3
             )

    assert {:ok, tab} =
             SpectreLens.new_tab(runtime,
               tab_id: "facade",
               url: "https://example.test"
             )

    assert {:ok, view} =
             SpectreLens.look(tab,
               include: [
                 :markdown,
                 :semantic_tree,
                 :interactive,
                 :forms,
                 :links,
                 :structured_data,
                 :html
               ]
             )

    assert view.markdown == "# Fake page"
    assert view.title == "Fake page"
    assert view.links == [%{"href" => "https://example.test/docs", "text" => "Docs"}]

    assert :ok = SpectreLens.act(tab, {:click, "#save"}, timeout: 10)
    assert_receive {:fake_clicked, "facade", "#save", [timeout: 10]}

    assert :ok = SpectreLens.act(tab, {:fill, ref: "#name", value: "Ada"})
    assert_receive {:fake_filled, "facade", "#name", "Ada", []}

    assert :ok =
             SpectreLens.act(
               tab,
               {:submit, form: "#search", fields: %{q: "lens"}}
             )

    assert_receive {:fake_submitted, "facade", "#search", %{q: "lens"}, []}
    assert :ok = SpectreLens.act(tab, {:submit, "#search"})
    assert_receive {:fake_submitted, "facade", "#search", %{}, []}

    assert :ok = SpectreLens.act(tab, {:scroll, by: 200}, timeout: 30)
    assert_receive {:fake_scrolled, "facade", scroll_opts}
    assert scroll_opts[:by] == 200
    assert scroll_opts[:timeout] == 30

    assert {:error, {:unknown_action, :invalid}} = SpectreLens.act(tab, :invalid)

    directory =
      Path.join(
        System.tmp_dir!(),
        "spectre-lens-facade-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(directory) end)

    assert {:ok, html_path} =
             SpectreLens.export(tab, :html, to: Path.join(directory, "page.html"))

    assert File.read!(html_path) == "<html><body>Fake page</body></html>"

    assert {:ok, markdown_path} =
             SpectreLens.export(tab, :markdown, path: Path.join(directory, "page.md"))

    assert File.read!(markdown_path) == "# Fake page"
    assert {:error, {:unknown_export, :video}} = SpectreLens.export(tab, :video)

    assert {:ok, page_map} = SpectreLens.unfocus(tab)
    assert {:ok, ^page_map} = SpectreLens.zoom_in(tab, hd(page_map.regions))
    assert {:ok, ^page_map} = SpectreLens.zoom_in(tab, "#main")

    assert {:ok, outline} = SpectreLens.outline(tab, detailed?: true)
    assert outline.sections != []
    assert {:error, :missing_url} = SpectreLens.outline(runtime)
    assert {:error, :missing_url} = SpectreLens.discover(runtime)

    assert {:ok, discovery} =
             SpectreLens.discover(runtime,
               url: "https://example.test",
               goal: "docs",
               max_pages: 1
             )

    assert %SpectreLens.Discovery{} = discovery

    assert {:ok, %{method: "Browser.getVersion", params: %{}}} =
             SpectreLens.command(tab, "Browser.getVersion")

    assert {:ok, %{method: "Runtime.enable"}} = SpectreLens.cdp(tab, "Runtime.enable")

    assert {:ok, wrapped_map} =
             SpectreLens.agent_context(page_map, source_url: "https://example.test")

    assert wrapped_map =~ "BEGIN UNTRUSTED WEB CONTENT"

    assert {:ok, wrapped_outline} =
             SpectreLens.agent_context(outline, source_url: "https://example.test")

    assert wrapped_outline =~ outline.text

    assert {:ok, wrapped_discovery} = SpectreLens.agent_context(discovery)
    assert wrapped_discovery =~ "Best Candidates"
    assert wrapped_discovery =~ "ESCAPED BEGIN UNTRUSTED WEB CONTENT MARKER"

    semantic_view = %SpectreLens.View{
      semantic_text: "main: Fake page",
      url: "https://example.test"
    }

    assert {:ok, semantic_context} =
             SpectreLens.agent_context(semantic_view, prefer: :semantic_text)

    assert semantic_context =~ "Fake page"

    llms_view = %SpectreLens.View{
      llms_context: "# Agent context",
      url: "https://example.test"
    }

    assert {:ok, llms_context} = SpectreLens.agent_context(llms_view, prefer: :llms)
    assert llms_context =~ "Agent context"

    assert {:ok, html_context} = SpectreLens.agent_context(view, prefer: :html)
    assert html_context =~ "<html>"

    assert {:error, :no_agent_context} =
             SpectreLens.agent_context(%SpectreLens.View{}, prefer: :llms)

    assert {:error, {:invalid_agent_context_preference, :raw}} =
             SpectreLens.agent_context(view, prefer: :raw)

    assert {:error, :unsupported_agent_context} = SpectreLens.agent_context(%{})
    assert SpectreLens.explain_error({:unknown_action, :invalid}).type == :unknown_action

    assert :ok = SpectreLens.close(runtime)
  end

  test "one-shot outline and discovery own and clean their temporary runtime" do
    runtime_opts = [
      backend: FakeBackend,
      protocol: FakeProtocol,
      test_pid: self(),
      network_policy: :any,
      max_tabs_per_instance: 2
    ]

    assert {:ok, outline} =
             SpectreLens.outline(
               [
                 :detailed,
                 url: "https://example.test",
                 max_regions: 5
               ] ++ runtime_opts
             )

    assert outline.detailed?
    assert outline.text =~ "Fake Content"

    assert {:ok, discovery} =
             SpectreLens.discover(
               [
                 url: "https://example.test",
                 goal: "docs",
                 max_pages: 1
               ] ++ runtime_opts
             )

    assert discovery.candidates != []

    assert {:ok, from_url} =
             SpectreLens.discover(
               "https://example.test",
               runtime_opts ++ [goal: "docs", max_pages: 1]
             )

    assert from_url.root_url == "https://example.test/root"

    assert {:error, :missing_url} = SpectreLens.outline(runtime_opts)
    assert {:error, :missing_url} = SpectreLens.discover(runtime_opts)
  end

  test "public llms context works from both a URL and a live tab without hidden I/O" do
    document =
      """
      # Example

      > Agent documentation.

      ## Docs
      - [Guide](/guide): Start here
      """

    full_document = "# Full\n\nComplete context."

    fetcher = fn url, _opts ->
      cond do
        String.ends_with?(url, "llms-full.txt") -> {:ok, full_document}
        String.ends_with?(url, "llms-ctx-full.txt") -> {:error, :missing}
        String.ends_with?(url, "llms.txt") -> {:ok, document}
        true -> {:error, :unexpected_url}
      end
    end

    opts = [network_policy: :any, fetcher: fetcher, full?: true]

    assert {:ok, %SpectreLens.LlmsTxt{} = doc} =
             SpectreLens.llms("https://example.test/docs", opts)

    assert doc.title == "Example"
    assert doc.full_content == full_document

    assert {:ok, raw_context} =
             SpectreLens.llms_context(
               "https://example.test/docs",
               Keyword.put(opts, :raw?, true)
             )

    assert raw_context == full_document
    assert {:ok, wrapped_context} = SpectreLens.agent_context(doc, prefer: :index)
    assert wrapped_context =~ "BEGIN UNTRUSTED WEB CONTENT"
    assert wrapped_context =~ "Agent documentation"

    assert {:ok, runtime} =
             SpectreLens.open(
               backend: FakeBackend,
               protocol: FakeProtocol,
               test_pid: self(),
               network_policy: :any
             )

    assert {:ok, tab} = SpectreLens.new_tab(runtime, tab_id: "llms-tab")

    assert {:ok, from_tab} =
             SpectreLens.llms(tab, fetcher: fetcher, full?: false)

    assert from_tab.title == "Example"
    assert from_tab.full_content == nil

    assert {:ok, view} = SpectreLens.look(tab)
    assert view.markdown == "# Fake page"

    assert {:ok, watcher} = SpectreLens.watch(tab)
    assert_receive {:spectre_lens_watch, watcher_pid, :initial, _view}
    assert watcher.pid == watcher_pid
    assert :ok = SpectreLens.stop_watch(watcher)
    assert :ok = SpectreLens.stop_watch(watcher)

    assert {:ok, _saved} =
             SpectreLens.save_session(%{tab | session_key: :default}, replace?: true)

    assert :ok = SpectreLens.close(runtime)
  end

  defp assert_runtime_idle(runtime) do
    assert wait_until(fn ->
             case Runtime.info(runtime) do
               %{instances: [%{active_tabs: 0, pending_tabs: 0}]} -> true
               _other -> false
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
end
