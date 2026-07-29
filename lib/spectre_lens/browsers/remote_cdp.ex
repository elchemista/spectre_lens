defmodule SpectreLens.Browsers.RemoteCDP do
  @moduledoc """
  Browser backend for an already-running CDP endpoint.

  The endpoint may belong to Lightpanda Cloud, Chrome, Chromium, or any other
  implementation compatible with the selected `SpectreLens.Protocol`.
  Closing Lens only closes its CDP connection; it never stops the remote
  browser service.
  """

  @behaviour SpectreLens.Browser

  alias SpectreLens.Browser.Instance
  alias SpectreLens.CDP.Connection

  @impl SpectreLens.Browser
  def default_protocol, do: SpectreLens.Protocol.CDP

  @impl SpectreLens.Browser
  def start_instance(index, opts) do
    with {:ok, endpoint} <- endpoint_for(index, opts),
         {:ok, protocol} <- SpectreLens.Browser.protocol(__MODULE__, opts),
         {:ok, connection} <- Connection.open(endpoint) do
      {:ok,
       %Instance{
         id: index,
         backend: __MODULE__,
         protocol: protocol,
         endpoint: endpoint,
         connection: connection,
         owner: :external,
         metadata: %{ownership: :external}
       }}
    end
  end

  @impl SpectreLens.Browser
  def stop_instance(%Instance{connection: connection}) do
    Connection.close(connection)
  end

  @impl SpectreLens.Browser
  def max_tabs(_instance, opts), do: Keyword.get(opts, :max_tabs_per_instance, 8)

  @impl SpectreLens.Browser
  def handle_info({:EXIT, connection, reason}, %Instance{connection: connection}),
    do: {:instance_down, {:connection_down, reason}}

  def handle_info(_message, _instance), do: :ignore

  @impl SpectreLens.Browser
  def doctor(opts) do
    case endpoint_for(1, opts) do
      {:ok, endpoint} ->
        case Connection.open(endpoint) do
          {:ok, connection} ->
            Connection.close(connection)

            %{
              backend: __MODULE__,
              available?: true,
              reachable?: true,
              endpoint: diagnostic_endpoint(endpoint)
            }

          {:error, reason} ->
            %{
              backend: __MODULE__,
              available?: false,
              reachable?: false,
              endpoint: diagnostic_endpoint(endpoint),
              error: diagnostic_error(reason)
            }
        end

      {:error, reason} ->
        %{
          backend: __MODULE__,
          available?: false,
          reachable?: false,
          error: diagnostic_error(reason)
        }
    end
  end

  @spec endpoint_for(pos_integer(), keyword()) :: {:ok, binary()} | {:error, term()}
  defp endpoint_for(index, opts) do
    endpoint =
      case Keyword.get(opts, :endpoints) do
        endpoints when is_list(endpoints) -> Enum.at(endpoints, index - 1)
        _other -> Keyword.get(opts, :endpoint)
      end

    if is_binary(endpoint) and endpoint != "" do
      {:ok, endpoint}
    else
      {:error, {:missing_browser_endpoint, index}}
    end
  end

  @spec diagnostic_endpoint(binary()) :: binary()
  defp diagnostic_endpoint(endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        URI.to_string(%URI{scheme: scheme, host: host, port: uri.port})

      _invalid ->
        "[redacted-endpoint]"
    end
  rescue
    _error -> "[redacted-endpoint]"
  end

  @spec diagnostic_error(Exception.t() | {atom(), term()}) :: module() | atom()
  defp diagnostic_error(%{__struct__: module}) when is_atom(module), do: module
  defp diagnostic_error({kind, _details}) when is_atom(kind), do: kind
end
