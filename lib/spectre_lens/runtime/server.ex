defmodule SpectreLens.Runtime do
  @moduledoc """
  Runtime handle and pool manager for one or more Lightpanda instances.
  """

  use GenServer

  alias SpectreLens.CDP.Connection
  alias SpectreLens.{Session, Tab}
  alias SpectreLens.Telemetry

  defstruct [:pid]

  @type t :: %__MODULE__{pid: pid()}
  @typep state :: %{
           instances: [map()],
           max_tabs: pos_integer(),
           driver: module(),
           session_table: :ets.tid(),
           url_policy: keyword(),
           pending_tabs: map(),
           caller_monitors: map(),
           destroyed_targets: MapSet.t(binary())
         }

  @doc "Starts a runtime pool."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    Telemetry.span([:spectre_lens, :runtime, :start], runtime_metadata(opts), fn ->
      result = GenServer.start_link(__MODULE__, opts)
      {result, %{result: result}}
    end)
  end

  @doc "Creates a new tab on the least-loaded Lightpanda instance."
  @spec new_tab(t() | pid(), keyword()) :: {:ok, SpectreLens.Tab.t()} | {:error, term()}
  def new_tab(%__MODULE__{pid: pid}, opts), do: new_tab(pid, opts)

  def new_tab(pid, opts) when is_pid(pid) do
    Telemetry.span([:spectre_lens, :runtime, :new_tab], %{runtime: inspect(pid)}, fn ->
      result = GenServer.call(pid, {:new_tab, opts}, :infinity)
      {result, %{result: result}}
    end)
  end

  @doc "Closes the runtime and all owned Lightpanda instances."
  @spec close(t() | pid()) :: :ok
  def close(%__MODULE__{pid: pid}), do: close(pid)

  def close(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal, 30_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  @doc "Returns a stored logical browser session."
  @spec get_session(t() | pid(), term()) :: {:ok, Session.t()} | {:error, term()}
  def get_session(%__MODULE__{pid: pid}, key), do: get_session(pid, key)

  def get_session(pid, key) when is_pid(pid) do
    GenServer.call(pid, {:get_session, key})
  end

  @doc "Stores a logical browser session snapshot."
  @spec put_session(t() | pid(), term(), Session.t() | map() | keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  def put_session(%__MODULE__{pid: pid}, key, session), do: put_session(pid, key, session)

  def put_session(pid, key, session) when is_pid(pid) do
    GenServer.call(pid, {:put_session, key, session})
  end

  @doc "Deletes a stored logical browser session."
  @spec delete_session(t() | pid(), term()) :: :ok
  def delete_session(%__MODULE__{pid: pid}, key), do: delete_session(pid, key)

  def delete_session(pid, key) when is_pid(pid) do
    GenServer.call(pid, {:delete_session, key})
  end

  @doc "Exports a stored logical browser session as a JSON-safe map."
  @spec export_session(t() | pid(), term()) :: {:ok, map()} | {:error, term()}
  def export_session(%__MODULE__{pid: pid}, key), do: export_session(pid, key)

  def export_session(pid, key) when is_pid(pid) do
    GenServer.call(pid, {:export_session, key})
  end

  @doc "Imports a JSON-safe logical browser session snapshot."
  @spec import_session(t() | pid(), term(), map() | keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  def import_session(runtime, key, session), do: put_session(runtime, key, session)

  @doc "Captures a tab's browser session into the runtime ETS table."
  @spec save_session(Tab.t(), term() | nil, keyword()) :: {:ok, Session.t()} | {:error, term()}
  def save_session(tab, key \\ nil, opts \\ [])

  def save_session(%Tab{runtime: runtime} = tab, key, opts) when is_pid(runtime) do
    with {:ok, key} <- save_key(tab, key),
         {:ok, captured} <- SpectreLens.Page.session_snapshot(tab, opts) do
      GenServer.call(runtime, {:store_captured_session, key, captured, opts})
    end
  end

  def save_session(%Tab{}, _key, _opts), do: {:error, :missing_runtime}

  @doc "Marks a tab as closed so the runtime can reuse instance capacity."
  def release_tab(pid, tab) when is_pid(pid), do: GenServer.cast(pid, {:release_tab, tab})

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    instance_count = opts[:instances] || 1
    driver = SpectreLens.Protocol.driver(opts)
    max_tabs = effective_max_tabs_per_instance(driver, opts)
    session_table = :ets.new(:spectre_lens_sessions, [:set, :protected, :compressed])
    url_policy = SpectreLens.URLPolicy.take_options(opts)

    case start_instances(instance_count, opts) do
      {:ok, instances} ->
        {:ok,
         %{
           instances: instances,
           max_tabs: max_tabs,
           driver: driver,
           session_table: session_table,
           url_policy: url_policy,
           pending_tabs: %{},
           caller_monitors: %{},
           destroyed_targets: MapSet.new()
         }}

      {:error, reason, started} ->
        cleanup(started)
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:new_tab, opts}, from, state) do
    opts = Keyword.merge(state.url_policy, opts)

    with {:ok, opts} <- prepare_session_opts(state.session_table, opts),
         {:ok, instance} <- available_instance(state, opts) do
      {:noreply, start_tab_worker(state, from, instance, opts)}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get_session, key}, _from, state) do
    {:reply, lookup_session(state.session_table, key), state}
  end

  def handle_call({:put_session, key, session}, _from, state) do
    result = put_session_snapshot(state.session_table, key, session)
    {:reply, result, state}
  end

  def handle_call({:delete_session, key}, _from, state) do
    :ets.delete(state.session_table, key)
    {:reply, :ok, state}
  end

  def handle_call({:export_session, key}, _from, state) do
    result =
      with {:ok, session} <- lookup_session(state.session_table, key) do
        {:ok, Session.to_map(session)}
      end

    {:reply, result, state}
  end

  def handle_call({:store_captured_session, key, captured, opts}, _from, state) do
    result = merge_or_replace_session(state.session_table, key, captured, opts)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_cast({:release_tab, tab}, state) do
    {instances, released?} = release_registered_tab(state.instances, tab)

    if released? do
      Telemetry.emit([:spectre_lens, :runtime, :tab_released], %{}, %{
        instance_id: tab.instance_id,
        target_id: tab.target_id
      })
    end

    {:noreply, %{state | instances: instances}}
  end

  @impl GenServer
  def handle_info({stream, _os_pid, _data}, state) when stream in [:stdout, :stderr] do
    {:noreply, state}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.pending_tabs, ref) do
      {nil, _pending_tabs} ->
        {:noreply, state}

      {pending, pending_tabs} ->
        Process.demonitor(ref, [:flush])
        Process.demonitor(pending.caller_monitor, [:flush])

        state = %{
          state
          | pending_tabs: pending_tabs,
            caller_monitors: Map.delete(state.caller_monitors, pending.caller_monitor),
            instances: release_reservation(state.instances, pending.instance_id, pending.reservation)
        }

        pending =
          if pending.caller_alive? and Process.alive?(elem(pending.from, 0)) do
            pending
          else
            %{pending | caller_alive?: false}
          end

        {state, result} = reject_destroyed_target(state, result)
        {:noreply, finish_tab_worker(state, pending, result)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    cond do
      pending = Map.get(state.pending_tabs, ref) ->
        state = drop_failed_worker(state, ref, pending)

        if pending.caller_alive? do
          GenServer.reply(pending.from, {:error, {:tab_worker_down, reason}})
        end

        {:noreply, state}

      task_ref = Map.get(state.caller_monitors, ref) ->
        pending_tabs = mark_caller_dead(state.pending_tabs, task_ref)

        {:noreply,
         %{
           state
           | pending_tabs: pending_tabs,
             caller_monitors: Map.delete(state.caller_monitors, ref)
         }}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:spectre_lens_cdp_event, "Target.targetDestroyed", _session_id,
         %{"targetId" => target_id}},
        state
      ) do
    {instances, tabs} = release_target(state.instances, target_id)
    Enum.each(tabs, &SpectreLens.CDP.RequestGuard.target_closed(&1.request_guard))

    destroyed_targets =
      if tabs == [] and map_size(state.pending_tabs) > 0 do
        remember_destroyed_target(state.destroyed_targets, target_id)
      else
        state.destroyed_targets
      end

    {:noreply,
     %{state | instances: instances, destroyed_targets: destroyed_targets}}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    case Enum.find(state.instances, &(Map.get(&1, :conn) == pid)) do
      nil -> {:noreply, state}
      instance -> {:stop, {:connection_down, instance.id, reason}, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    shutdown_pending_workers(state.pending_tabs)
    cleanup(state.instances)
    :ok
  end

  @spec available_instance(state(), keyword()) ::
          {:ok, map()} | {:error, :tab_capacity_exceeded | :session_context_capacity_exceeded}
  defp available_instance(state, opts) do
    session_tab? = Keyword.has_key?(opts, :session_key)

    case choose_instance(state.instances, state.max_tabs, session_tab?) do
      nil when session_tab? -> {:error, :session_context_capacity_exceeded}
      nil -> {:error, :tab_capacity_exceeded}
      instance -> {:ok, instance}
    end
  end

  @spec start_tab_worker(state(), GenServer.from(), map(), keyword()) :: state()
  defp start_tab_worker(state, from, instance, opts) do
    reservation = make_ref()
    runtime = self()
    task = Task.async(fn -> setup_tab(instance, opts, runtime) end)
    caller_monitor = Process.monitor(elem(from, 0))

    pending = %{
      task: task,
      from: from,
      caller_monitor: caller_monitor,
      caller_alive?: true,
      instance_id: instance.id,
      reservation: reservation
    }

    %{
      state
      | instances: reserve_instance(state.instances, instance.id, reservation, opts),
        pending_tabs: Map.put(state.pending_tabs, task.ref, pending),
        caller_monitors: Map.put(state.caller_monitors, caller_monitor, task.ref)
    }
  end

  @spec setup_tab(map(), keyword(), pid()) :: {:ok, Tab.t()} | {:error, term()}
  defp setup_tab(instance, opts, runtime) do
    case open_tab(instance, opts) do
      {:ok, tab} -> finish_tab_setup(tab, opts, runtime)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec finish_tab_setup(Tab.t(), keyword(), pid()) :: {:ok, Tab.t()} | {:error, term()}
  defp finish_tab_setup(tab, opts, runtime) do
    result =
      SpectreLens.Errors.safe(:tab_setup, fn ->
        with {:ok, tab} <- maybe_navigate(tab, opts),
             {:ok, tab} <- maybe_restore_session(tab, opts) do
          {:ok, %{tab | runtime: runtime}}
        end
      end)

    case result do
      {:ok, _tab} = ok ->
        ok

      {:error, {:navigation_failed, _tab, reason}} ->
        close_setup_tab(tab)
        {:error, reason}

      {:error, reason} ->
        close_setup_tab(tab)
        {:error, reason}
    end
  end

  @spec close_setup_tab(Tab.t()) :: :ok
  defp close_setup_tab(tab) do
    SpectreLens.Errors.safe(:close_setup_tab, fn ->
      SpectreLens.Protocol.close_tab(%{tab | runtime: nil})
    end)

    :ok
  end

  @spec finish_tab_worker(state(), map(), {:ok, Tab.t()} | {:error, term()}) :: state()
  defp finish_tab_worker(state, %{caller_alive?: true} = pending, {:ok, tab}) do
    GenServer.reply(pending.from, {:ok, tab})
    %{state | instances: register_tab(state.instances, pending.instance_id, tab)}
  end

  defp finish_tab_worker(state, %{caller_alive?: true} = pending, {:error, reason}) do
    GenServer.reply(pending.from, {:error, reason})
    state
  end

  defp finish_tab_worker(state, %{caller_alive?: false}, {:ok, tab}) do
    close_setup_tab(tab)
    state
  end

  defp finish_tab_worker(state, %{caller_alive?: false}, {:error, _reason}), do: state

  @spec reject_destroyed_target(state(), {:ok, Tab.t()} | {:error, term()}) ::
          {state(), {:ok, Tab.t()} | {:error, term()}}
  defp reject_destroyed_target(state, {:ok, %Tab{target_id: target_id} = tab} = result)
       when is_binary(target_id) do
    if MapSet.member?(state.destroyed_targets, target_id) do
      SpectreLens.CDP.RequestGuard.target_closed(tab.request_guard)

      Task.start(fn -> close_setup_tab(%{tab | request_guard: nil}) end)

      {%{state | destroyed_targets: MapSet.delete(state.destroyed_targets, target_id)},
       {:error, :target_closed}}
    else
      {state, result}
    end
  end

  defp reject_destroyed_target(state, result), do: {state, result}

  @spec remember_destroyed_target(MapSet.t(binary()), binary()) :: MapSet.t(binary())
  defp remember_destroyed_target(targets, target_id) do
    if MapSet.size(targets) >= 128 do
      MapSet.new([target_id])
    else
      MapSet.put(targets, target_id)
    end
  end

  @spec mark_caller_dead(map(), reference()) :: map()
  defp mark_caller_dead(pending_tabs, task_ref) do
    case Map.fetch(pending_tabs, task_ref) do
      {:ok, pending} -> Map.put(pending_tabs, task_ref, %{pending | caller_alive?: false})
      :error -> pending_tabs
    end
  end

  @spec drop_failed_worker(state(), reference(), map()) :: state()
  defp drop_failed_worker(state, ref, pending) do
    Process.demonitor(pending.caller_monitor, [:flush])

    %{
      state
      | pending_tabs: Map.delete(state.pending_tabs, ref),
        caller_monitors: Map.delete(state.caller_monitors, pending.caller_monitor),
        instances: release_reservation(state.instances, pending.instance_id, pending.reservation)
    }
  end

  @spec open_tab(map(), keyword()) :: {:ok, SpectreLens.Tab.t()} | {:error, term()}
  defp open_tab(instance, opts) do
    tab_opts =
      opts
      |> Keyword.put(:runtime, nil)
      |> Keyword.put(:url, "about:blank")

    SpectreLens.Protocol.new_tab(instance, tab_opts)
  end

  @spec maybe_navigate(SpectreLens.Tab.t(), keyword()) ::
          {:ok, SpectreLens.Tab.t()} | {:error, {:navigation_failed, SpectreLens.Tab.t(), term()}}
  defp maybe_navigate(tab, opts) do
    case opts[:url] do
      nil ->
        {:ok, tab}

      "about:blank" ->
        {:ok, tab}

      url ->
        case SpectreLens.Protocol.navigate(tab, url, opts) do
          :ok -> {:ok, tab}
          {:error, reason} -> {:error, {:navigation_failed, tab, reason}}
        end
    end
  end

  @spec maybe_restore_session(Tab.t(), keyword()) :: {:ok, Tab.t()} | {:error, term()}
  defp maybe_restore_session(tab, opts) do
    if Keyword.has_key?(opts, :session_key) and restorable_url?(opts[:url]) do
      case SpectreLens.Page.restore_session(tab, opts[:session_snapshot], opts) do
        :ok -> {:ok, tab}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, tab}
    end
  end

  @spec prepare_session_opts(:ets.tid(), keyword()) :: {:ok, keyword()} | {:error, term()}
  defp prepare_session_opts(table, opts) do
    case Keyword.fetch(opts, :session) do
      :error ->
        {:ok, opts}

      {:ok, nil} ->
        {:ok, Keyword.delete(opts, :session)}

      {:ok, key} ->
        prepare_named_session_opts(table, opts, key)
    end
  end

  @spec prepare_named_session_opts(:ets.tid(), keyword(), term()) ::
          {:ok, keyword()} | {:error, {:unknown_session, term()}}
  defp prepare_named_session_opts(table, opts, key) do
    case lookup_session(table, key) do
      {:ok, session} ->
        {:ok, put_session_opts(opts, key, session)}

      {:error, {:unknown_session, ^key}} ->
        missing_session_opts(opts, key)
    end
  end

  @spec missing_session_opts(keyword(), term()) ::
          {:ok, keyword()} | {:error, {:unknown_session, term()}}
  defp missing_session_opts(opts, key) do
    if opts[:require_session?] do
      {:error, {:unknown_session, key}}
    else
      {:ok, put_session_opts(opts, key, Session.new())}
    end
  end

  @spec put_session_opts(keyword(), term(), Session.t()) :: keyword()
  defp put_session_opts(opts, key, session) do
    opts
    |> Keyword.put(:session_key, key)
    |> Keyword.put(:session_snapshot, session)
  end

  @spec restorable_url?(term()) :: boolean()
  defp restorable_url?(nil), do: false
  defp restorable_url?("about:blank"), do: false
  defp restorable_url?(url) when is_binary(url), do: true
  defp restorable_url?(_other), do: false

  @spec lookup_session(:ets.tid(), term()) :: {:ok, Session.t()} | {:error, term()}
  defp lookup_session(table, key) do
    case :ets.lookup(table, key) do
      [{^key, %Session{} = session}] -> {:ok, session}
      [] -> {:error, {:unknown_session, key}}
    end
  end

  @spec put_session_snapshot(:ets.tid(), term(), Session.t() | map() | keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  defp put_session_snapshot(table, key, session) do
    with {:ok, %Session{} = normalized} <- Session.normalize(session) do
      stored = Session.touch(normalized)
      :ets.insert(table, {key, stored})
      {:ok, stored}
    end
  end

  @spec save_key(Tab.t(), term() | nil) :: {:ok, term()} | {:error, term()}
  defp save_key(%Tab{session_key: session_key}, nil) when not is_nil(session_key),
    do: {:ok, session_key}

  defp save_key(_tab, nil), do: {:error, :missing_session_key}
  defp save_key(_tab, key), do: {:ok, key}

  @spec merge_or_replace_session(:ets.tid(), term(), Session.t(), keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  defp merge_or_replace_session(table, key, captured, opts) do
    stored =
      if opts[:replace?] do
        Session.touch(captured)
      else
        case lookup_session(table, key) do
          {:ok, existing} -> Session.merge(existing, captured)
          {:error, _} -> Session.touch(captured)
        end
      end

    :ets.insert(table, {key, stored})
    {:ok, stored}
  end

  @spec start_instances(pos_integer(), keyword()) :: {:ok, [map()]} | {:error, term(), [map()]}
  defp start_instances(count, opts) do
    Enum.reduce_while(1..count, {:ok, []}, fn index, {:ok, acc} ->
      case start_instance(index, count, opts) do
        {:ok, instance} ->
          {:cont, {:ok, [instance | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason, acc}}
      end
    end)
    |> case do
      {:ok, instances} -> {:ok, Enum.reverse(instances)}
      other -> other
    end
  end

  @spec start_instance(pos_integer(), pos_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  defp start_instance(index, count, opts) do
    instance_opts =
      opts
      |> Keyword.drop([:instances, :max_tabs_per_instance, :port])
      |> Keyword.put(:id, index)
      |> maybe_put(:port, port_for(opts, index, count))

    with {:ok, lightpanda} <- SpectreLens.Lightpanda.start_instance(instance_opts) do
      open_instance(lightpanda, opts)
    end
  end

  @spec open_instance(map(), keyword()) :: {:ok, map()} | {:error, term()}
  defp open_instance(lightpanda, opts) do
    case Connection.open(lightpanda.endpoint) do
      {:ok, conn} ->
        :ok = Connection.subscribe_event(conn, "Target.targetDestroyed", nil, self())

        instance =
          lightpanda
          |> Map.put(:conn, conn)
          |> Map.put(:driver, SpectreLens.Protocol.driver(opts))
          |> Map.put(:tabs, %{})
          |> Map.put(:reservations, %{})

        {:ok, instance}

      {:error, reason} ->
        SpectreLens.Lightpanda.stop_instance(lightpanda)
        {:error, reason}
    end
  end

  @spec port_for(keyword(), pos_integer(), pos_integer()) :: pos_integer() | nil
  defp port_for(opts, index, count) do
    ports = opts[:ports]

    cond do
      is_list(ports) -> Enum.at(ports, index - 1)
      count == 1 -> opts[:port]
      true -> nil
    end
  end

  @spec choose_instance([map()], pos_integer(), boolean()) :: map() | nil
  defp choose_instance(instances, max_tabs, session_tab?) do
    instances
    |> Enum.filter(&instance_available?(&1, max_tabs, session_tab?))
    |> Enum.min_by(&{session_context_count(&1), tab_count(&1)}, fn -> nil end)
  end

  @spec instance_available?(map(), pos_integer(), boolean()) :: boolean()
  defp instance_available?(instance, max_tabs, session_tab?) do
    tab_count(instance) < max_tabs and (not session_tab? or session_context_count(instance) < 1)
  end

  @spec effective_max_tabs_per_instance(module(), keyword()) :: pos_integer()
  defp effective_max_tabs_per_instance(SpectreLens.Protocol.LightpandaCDP, _opts), do: 1

  defp effective_max_tabs_per_instance(_driver, opts), do: opts[:max_tabs_per_instance] || 8

  @spec reserve_instance([map()], term(), reference(), keyword()) :: [map()]
  defp reserve_instance(instances, id, reservation, opts) do
    Enum.map(instances, fn
      %{id: ^id} = instance ->
        session? = Keyword.has_key?(opts, :session_key)
        %{instance | reservations: Map.put(instance.reservations, reservation, session?)}

      instance ->
        instance
    end)
  end

  @spec release_reservation([map()], term(), reference()) :: [map()]
  defp release_reservation(instances, id, reservation) do
    Enum.map(instances, fn
      %{id: ^id} = instance ->
        %{instance | reservations: Map.delete(instance.reservations, reservation)}

      instance ->
        instance
    end)
  end

  @spec register_tab([map()], term(), Tab.t()) :: [map()]
  defp register_tab(instances, id, tab) do
    Enum.map(instances, fn
      %{id: ^id} = instance -> %{instance | tabs: Map.put(instance.tabs, tab_key(tab), tab)}
      instance -> instance
    end)
  end

  @spec release_registered_tab([map()], Tab.t()) :: {[map()], boolean()}
  defp release_registered_tab(instances, tab) do
    key = tab_key(tab)

    Enum.map_reduce(instances, false, fn
      %{id: id} = instance, released? when id == tab.instance_id ->
        if Map.has_key?(instance.tabs, key) do
          {%{instance | tabs: Map.delete(instance.tabs, key)}, true}
        else
          {instance, released?}
        end

      instance, released? ->
        {instance, released?}
    end)
  end

  @spec release_target([map()], binary()) :: {[map()], [Tab.t()]}
  defp release_target(instances, target_id) do
    Enum.map_reduce(instances, [], fn instance, released_tabs ->
      {released, kept} =
        Enum.split_with(instance.tabs, fn {_key, tab} -> tab.target_id == target_id end)

      {%{instance | tabs: Map.new(kept)}, Enum.map(released, &elem(&1, 1)) ++ released_tabs}
    end)
  end

  @spec tab_count(map()) :: non_neg_integer()
  defp tab_count(instance), do: map_size(instance.tabs) + map_size(instance.reservations)

  @spec session_context_count(map()) :: non_neg_integer()
  defp session_context_count(instance) do
    active = Enum.count(instance.tabs, fn {_key, tab} -> is_binary(tab.browser_context_id) end)
    reserved = Enum.count(instance.reservations, fn {_ref, session?} -> session? end)
    active + reserved
  end

  @spec tab_key(Tab.t()) :: term()
  defp tab_key(%Tab{target_id: target_id}) when is_binary(target_id), do: {:target, target_id}
  defp tab_key(%Tab{session_id: session_id}) when is_binary(session_id), do: {:session, session_id}
  defp tab_key(%Tab{} = tab), do: {:tab, :erlang.phash2(tab)}

  @spec shutdown_pending_workers(map()) :: :ok
  defp shutdown_pending_workers(pending_tabs) do
    Enum.each(pending_tabs, fn {_ref, pending} ->
      case Task.shutdown(pending.task, 5_000) do
        {:ok, {:ok, tab}} -> close_setup_tab(tab)
        _ -> :ok
      end
    end)

    :ok
  end

  @spec cleanup([map()]) :: :ok
  defp cleanup(instances) do
    Enum.each(instances, fn instance ->
      if Map.has_key?(instance, :conn), do: Connection.close(instance.conn)
      SpectreLens.Lightpanda.stop_instance(instance)
    end)
  end

  @spec maybe_put(keyword(), atom(), term() | nil) :: keyword()
  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  @spec runtime_metadata(keyword()) :: map()
  defp runtime_metadata(opts) do
    driver = SpectreLens.Protocol.driver(opts)

    %{
      instances: opts[:instances] || 1,
      max_tabs_per_instance: effective_max_tabs_per_instance(driver, opts)
    }
  end
end
