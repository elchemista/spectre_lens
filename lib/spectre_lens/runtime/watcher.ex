defmodule SpectreLens.Watcher do
  @moduledoc """
  Polling watcher that emits page-change messages to a process.

  Messages:

      {:spectre_lens_watch, watcher_pid, :initial, view}
      {:spectre_lens_watch, watcher_pid, :changed, view}
      {:spectre_lens_watch, watcher_pid, :error, reason}
  """

  @stop_timeout 30_000

  defstruct [:pid, :ref, :tab, :include, :notify]

  @type t :: %__MODULE__{
          pid: pid(),
          ref: reference(),
          tab: SpectreLens.Tab.t(),
          include: [atom()],
          notify: pid()
        }

  @doc "Starts watching a tab and sends change messages to `:notify`."
  @spec start(SpectreLens.Tab.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def start(tab, opts \\ []) do
    notify = opts[:notify] || self()
    include = opts[:include] || [:markdown, :interactive]
    every = opts[:every] || 2_000
    ref = make_ref()

    with :ok <- validate_notify(notify),
         :ok <- validate_include(include),
         :ok <- validate_interval(every),
         {:ok, pid} <-
           Task.start(fn ->
             notify_monitor = Process.monitor(notify)
             loop(tab, notify, notify_monitor, ref, include, every, nil)
           end) do
      {:ok, %__MODULE__{pid: pid, ref: ref, tab: tab, include: include, notify: notify}}
    end
  end

  @doc "Stops a watcher process."
  @spec stop(t()) :: :ok | {:error, :watcher_stop_timeout}
  def stop(%__MODULE__{pid: pid, ref: ref}) do
    if Process.alive?(pid) do
      monitor = Process.monitor(pid)
      send(pid, {:spectre_lens_stop, ref})

      receive do
        {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
      after
        @stop_timeout ->
          Process.demonitor(monitor, [:flush])
          {:error, :watcher_stop_timeout}
      end
    else
      :ok
    end
  catch
    _, _ -> :ok
  end

  @spec loop(
          SpectreLens.Tab.t(),
          pid(),
          reference(),
          reference(),
          [atom()],
          pos_integer(),
          binary() | nil
        ) :: :ok
  defp loop(tab, notify, notify_monitor, ref, include, every, previous_hash) do
    receive do
      {:spectre_lens_stop, ^ref} -> :ok
      {:DOWN, ^notify_monitor, :process, ^notify, _reason} -> :ok
    after
      0 -> poll(tab, notify, notify_monitor, ref, include, every, previous_hash)
    end
  end

  @spec poll(
          SpectreLens.Tab.t(),
          pid(),
          reference(),
          reference(),
          [atom()],
          pos_integer(),
          binary() | nil
        ) :: :ok
  defp poll(tab, notify, notify_monitor, ref, include, every, previous_hash) do
    next_hash = poll_view(tab, notify, include, previous_hash)

    receive do
      {:spectre_lens_stop, ^ref} -> :ok
      {:DOWN, ^notify_monitor, :process, ^notify, _reason} -> :ok
    after
      every -> loop(tab, notify, notify_monitor, ref, include, every, next_hash)
    end
  end

  @spec poll_view(SpectreLens.Tab.t(), pid(), [atom()], binary() | nil) :: binary() | nil
  defp poll_view(tab, notify, include, previous_hash) do
    case SpectreLens.look(tab, include: include) do
      {:ok, view} ->
        hash = view_hash(view)
        notify_view(notify, include, previous_hash, hash, view)
        hash

      {:error, reason} ->
        SpectreLens.Telemetry.emit([:spectre_lens, :watcher, :error], %{}, %{
          watcher: inspect(self()),
          include: include,
          result: {:error, reason}
        })

        send(notify, {:spectre_lens_watch, self(), :error, reason})
        previous_hash
    end
  end

  @spec notify_view(pid(), [atom()], binary() | nil, binary(), SpectreLens.View.t()) :: :ok
  defp notify_view(notify, include, previous_hash, hash, view) do
    event = if is_nil(previous_hash), do: :initial, else: :changed

    if is_nil(previous_hash) or hash != previous_hash do
      SpectreLens.Telemetry.emit([:spectre_lens, :watcher, event], %{}, %{
        watcher: inspect(self()),
        include: include
      })

      send(notify, {:spectre_lens_watch, self(), event, view})
    end

    :ok
  end

  @spec validate_notify(term()) :: :ok | {:error, term()}
  defp validate_notify(notify) when is_pid(notify) do
    if Process.alive?(notify),
      do: :ok,
      else: {:error, {:watcher_notify_unavailable, notify}}
  end

  defp validate_notify(notify), do: {:error, {:invalid_watcher_notify, notify}}

  @spec validate_include(term()) :: :ok | {:error, term()}
  defp validate_include(include) when is_list(include) do
    if Enum.all?(include, &is_atom/1),
      do: :ok,
      else: {:error, {:invalid_watcher_include, include}}
  end

  defp validate_include(include), do: {:error, {:invalid_watcher_include, include}}

  @spec validate_interval(term()) :: :ok | {:error, term()}
  defp validate_interval(every) when is_integer(every) and every > 0, do: :ok
  defp validate_interval(every), do: {:error, {:invalid_watcher_interval, every}}

  @spec view_hash(SpectreLens.View.t()) :: binary()
  defp view_hash(view) do
    view
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
