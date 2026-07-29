defmodule SpectreLens.Browsers.Lightpanda do
  @moduledoc """
  Local Lightpanda runtime backend.

  This adapter is the only place where the generic Lens runtime knows how to
  provision a Lightpanda process. Page semantics are supplied separately by
  `SpectreLens.Protocol.Lightpanda`.
  """

  @behaviour SpectreLens.Browser

  alias SpectreLens.Browser.Instance
  alias SpectreLens.CDP.Connection

  @impl SpectreLens.Browser
  def default_protocol, do: SpectreLens.Protocol.Lightpanda

  @impl SpectreLens.Browser
  def start_instance(index, opts) do
    with {:ok, protocol} <- SpectreLens.Browser.protocol(__MODULE__, opts),
         {:ok, lightpanda} <- SpectreLens.Lightpanda.start_instance(Keyword.put(opts, :id, index)) do
      open_instance(index, protocol, lightpanda)
    end
  end

  @impl SpectreLens.Browser
  def stop_instance(%Instance{connection: connection, owner: lightpanda}) do
    Connection.close(connection)
    SpectreLens.Lightpanda.stop_instance(lightpanda)
  end

  @impl SpectreLens.Browser
  def max_tabs(_instance, _opts), do: 1

  @impl SpectreLens.Browser
  def handle_info(
        {:DOWN, os_pid, :process, process_pid, reason},
        %Instance{owner: %{process: {process_pid, os_pid}}}
      ),
      do: {:instance_down, {:lightpanda_down, reason}}

  def handle_info({stream, os_pid, _data}, %Instance{owner: %{process: {_pid, os_pid}}})
      when stream in [:stdout, :stderr],
      do: :ignore

  def handle_info(_message, _instance), do: :ignore

  @impl SpectreLens.Browser
  def doctor(opts), do: Map.put(SpectreLens.Lightpanda.doctor(opts), :backend, __MODULE__)

  @spec open_instance(pos_integer(), module(), map()) ::
          {:ok, Instance.t()} | {:error, term()}
  defp open_instance(index, protocol, lightpanda) do
    case Connection.open(lightpanda.endpoint) do
      {:ok, connection} ->
        {:ok,
         %Instance{
           id: index,
           backend: __MODULE__,
           protocol: protocol,
           endpoint: lightpanda.endpoint,
           connection: connection,
           owner: lightpanda,
           metadata: %{
             ownership: :local,
             binary: lightpanda.binary,
             version: lightpanda.version
           }
         }}

      {:error, reason} ->
        SpectreLens.Lightpanda.stop_instance(lightpanda)
        {:error, reason}
    end
  end
end
