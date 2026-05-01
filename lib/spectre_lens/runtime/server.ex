defmodule SpectreLens.Runtime do
  @moduledoc """
  Runtime handle and pool manager for one or more Lightpanda instances.
  """

  use GenServer

  alias SpectreLens.CDP.Connection
  alias SpectreLens.Telemetry

  defstruct [:pid]

  @type t :: %__MODULE__{pid: pid()}
  @typep state :: %{instances: [map()], max_tabs: pos_integer(), driver: module()}

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

  @doc false
  def release_tab(pid, tab) when is_pid(pid), do: GenServer.cast(pid, {:release_tab, tab})

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    instance_count = opts[:instances] || 1
    max_tabs = opts[:max_tabs_per_instance] || 8
    driver = SpectreLens.Protocol.driver(opts)

    case start_instances(instance_count, opts) do
      {:ok, instances} ->
        {:ok, %{instances: instances, max_tabs: max_tabs, driver: driver}}

      {:error, reason, started} ->
        cleanup(started)
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:new_tab, opts}, _from, state) do
    with {:ok, instance} <- available_instance(state),
         {:ok, tab} <- open_tab(instance, opts),
         {:ok, tab} <- maybe_navigate(tab, opts) do
      instances = bump_tabs(state.instances, instance.id, 1)
      {:reply, {:ok, tab}, %{state | instances: instances}}
    else
      {:error, {:navigation_failed, tab, reason}} ->
        SpectreLens.Protocol.close_tab(tab)
        {:reply, {:error, reason}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:release_tab, tab}, state) do
    Telemetry.emit([:spectre_lens, :runtime, :tab_released], %{}, %{
      instance_id: tab.instance_id,
      target_id: tab.target_id
    })

    {:noreply, %{state | instances: bump_tabs(state.instances, tab.instance_id, -1)}}
  end

  @impl true
  def terminate(_reason, state) do
    cleanup(state.instances)
    :ok
  end

  @spec available_instance(state()) :: {:ok, map()} | {:error, :tab_capacity_exceeded}
  defp available_instance(state) do
    case choose_instance(state.instances, state.max_tabs) do
      nil -> {:error, :tab_capacity_exceeded}
      instance -> {:ok, instance}
    end
  end

  @spec open_tab(map(), keyword()) :: {:ok, SpectreLens.Tab.t()} | {:error, term()}
  defp open_tab(instance, opts) do
    SpectreLens.Protocol.new_tab(instance, Keyword.put(opts, :runtime, self()))
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

  @spec choose_instance([map()], pos_integer()) :: map() | nil
  defp choose_instance(instances, max_tabs) do
    instances
    |> Enum.filter(&(&1.tabs < max_tabs))
    |> Enum.min_by(& &1.tabs, fn -> nil end)
  end

  @spec bump_tabs([map()], term(), integer()) :: [map()]
  defp bump_tabs(instances, id, delta) do
    Enum.map(instances, fn
      %{id: ^id, tabs: tabs} = instance -> %{instance | tabs: max(tabs + delta, 0)}
      instance -> instance
    end)
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
    %{
      instances: opts[:instances] || 1,
      max_tabs_per_instance: opts[:max_tabs_per_instance] || 8
    }
  end
end
