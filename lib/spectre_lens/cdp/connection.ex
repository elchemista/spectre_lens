defmodule SpectreLens.CDP.Connection do
  @moduledoc """
  Native WebSocket client for Chrome DevTools Protocol.

  This module is deliberately owned by Spectre Lens. It only knows CDP
  transport mechanics: request ids, response routing, session ids and event
  waiters.
  """

  use WebSockex

  alias SpectreLens.Telemetry

  @type endpoint :: binary()
  @type event_waiter :: {pid(), reference()}

  @doc """
  Opens a CDP WebSocket connection.

  `endpoint` may be the HTTP server base URL (`http://127.0.0.1:9222`) or a
  direct WebSocket URL.
  """
  @spec open(term()) :: {:ok, pid()} | {:error, Exception.t()}
  def open(endpoint) do
    with {:ok, endpoint_kind} <- validate_endpoint(endpoint) do
      open_endpoint(endpoint_kind, endpoint)
    end
  end

  @spec open_endpoint(:http | :websocket, endpoint()) ::
          {:ok, pid()} | {:error, Exception.t()}
  defp open_endpoint(:websocket, endpoint) do
    WebSockex.start_link(endpoint, __MODULE__, initial_state())
  rescue
    exception -> {:error, SpectreLens.ConnectionError.new(exception)}
  catch
    kind, reason -> {:error, SpectreLens.ConnectionError.new({kind, reason})}
  end

  defp open_endpoint(:http, endpoint) do
    version_url = version_url(endpoint)

    case Req.get(version_url, retry: false) do
      {:ok, %{status: status, body: %{"webSocketDebuggerUrl" => ws_url}}}
      when status in 200..299 and is_binary(ws_url) ->
        open(ws_url)

      {:ok, %{status: status, body: %{"webSocketDebuggerUrl" => ws_url}}}
      when status in 200..299 ->
        {:error,
         SpectreLens.ConnectionError.new({:invalid_websocket_endpoint, value_type(ws_url)})}

      {:ok, %{status: status, body: body}} ->
        {:error, SpectreLens.ConnectionError.new({:unexpected_version_response, status, body})}

      {:error, reason} ->
        {:error, SpectreLens.ConnectionError.new(reason)}
    end
  rescue
    exception -> {:error, SpectreLens.ConnectionError.new(exception)}
  catch
    kind, reason -> {:error, SpectreLens.ConnectionError.new({kind, reason})}
  end

  @spec validate_endpoint(term()) ::
          {:ok, :http | :websocket} | {:error, SpectreLens.ConnectionError.t()}
  defp validate_endpoint(endpoint) when is_binary(endpoint) and endpoint != "" do
    endpoint |> URI.parse() |> validate_endpoint_uri()
  rescue
    _exception -> invalid_endpoint(:invalid_cdp_endpoint)
  end

  defp validate_endpoint(endpoint),
    do: invalid_endpoint({:invalid_cdp_endpoint_type, value_type(endpoint)})

  @spec validate_endpoint_uri(URI.t()) ::
          {:ok, :http | :websocket} | {:error, SpectreLens.ConnectionError.t()}
  defp validate_endpoint_uri(%URI{scheme: scheme, host: host})
       when scheme in ["ws", "wss"] and is_binary(host) and host != "",
       do: {:ok, :websocket}

  defp validate_endpoint_uri(%URI{scheme: scheme, host: host})
       when scheme in ["http", "https"] and is_binary(host) and host != "",
       do: {:ok, :http}

  defp validate_endpoint_uri(%URI{scheme: scheme})
       when scheme in ["http", "https", "ws", "wss"],
       do: invalid_endpoint(:invalid_cdp_endpoint)

  defp validate_endpoint_uri(%URI{scheme: scheme}) when is_binary(scheme),
    do: invalid_endpoint({:unsupported_cdp_endpoint_scheme, scheme})

  defp validate_endpoint_uri(_invalid), do: invalid_endpoint(:invalid_cdp_endpoint)

  @spec invalid_endpoint(term()) :: {:error, SpectreLens.ConnectionError.t()}
  defp invalid_endpoint(reason), do: {:error, SpectreLens.ConnectionError.new(reason)}

  @spec version_url(endpoint()) :: endpoint()
  defp version_url(endpoint) do
    uri = URI.parse(endpoint)
    path = String.trim_trailing(uri.path || "", "/") <> "/json/version"
    URI.to_string(%{uri | path: path, fragment: nil})
  end

  @doc "Closes a CDP connection process."
  @spec close(pid()) :: :ok
  def close(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      WebSockex.cast(pid, :close)
    end

    :ok
  catch
    _, _ -> :ok
  end

  @doc """
  Sends one CDP command and waits for its result.
  """
  @spec send_command(pid(), binary(), map(), non_neg_integer(), binary() | nil) ::
          {:ok, map()} | {:error, Exception.t()}
  def send_command(pid, method, params \\ %{}, timeout \\ 15_000, session_id \\ nil) do
    metadata = %{method: method, session_id: session_id}

    Telemetry.span([:spectre_lens, :cdp, :command], metadata, fn ->
      result =
        with :ok <- validate_command(pid, method, params, timeout, session_id) do
          send_valid_command(pid, method, params, timeout, session_id)
        end

      {result, %{result: result}}
    end)
  end

  @spec send_valid_command(pid(), binary(), map(), non_neg_integer(), binary() | nil) ::
          {:ok, map()} | {:error, Exception.t()}
  defp send_valid_command(pid, method, params, timeout, session_id) do
    ref = make_ref()
    monitor = Process.monitor(pid)
    WebSockex.cast(pid, {:send_command, method, params, session_id, self(), ref})

    result =
      receive do
        {:spectre_lens_cdp_response, ^ref, response} ->
          {:ok, response}

        {:spectre_lens_cdp_error, ^ref, %{"code" => code, "message" => message}} ->
          {:error, SpectreLens.CDPError.new(code, message, method)}

        {:spectre_lens_cdp_error, ^ref, error} ->
          {:error, SpectreLens.CDPError.new(0, inspect(error), method)}

        {:DOWN, ^monitor, :process, ^pid, reason} ->
          {:error, SpectreLens.ConnectionError.new({:connection_down, reason})}
      after
        timeout ->
          WebSockex.cast(pid, {:cancel_command, self(), ref})
          {:error, SpectreLens.TimeoutError.new(operation: method, timeout_ms: timeout)}
      end

    Process.demonitor(monitor, [:flush])
    result
  end

  @spec validate_command(term(), term(), term(), term(), term()) ::
          :ok | {:error, SpectreLens.ConnectionError.t()}
  defp validate_command(pid, method, params, timeout, session_id) do
    with :ok <- validate_connection(pid),
         :ok <- validate_method(method),
         :ok <- validate_params(params),
         :ok <- validate_command_timeout(timeout) do
      validate_session_id(session_id)
    end
  end

  @spec validate_connection(term()) :: :ok | {:error, SpectreLens.ConnectionError.t()}
  defp validate_connection(pid) when is_pid(pid) do
    if Process.alive?(pid), do: :ok, else: invalid_command(:cdp_connection_closed)
  end

  defp validate_connection(pid), do: invalid_command({:invalid_cdp_connection, pid})

  @spec validate_method(term()) :: :ok | {:error, SpectreLens.ConnectionError.t()}
  defp validate_method(method) when is_binary(method) and method != "", do: :ok
  defp validate_method(method), do: invalid_command({:invalid_cdp_method, method})

  @spec validate_params(term()) :: :ok | {:error, SpectreLens.ConnectionError.t()}
  defp validate_params(params) when is_map(params), do: :ok
  defp validate_params(params), do: invalid_command({:invalid_cdp_params, value_type(params)})

  @spec validate_command_timeout(term()) :: :ok | {:error, SpectreLens.ConnectionError.t()}
  defp validate_command_timeout(timeout) when is_integer(timeout) and timeout >= 0, do: :ok
  defp validate_command_timeout(timeout), do: invalid_command({:invalid_cdp_timeout, timeout})

  @spec validate_session_id(term()) :: :ok | {:error, SpectreLens.ConnectionError.t()}
  defp validate_session_id(session_id) when is_nil(session_id) or is_binary(session_id), do: :ok

  defp validate_session_id(session_id),
    do: invalid_command({:invalid_cdp_session_id, value_type(session_id)})

  @spec invalid_command(term()) :: {:error, SpectreLens.ConnectionError.t()}
  defp invalid_command(reason), do: {:error, SpectreLens.ConnectionError.new(reason)}

  @spec value_type(term()) :: atom()
  defp value_type(value) when is_atom(value), do: :atom
  defp value_type(value) when is_binary(value), do: :binary
  defp value_type(value) when is_function(value), do: :function
  defp value_type(value) when is_integer(value), do: :integer
  defp value_type(value) when is_list(value), do: :list
  defp value_type(value) when is_map(value), do: :map
  defp value_type(value) when is_pid(value), do: :pid
  defp value_type(value) when is_reference(value), do: :reference
  defp value_type(value) when is_tuple(value), do: :tuple
  defp value_type(_value), do: :other

  @doc """
  Registers a one-shot waiter for a CDP event.

  Pass `session_id` to wait only for an event emitted by one target.
  """
  @spec register_event_waiter(pid(), binary(), binary() | nil) :: event_waiter()
  def register_event_waiter(pid, method, session_id \\ nil) do
    ref = make_ref()
    WebSockex.cast(pid, {:wait_event, method, session_id, self(), ref})
    {pid, ref}
  end

  @doc "Waits for an event registered by `register_event_waiter/3`."
  @spec await_event(event_waiter() | reference(), non_neg_integer()) ::
          {:ok, map()} | {:error, Exception.t()}
  def await_event(waiter, timeout \\ 15_000)

  def await_event({pid, ref}, timeout)
      when is_pid(pid) and is_reference(ref) and is_integer(timeout) and timeout >= 0 do
    monitor = Process.monitor(pid)
    result = await_registered_event(pid, ref, monitor, timeout)
    Process.demonitor(monitor, [:flush])
    result
  end

  def await_event(ref, timeout)
      when is_reference(ref) and is_integer(timeout) and timeout >= 0 do
    receive do
      {:spectre_lens_cdp_event, ^ref, params} ->
        {:ok, params}

      {:spectre_lens_cdp_event_error, ^ref, reason} ->
        {:error, SpectreLens.ConnectionError.new(reason)}
    after
      timeout ->
        {:error, SpectreLens.TimeoutError.new(operation: :await_event, timeout_ms: timeout)}
    end
  end

  def await_event(_waiter, timeout) when not (is_integer(timeout) and timeout >= 0),
    do: invalid_command({:invalid_cdp_timeout, timeout})

  def await_event(waiter, _timeout),
    do: invalid_command({:invalid_cdp_event_waiter, value_type(waiter)})

  @spec await_registered_event(pid(), reference(), reference(), non_neg_integer()) ::
          {:ok, map()} | {:error, Exception.t()}
  defp await_registered_event(pid, ref, monitor, timeout) do
    receive do
      {:spectre_lens_cdp_event, ^ref, params} ->
        {:ok, params}

      {:spectre_lens_cdp_event_error, ^ref, reason} ->
        {:error, SpectreLens.ConnectionError.new(reason)}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, SpectreLens.ConnectionError.new({:connection_down, reason})}
    after
      timeout ->
        cancel_event_waiter({pid, ref})
        {:error, SpectreLens.TimeoutError.new(operation: :await_event, timeout_ms: timeout)}
    end
  end

  @doc "Cancels a one-shot CDP event waiter if it is still registered."
  @spec cancel_event_waiter(event_waiter()) :: :ok
  def cancel_event_waiter({pid, ref}) when is_pid(pid) and is_reference(ref) do
    WebSockex.cast(pid, {:cancel_event_waiter, self(), ref})
    :ok
  catch
    _, _ -> :ok
  end

  @doc "Registers and waits for a CDP event in one call."
  @spec wait_for_event(pid(), binary(), non_neg_integer(), binary() | nil) ::
          {:ok, map()} | {:error, Exception.t()}
  def wait_for_event(pid, method, timeout \\ 15_000, session_id \\ nil) do
    with :ok <- validate_command(pid, method, %{}, timeout, session_id) do
      pid
      |> register_event_waiter(method, session_id)
      |> await_event(timeout)
    end
  end

  @doc "Subscribes a process to every matching CDP event until it unsubscribes or exits."
  @spec subscribe_event(pid(), binary(), binary() | nil, pid()) :: :ok
  def subscribe_event(pid, method, session_id \\ nil, subscriber \\ self()) do
    WebSockex.cast(pid, {:subscribe_event, method, session_id, subscriber})
    :ok
  end

  @doc "Removes a persistent CDP event subscription."
  @spec unsubscribe_event(pid(), binary(), binary() | nil, pid()) :: :ok
  def unsubscribe_event(pid, method, session_id \\ nil, subscriber \\ self()) do
    WebSockex.cast(pid, {:unsubscribe_event, method, session_id, subscriber})
    :ok
  end

  @impl WebSockex
  def handle_cast({:send_command, method, params, session_id, from, ref}, state) do
    id = state.id

    payload =
      %{id: id, method: method, params: params}
      |> maybe_put(:sessionId, session_id)

    case Jason.encode(payload) do
      {:ok, message} ->
        monitor = Process.monitor(from)

        pending =
          Map.put(state.pending, id, %{from: from, ref: ref, method: method, monitor: monitor})

        pending_refs = Map.put(state.pending_refs, {from, ref}, id)
        monitors = Map.put(state.monitors, monitor, {:pending, id})

        {:reply, {:text, message},
         %{state | id: id + 1, pending: pending, pending_refs: pending_refs, monitors: monitors}}

      {:error, _reason} ->
        Telemetry.emit([:spectre_lens, :cdp, :encode_error], %{}, %{method: method})
        send(from, {:spectre_lens_cdp_error, ref, invalid_command_payload()})
        {:ok, state}
    end
  end

  def handle_cast({:cancel_command, from, ref}, state) do
    {:ok, cancel_pending(state, from, ref)}
  end

  @impl WebSockex
  def handle_cast({:wait_event, method, session_id, from, ref}, state) do
    key = {method, session_id}
    monitor = Process.monitor(from)
    waiter = %{from: from, ref: ref, monitor: monitor}
    event_waiters = Map.update(state.event_waiters, key, [waiter], &[waiter | &1])
    waiter_refs = Map.put(state.waiter_refs, {from, ref}, key)
    monitors = Map.put(state.monitors, monitor, {:waiter, key, from, ref})

    {:ok, %{state | event_waiters: event_waiters, waiter_refs: waiter_refs, monitors: monitors}}
  end

  def handle_cast({:cancel_event_waiter, from, ref}, state) do
    {:ok, cancel_waiter(state, from, ref)}
  end

  def handle_cast({:subscribe_event, method, session_id, subscriber}, state) do
    {:ok, add_subscriber(state, {method, session_id}, subscriber)}
  end

  def handle_cast({:unsubscribe_event, method, session_id, subscriber}, state) do
    {:ok, remove_subscriber(state, {method, session_id}, subscriber)}
  end

  def handle_cast(:close, state), do: {:close, state}

  @impl WebSockex
  def handle_frame({:text, data}, state) do
    case Jason.decode(data) do
      {:ok, %{"id" => id} = message} ->
        handle_response(id, message, state)

      {:ok, %{"method" => method} = message} ->
        session_id = Map.get(message, "sessionId")
        params = Map.get(message, "params", %{})
        handle_event(method, session_id, params, state)

      {:ok, _other} ->
        {:ok, state}

      {:error, reason} ->
        Telemetry.emit([:spectre_lens, :cdp, :decode_error], %{}, %{reason: reason})
        {:ok, state}
    end
  end

  @impl WebSockex
  def handle_frame(_frame, state), do: {:ok, state}

  @impl WebSockex
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    {:ok, drop_monitored_owner(state, monitor)}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl WebSockex
  def terminate(reason, state) do
    Enum.each(state.pending, fn {_id, pending} ->
      send(pending.from, {:spectre_lens_cdp_error, pending.ref, connection_closed(reason)})
    end)

    Enum.each(state.event_waiters, fn {_key, waiters} ->
      Enum.each(waiters, fn waiter ->
        send(waiter.from, {:spectre_lens_cdp_event_error, waiter.ref, reason})
      end)
    end)

    :ok
  end

  @spec initial_state() :: map()
  defp initial_state do
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

  @spec handle_response(integer(), map(), map()) :: {:ok, map()}
  defp handle_response(id, message, state) do
    case Map.pop(state.pending, id) do
      {%{from: from, ref: ref, monitor: monitor}, pending} ->
        if error = Map.get(message, "error") do
          send(from, {:spectre_lens_cdp_error, ref, error})
        else
          send(from, {:spectre_lens_cdp_response, ref, Map.get(message, "result", %{})})
        end

        state =
          state
          |> Map.put(:pending, pending)
          |> Map.update!(:pending_refs, &Map.delete(&1, {from, ref}))
          |> drop_monitor(monitor)

        {:ok, state}

      {nil, _pending} ->
        {:ok, state}
    end
  end

  @spec handle_event(binary(), binary() | nil, map(), map()) :: {:ok, map()}
  defp handle_event(method, session_id, params, state) do
    state = notify_subscribers(state, method, session_id, params)

    case pop_waiter(state, {method, session_id}, {method, nil}) do
      {:ok, waiter, state} ->
        send(waiter.from, {:spectre_lens_cdp_event, waiter.ref, params})
        {:ok, state}

      :none ->
        {:ok, state}
    end
  end

  @spec pop_waiter(map(), {binary(), binary() | nil}, {binary(), nil}) ::
          {:ok, map(), map()} | :none
  defp pop_waiter(state, exact_key, fallback_key) do
    case pop_one(state, exact_key) do
      :none when exact_key != fallback_key -> pop_one(state, fallback_key)
      other -> other
    end
  end

  @spec pop_one(map(), {binary(), binary() | nil}) :: {:ok, map(), map()} | :none
  defp pop_one(state, key) do
    case Map.get(state.event_waiters, key, []) do
      [] ->
        :none

      [waiter | rest] ->
        next_waiters =
          if rest == [] do
            Map.delete(state.event_waiters, key)
          else
            Map.put(state.event_waiters, key, rest)
          end

        state =
          state
          |> Map.put(:event_waiters, next_waiters)
          |> Map.update!(:waiter_refs, &Map.delete(&1, {waiter.from, waiter.ref}))
          |> drop_monitor(waiter.monitor)

        {:ok, waiter, state}
    end
  end

  @spec cancel_pending(map(), pid(), reference()) :: map()
  defp cancel_pending(state, from, ref) do
    case Map.pop(state.pending_refs, {from, ref}) do
      {nil, _pending_refs} ->
        state

      {id, pending_refs} ->
        case Map.pop(state.pending, id) do
          {nil, _pending} ->
            %{state | pending_refs: pending_refs}

          {%{monitor: monitor}, pending} ->
            state
            |> Map.put(:pending, pending)
            |> Map.put(:pending_refs, pending_refs)
            |> drop_monitor(monitor)
        end
    end
  end

  @spec cancel_waiter(map(), pid(), reference()) :: map()
  defp cancel_waiter(state, from, ref) do
    case Map.pop(state.waiter_refs, {from, ref}) do
      {nil, _waiter_refs} ->
        state

      {key, waiter_refs} ->
        {removed, remaining} =
          state.event_waiters
          |> Map.get(key, [])
          |> Enum.split_with(&(&1.from == from and &1.ref == ref))

        event_waiters = put_waiters(state.event_waiters, key, remaining)

        Enum.reduce(removed, %{state | event_waiters: event_waiters, waiter_refs: waiter_refs}, fn
          waiter, acc -> drop_monitor(acc, waiter.monitor)
        end)
    end
  end

  @spec add_subscriber(map(), {binary(), binary() | nil}, pid()) :: map()
  defp add_subscriber(state, key, subscriber) do
    subscribers = Map.get(state.subscribers, key, %{})

    if Map.has_key?(subscribers, subscriber) do
      state
    else
      monitor = Process.monitor(subscriber)

      %{
        state
        | subscribers: Map.put(state.subscribers, key, Map.put(subscribers, subscriber, monitor)),
          monitors: Map.put(state.monitors, monitor, {:subscriber, key, subscriber})
      }
    end
  end

  @spec remove_subscriber(map(), {binary(), binary() | nil}, pid()) :: map()
  defp remove_subscriber(state, key, subscriber) do
    case Map.get(state.subscribers, key, %{}) |> Map.pop(subscriber) do
      {nil, _subscribers} ->
        state

      {monitor, remaining} ->
        subscribers = put_subscribers(state.subscribers, key, remaining)
        state |> Map.put(:subscribers, subscribers) |> drop_monitor(monitor)
    end
  end

  @spec notify_subscribers(map(), binary(), binary() | nil, map()) :: map()
  defp notify_subscribers(state, method, session_id, params) do
    keys = Enum.uniq([{method, session_id}, {method, nil}])

    keys
    |> Enum.flat_map(&(state.subscribers |> Map.get(&1, %{}) |> Map.keys()))
    |> Enum.uniq()
    |> Enum.each(fn subscriber ->
      send(subscriber, {:spectre_lens_cdp_event, self(), method, session_id, params})
    end)

    state
  end

  @spec drop_monitored_owner(map(), reference()) :: map()
  defp drop_monitored_owner(state, monitor) do
    case Map.pop(state.monitors, monitor) do
      {nil, _monitors} ->
        state

      {{:pending, id}, monitors} ->
        case Map.pop(state.pending, id) do
          {nil, _pending} ->
            %{state | monitors: monitors}

          {%{from: from, ref: ref}, pending} ->
            %{
              state
              | pending: pending,
                pending_refs: Map.delete(state.pending_refs, {from, ref}),
                monitors: monitors
            }
        end

      {{:waiter, key, from, ref}, monitors} ->
        waiters =
          state.event_waiters
          |> Map.get(key, [])
          |> Enum.reject(&(&1.from == from and &1.ref == ref))

        %{
          state
          | event_waiters: put_waiters(state.event_waiters, key, waiters),
            waiter_refs: Map.delete(state.waiter_refs, {from, ref}),
            monitors: monitors
        }

      {{:subscriber, key, subscriber}, monitors} ->
        subscribers = state.subscribers |> Map.get(key, %{}) |> Map.delete(subscriber)

        %{
          state
          | subscribers: put_subscribers(state.subscribers, key, subscribers),
            monitors: monitors
        }
    end
  end

  @spec drop_monitor(map(), reference()) :: map()
  defp drop_monitor(state, monitor) do
    Process.demonitor(monitor, [:flush])
    %{state | monitors: Map.delete(state.monitors, monitor)}
  end

  @spec put_waiters(map(), {binary(), binary() | nil}, [map()]) :: map()
  defp put_waiters(waiters, key, []), do: Map.delete(waiters, key)
  defp put_waiters(waiters, key, values), do: Map.put(waiters, key, values)

  @spec put_subscribers(map(), {binary(), binary() | nil}, map()) :: map()
  defp put_subscribers(subscribers, key, values) when map_size(values) == 0,
    do: Map.delete(subscribers, key)

  defp put_subscribers(subscribers, key, values), do: Map.put(subscribers, key, values)

  @spec connection_closed(term()) :: map()
  defp connection_closed(reason) do
    %{"code" => -32_000, "message" => "CDP connection closed: #{inspect(reason)}"}
  end

  @spec invalid_command_payload() :: map()
  defp invalid_command_payload do
    %{"code" => -32_602, "message" => "CDP command parameters are not JSON encodable"}
  end

  @spec maybe_put(map(), atom(), nil | term()) :: map()
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
