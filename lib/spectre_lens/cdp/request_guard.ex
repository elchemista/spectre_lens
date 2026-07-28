defmodule SpectreLens.CDP.RequestGuard do
  @moduledoc false

  use GenServer

  alias SpectreLens.CDP.Connection
  alias SpectreLens.{Tab, Telemetry, URLPolicy}

  @command_timeout 5_000

  @spec start(Tab.t(), keyword()) :: {:ok, pid() | nil} | {:error, term()}
  def start(%Tab{} = tab, opts \\ []) do
    policy_opts = URLPolicy.merge_options(tab.url_policy, opts)

    case Keyword.get(policy_opts, :network_policy, :public) do
      :any -> {:ok, nil}
      :public -> GenServer.start(__MODULE__, {tab, policy_opts})
      other -> {:error, {:invalid_network_policy, other}}
    end
  end

  @spec stop(pid() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, @command_timeout)
    :ok
  catch
    :exit, _ -> :ok
  end

  @doc false
  @spec target_closed(pid() | nil) :: :ok
  def target_closed(nil), do: :ok

  def target_closed(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.cast(pid, :target_closed)
    :ok
  catch
    _, _ -> :ok
  end

  @impl GenServer
  def init({%Tab{conn: conn, session_id: session_id}, policy_opts}) do
    monitor = Process.monitor(conn)
    :ok = Connection.subscribe_event(conn, "Fetch.requestPaused", session_id, self())

    case Connection.send_command(
           conn,
           "Fetch.enable",
           %{"patterns" => [%{"urlPattern" => "*"}]},
           @command_timeout,
           session_id
         ) do
      {:ok, _} ->
        {:ok, %{conn: conn, session_id: session_id, policy_opts: policy_opts, monitor: monitor}}

      {:error, reason} ->
        Connection.unsubscribe_event(conn, "Fetch.requestPaused", session_id, self())
        Process.demonitor(monitor, [:flush])
        {:stop, {:request_guard_unavailable, reason}}
    end
  end

  @impl GenServer
  def handle_info(
        {:spectre_lens_cdp_event, "Fetch.requestPaused", session_id, params},
        %{session_id: session_id} = state
      ) do
    handle_paused_request(params, state)
    {:noreply, state}
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, %{monitor: monitor} = state) do
    {:stop, {:connection_down, reason}, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def handle_cast(:target_closed, state) do
    {:stop, :normal, Map.put(state, :target_closed?, true)}
  end

  @impl GenServer
  def terminate(_reason, state) do
    if Process.alive?(state.conn) do
      Connection.unsubscribe_event(
        state.conn,
        "Fetch.requestPaused",
        state.session_id,
        self()
      )

      unless Map.get(state, :target_closed?, false) do
        Connection.send_command(
          state.conn,
          "Fetch.disable",
          %{},
          @command_timeout,
          state.session_id
        )
      end
    end

    :ok
  catch
    _, _ -> :ok
  end

  @spec handle_paused_request(map(), map()) :: :ok
  defp handle_paused_request(params, state) do
    request_id = Map.get(params, "requestId")
    url = get_in(params, ["request", "url"])

    case {request_id, url} do
      {request_id, url} when is_binary(request_id) and is_binary(url) ->
        decide_request(request_id, url, state)

      _ ->
        :ok
    end
  end

  @spec decide_request(binary(), binary(), map()) :: :ok
  defp decide_request(request_id, url, state) do
    case URLPolicy.validate_request(url, state.policy_opts) do
      {:ok, _url} ->
        continue_request(request_id, state)

      {:error, reason} ->
        Telemetry.emit([:spectre_lens, :network, :blocked], %{}, %{
          url: URLPolicy.sanitize(url),
          reason: safe_reason(reason),
          session_id: state.session_id
        })

        fail_request(request_id, state)
    end
  end

  @spec continue_request(binary(), map()) :: :ok
  defp continue_request(request_id, state) do
    send_decision(state, "Fetch.continueRequest", %{"requestId" => request_id})
  end

  @spec fail_request(binary(), map()) :: :ok
  defp fail_request(request_id, state) do
    send_decision(state, "Fetch.failRequest", %{
      "requestId" => request_id,
      "errorReason" => "BlockedByClient"
    })
  end

  @spec send_decision(map(), binary(), map()) :: :ok
  defp send_decision(state, method, params) do
    Connection.send_command(
      state.conn,
      method,
      params,
      @command_timeout,
      state.session_id
    )

    :ok
  end

  @spec safe_reason({atom(), term()} | {atom(), term(), term()}) :: atom()
  defp safe_reason({:address_not_allowed, _host, _address}), do: :address_not_allowed
  defp safe_reason({kind, _value}) when is_atom(kind), do: kind
end
