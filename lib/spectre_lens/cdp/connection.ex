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

  @doc """
  Opens a CDP WebSocket connection.

  `endpoint` may be the HTTP server base URL (`http://127.0.0.1:9222`) or a
  direct WebSocket URL.
  """
  @spec open(endpoint()) :: {:ok, pid()} | {:error, Exception.t()}
  def open("ws://" <> _ = ws_url), do: WebSockex.start_link(ws_url, __MODULE__, initial_state())
  def open("wss://" <> _ = ws_url), do: WebSockex.start_link(ws_url, __MODULE__, initial_state())

  def open(endpoint) when is_binary(endpoint) do
    version_url = String.trim_trailing(endpoint, "/") <> "/json/version"

    case Req.get(version_url, retry: false) do
      {:ok, %{status: status, body: %{"webSocketDebuggerUrl" => ws_url}}}
      when status in 200..299 ->
        open(ws_url)

      {:ok, %{status: status, body: body}} ->
        {:error, SpectreLens.ConnectionError.new({:unexpected_version_response, status, body})}

      {:error, reason} ->
        {:error, SpectreLens.ConnectionError.new(reason)}
    end
  end

  @doc "Closes a CDP connection process."
  @spec close(pid()) :: :ok
  def close(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      Process.unlink(pid)
      Process.exit(pid, :normal)
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
      ref = make_ref()
      WebSockex.cast(pid, {:send_command, method, params, session_id, self(), ref})

      result =
        receive do
          {:spectre_lens_cdp_response, ^ref, result} ->
            {:ok, result}

          {:spectre_lens_cdp_error, ^ref, %{"code" => code, "message" => message}} ->
            {:error, SpectreLens.CDPError.new(code, message, method)}

          {:spectre_lens_cdp_error, ^ref, error} ->
            {:error, SpectreLens.CDPError.new(0, inspect(error), method)}
        after
          timeout ->
            {:error, SpectreLens.TimeoutError.new(operation: method, timeout_ms: timeout)}
        end

      {result, %{result: result}}
    end)
  end

  @doc """
  Registers a one-shot waiter for a CDP event.

  Pass `session_id` to wait only for an event emitted by one target.
  """
  @spec register_event_waiter(pid(), binary(), binary() | nil) :: reference()
  def register_event_waiter(pid, method, session_id \\ nil) do
    ref = make_ref()
    WebSockex.cast(pid, {:wait_event, method, session_id, self(), ref})
    ref
  end

  @doc "Waits for an event registered by `register_event_waiter/3`."
  @spec await_event(reference(), non_neg_integer()) :: {:ok, map()} | {:error, Exception.t()}
  def await_event(ref, timeout \\ 15_000) do
    receive do
      {:spectre_lens_cdp_event, ^ref, params} ->
        {:ok, params}
    after
      timeout ->
        {:error, SpectreLens.TimeoutError.new(operation: :await_event, timeout_ms: timeout)}
    end
  end

  @doc "Registers and waits for a CDP event in one call."
  @spec wait_for_event(pid(), binary(), non_neg_integer(), binary() | nil) ::
          {:ok, map()} | {:error, Exception.t()}
  def wait_for_event(pid, method, timeout \\ 15_000, session_id \\ nil) do
    pid
    |> register_event_waiter(method, session_id)
    |> await_event(timeout)
  end

  @impl true
  def handle_cast({:send_command, method, params, session_id, from, ref}, state) do
    id = state.id

    message =
      %{id: id, method: method, params: params}
      |> maybe_put(:sessionId, session_id)
      |> Jason.encode!()

    pending = Map.put(state.pending, id, {from, ref, method})
    {:reply, {:text, message}, %{state | id: id + 1, pending: pending}}
  end

  @impl true
  def handle_cast({:wait_event, method, session_id, from, ref}, state) do
    key = {method, session_id}
    event_waiters = Map.update(state.event_waiters, key, [{from, ref}], &[{from, ref} | &1])
    {:ok, %{state | event_waiters: event_waiters}}
  end

  @impl true
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

  @impl true
  def handle_frame(_frame, state), do: {:ok, state}

  @spec initial_state() :: map()
  defp initial_state do
    %{id: 1, pending: %{}, event_waiters: %{}}
  end

  @spec handle_response(integer(), map(), map()) :: {:ok, map()}
  defp handle_response(id, message, state) do
    case Map.pop(state.pending, id) do
      {{from, ref, _method}, pending} ->
        if error = Map.get(message, "error") do
          send(from, {:spectre_lens_cdp_error, ref, error})
        else
          send(from, {:spectre_lens_cdp_response, ref, Map.get(message, "result", %{})})
        end

        {:ok, %{state | pending: pending}}

      {nil, _pending} ->
        {:ok, state}
    end
  end

  @spec handle_event(binary(), binary() | nil, map(), map()) :: {:ok, map()}
  defp handle_event(method, session_id, params, state) do
    case pop_waiter(state.event_waiters, {method, session_id}, {method, nil}) do
      {{from, ref}, event_waiters} ->
        send(from, {:spectre_lens_cdp_event, ref, params})
        {:ok, %{state | event_waiters: event_waiters}}

      {nil, _event_waiters} ->
        {:ok, state}
    end
  end

  @spec pop_waiter(map(), {binary(), binary() | nil}, {binary(), nil}) :: {term() | nil, map()}
  defp pop_waiter(waiters, exact_key, fallback_key) do
    case pop_one(waiters, exact_key) do
      {nil, ^waiters} -> pop_one(waiters, fallback_key)
      other -> other
    end
  end

  @spec pop_one(map(), {binary(), binary() | nil}) :: {term() | nil, map()}
  defp pop_one(waiters, key) do
    case Map.get(waiters, key, []) do
      [] ->
        {nil, waiters}

      [waiter | rest] ->
        next_waiters =
          if rest == [] do
            Map.delete(waiters, key)
          else
            Map.put(waiters, key, rest)
          end

        {waiter, next_waiters}
    end
  end

  @spec maybe_put(map(), atom(), nil | term()) :: map()
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
