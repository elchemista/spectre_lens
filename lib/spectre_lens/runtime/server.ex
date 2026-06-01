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
           session_table: :ets.tid()
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
      result = GenServer.call(pid, {:new_tab, opts}, opts[:timeout] || 30_000)
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
    GenServer.call(runtime, {:save_session, tab, key, opts}, opts[:timeout] || 30_000)
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

    case start_instances(instance_count, opts) do
      {:ok, instances} ->
        {:ok,
         %{instances: instances, max_tabs: max_tabs, driver: driver, session_table: session_table}}

      {:error, reason, started} ->
        cleanup(started)
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:new_tab, opts}, _from, state) do
    with {:ok, opts} <- prepare_session_opts(state.session_table, opts),
         {:ok, instance} <- available_instance(state, opts),
         {:ok, tab} <- open_tab(instance, opts),
         {:ok, tab} <- maybe_navigate(tab, opts),
         {:ok, tab} <- maybe_restore_session(tab, opts) do
      instances = bump_instance_counts(state.instances, instance.id, tab, 1)
      {:reply, {:ok, tab}, %{state | instances: instances}}
    else
      {:error, {:navigation_failed, tab, reason}} ->
        SpectreLens.Protocol.close_tab(tab)
        {:reply, {:error, reason}, state}

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

  def handle_call({:save_session, tab, key, opts}, _from, state) do
    result =
      with {:ok, key} <- save_key(tab, key),
           {:ok, captured} <- SpectreLens.Page.session_snapshot(tab, opts) do
        merge_or_replace_session(state.session_table, key, captured, opts)
      end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_cast({:release_tab, tab}, state) do
    Telemetry.emit([:spectre_lens, :runtime, :tab_released], %{}, %{
      instance_id: tab.instance_id,
      target_id: tab.target_id
    })

    {:noreply,
     %{state | instances: bump_instance_counts(state.instances, tab.instance_id, tab, -1)}}
  end

  @impl GenServer
  def handle_info({stream, _os_pid, _data}, state) when stream in [:stdout, :stderr] do
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
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

  @spec open_tab(map(), keyword()) :: {:ok, SpectreLens.Tab.t()} | {:error, term()}
  defp open_tab(instance, opts) do
    tab_opts =
      opts
      |> Keyword.put(:runtime, self())
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
      instance_opts =
        opts
        |> Keyword.drop([:instances, :max_tabs_per_instance, :port])
        |> Keyword.put(:id, index)
        |> maybe_put(:port, port_for(opts, index, count))

      with {:ok, lightpanda} <- SpectreLens.Lightpanda.start_instance(instance_opts),
           {:ok, conn} <- Connection.open(lightpanda.endpoint) do
        instance =
          lightpanda
          |> Map.put(:conn, conn)
          |> Map.put(:driver, SpectreLens.Protocol.driver(opts))
          |> Map.put(:tabs, 0)
          |> Map.put(:session_contexts, 0)

        {:cont, {:ok, [instance | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason, acc}}
      end
    end)
    |> case do
      {:ok, instances} -> {:ok, Enum.reverse(instances)}
      other -> other
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
    |> Enum.min_by(&{&1.session_contexts, &1.tabs}, fn -> nil end)
  end

  @spec instance_available?(map(), pos_integer(), boolean()) :: boolean()
  defp instance_available?(instance, max_tabs, session_tab?) do
    instance.tabs < max_tabs and (not session_tab? or instance.session_contexts < 1)
  end

  @spec effective_max_tabs_per_instance(module(), keyword()) :: pos_integer()
  defp effective_max_tabs_per_instance(SpectreLens.Protocol.LightpandaCDP, _opts), do: 1

  defp effective_max_tabs_per_instance(_driver, opts), do: opts[:max_tabs_per_instance] || 8

  @spec bump_instance_counts([map()], term(), Tab.t(), integer()) :: [map()]
  defp bump_instance_counts(instances, id, tab, delta) do
    Enum.map(instances, fn
      %{id: ^id, tabs: tabs, session_contexts: session_contexts} = instance ->
        %{
          instance
          | tabs: max(tabs + delta, 0),
            session_contexts: max(session_contexts + session_context_delta(tab, delta), 0)
        }

      instance ->
        instance
    end)
  end

  @spec session_context_delta(Tab.t(), integer()) :: integer()
  defp session_context_delta(%Tab{browser_context_id: browser_context_id}, delta)
       when is_binary(browser_context_id),
       do: delta

  defp session_context_delta(_tab, _delta), do: 0

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
