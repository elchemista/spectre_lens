defmodule SpectreLens.Watcher do
  @moduledoc """
  Polling watcher that emits page-change messages to a process.

  Messages:

      {:spectre_lens_watch, watcher_pid, :initial, view}
      {:spectre_lens_watch, watcher_pid, :changed, view}
      {:spectre_lens_watch, watcher_pid, :error, reason}
  """

  defstruct [:pid, :ref, :tab, :include, :notify]

  @type t :: %__MODULE__{
          pid: pid(),
          ref: reference(),
          tab: SpectreLens.Tab.t(),
          include: [atom()],
          notify: pid()
        }

  @doc "Starts watching a tab and sends change messages to `:notify`."
  @spec start(SpectreLens.Tab.t(), keyword()) :: {:ok, t()}
  def start(tab, opts \\ []) do
    notify = opts[:notify] || self()
    include = opts[:include] || [:markdown, :interactive]
    every = opts[:every] || 2_000
    ref = make_ref()

    {:ok, pid} =
      Task.start_link(fn ->
        loop(tab, notify, ref, include, every, nil)
      end)

    {:ok, %__MODULE__{pid: pid, ref: ref, tab: tab, include: include, notify: notify}}
  end

  @doc "Stops a watcher process."
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{pid: pid}) do
    if Process.alive?(pid), do: Process.exit(pid, :normal)
    :ok
  catch
    _, _ -> :ok
  end

  @spec loop(SpectreLens.Tab.t(), pid(), reference(), [atom()], pos_integer(), binary() | nil) ::
          :ok
  defp loop(tab, notify, ref, include, every, previous_hash) do
    next_hash =
      case SpectreLens.look(tab, include: include) do
        {:ok, view} ->
          hash = view_hash(view)

          cond do
            is_nil(previous_hash) ->
              SpectreLens.Telemetry.emit([:spectre_lens, :watcher, :initial], %{}, %{
                watcher: inspect(self()),
                include: include
              })

              send(notify, {:spectre_lens_watch, self(), :initial, view})

            hash != previous_hash ->
              SpectreLens.Telemetry.emit([:spectre_lens, :watcher, :changed], %{}, %{
                watcher: inspect(self()),
                include: include
              })

              send(notify, {:spectre_lens_watch, self(), :changed, view})

            true ->
              :ok
          end

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

    receive do
      {:spectre_lens_stop, ^ref} -> :ok
    after
      every -> loop(tab, notify, ref, include, every, next_hash)
    end
  end

  @spec view_hash(SpectreLens.View.t()) :: binary()
  defp view_hash(view) do
    view
    |> Map.from_struct()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
