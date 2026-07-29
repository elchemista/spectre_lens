defmodule SpectreLens.Browser do
  @moduledoc """
  Runtime backend contract for browser engines used by Spectre Lens.

  A backend owns the live browser resource: it may spawn a local process,
  connect to a remote service, or allocate an in-memory test implementation.
  It does not implement page operations; those belong to
  `SpectreLens.Protocol`.

  This separation keeps `SpectreLens.Runtime` independent from Lightpanda and
  lets a Stack declaration such as `backend MyApp.Playwright` select a real
  runtime adapter rather than a page driver.
  """

  alias SpectreLens.Browser.Instance

  @type result(value) :: {:ok, value} | {:error, term()}

  @callback start_instance(pos_integer(), keyword()) :: result(Instance.t())
  @callback stop_instance(Instance.t()) :: :ok | {:error, term()}
  @callback default_protocol() :: module()
  @callback max_tabs(Instance.t(), keyword()) :: pos_integer()
  @callback handle_info(term(), Instance.t()) ::
              :ignore | {:ok, Instance.t()} | {:instance_down, term()}
  @callback doctor(keyword()) :: map()

  @optional_callbacks handle_info: 2, doctor: 1

  @required_callbacks [
    start_instance: 2,
    stop_instance: 1,
    default_protocol: 0,
    max_tabs: 2
  ]

  @doc "Returns the configured backend, defaulting to local Lightpanda."
  @spec resolve(keyword()) :: module()
  def resolve(opts) when is_list(opts) do
    Keyword.get(opts, :backend, SpectreLens.Browsers.Lightpanda)
  end

  @doc "Validates that a module implements the runtime backend contract."
  @spec validate(module()) :: :ok | {:error, term()}
  def validate(module) when is_atom(module) and not is_nil(module) do
    if Code.ensure_loaded?(module) do
      missing =
        Enum.reject(@required_callbacks, fn {name, arity} ->
          function_exported?(module, name, arity)
        end)

      case missing do
        [] -> :ok
        callbacks -> {:error, {:invalid_browser_backend, module, callbacks}}
      end
    else
      {:error, {:browser_backend_unavailable, module}}
    end
  end

  def validate(module), do: {:error, {:invalid_browser_backend, module}}

  @doc "Resolves and validates the page protocol selected for a backend."
  @spec protocol(module(), keyword()) :: {:ok, module()} | {:error, term()}
  def protocol(backend, opts) do
    protocol = Keyword.get_lazy(opts, :protocol, &backend.default_protocol/0)

    with :ok <- SpectreLens.Protocol.validate(protocol) do
      {:ok, protocol}
    end
  end

  @doc false
  @spec start_instance(module(), pos_integer(), keyword()) :: result(Instance.t())
  def start_instance(backend, index, opts) do
    case backend.start_instance(index, opts) do
      {:ok, %Instance{} = instance} ->
        case normalize_instance(instance, backend, index, opts) do
          {:ok, normalized} ->
            {:ok, normalized}

          {:error, _reason} = error ->
            stop_started_instance(backend, instance)
            error
        end

      {:ok, invalid} ->
        {:error, {:invalid_browser_instance, invalid}}

      {:error, _reason} = error ->
        error

      invalid ->
        {:error, {:invalid_browser_start_result, backend, invalid}}
    end
  rescue
    error -> {:error, {:browser_backend_start_failed, backend, error}}
  catch
    kind, reason -> {:error, {:browser_backend_start_failed, backend, {kind, reason}}}
  end

  @doc false
  @spec stop_instance(Instance.t()) :: :ok
  def stop_instance(%Instance{backend: backend} = instance) do
    case backend.stop_instance(instance) do
      :ok -> :ok
      {:error, _reason} -> :ok
      _other -> :ok
    end
  catch
    _, _ -> :ok
  end

  @doc false
  @spec subscribe(Instance.t(), pid()) :: :ok | {:error, term()}
  def subscribe(%Instance{protocol: protocol} = instance, subscriber) do
    result =
      if function_exported?(protocol, :subscribe, 2) do
        protocol.subscribe(instance, subscriber)
      else
        :ok
      end

    case result do
      :ok -> :ok
      {:error, _reason} = error -> error
      invalid -> {:error, {:invalid_browser_subscription_result, protocol, invalid}}
    end
  rescue
    error -> {:error, {:browser_subscription_failed, protocol, error}}
  catch
    kind, reason -> {:error, {:browser_subscription_failed, protocol, {kind, reason}}}
  end

  @doc false
  @spec handle_info(term(), Instance.t()) ::
          :ignore
          | {:ok, Instance.t()}
          | {:tab_closed, term()}
          | {:instance_down, term()}
  def handle_info(message, %Instance{} = instance) do
    with :ignore <- backend_info(message, instance) do
      protocol_info(message, instance)
    end
  rescue
    error -> {:instance_down, {:browser_event_failed, error}}
  catch
    kind, reason -> {:instance_down, {:browser_event_failed, {kind, reason}}}
  end

  @doc "Returns backend diagnostics without starting a browser."
  @spec doctor(module(), keyword()) :: map()
  def doctor(backend, opts) do
    if function_exported?(backend, :doctor, 1) do
      backend.doctor(opts)
    else
      %{backend: backend, available?: true}
    end
  end

  @spec normalize_instance(Instance.t(), module(), pos_integer(), keyword()) ::
          result(Instance.t())
  defp normalize_instance(instance, backend, index, opts) do
    with :ok <- validate_instance(instance, backend, index, opts),
         :ok <- SpectreLens.Protocol.validate(instance.protocol),
         max_tabs <- backend.max_tabs(instance, opts),
         :ok <- validate_capacity(max_tabs, backend) do
      {:ok, %{instance | max_tabs: max_tabs}}
    end
  rescue
    error -> {:error, {:browser_backend_capacity_failed, backend, error}}
  catch
    kind, reason -> {:error, {:browser_backend_capacity_failed, backend, {kind, reason}}}
  end

  @spec validate_instance(Instance.t(), module(), pos_integer(), keyword()) ::
          :ok | {:error, term()}
  defp validate_instance(
         %Instance{id: index, backend: backend, protocol: protocol},
         backend,
         index,
         opts
       )
       when is_atom(protocol) and not is_nil(protocol) do
    expected_protocol = Keyword.get_lazy(opts, :protocol, &backend.default_protocol/0)

    if protocol == expected_protocol do
      :ok
    else
      {:error, {:browser_protocol_mismatch, backend, expected_protocol, protocol}}
    end
  end

  defp validate_instance(instance, backend, index, _opts),
    do: {:error, {:invalid_browser_instance, backend, index, instance}}

  @spec validate_capacity(term(), module()) :: :ok | {:error, term()}
  defp validate_capacity(capacity, _backend) when is_integer(capacity) and capacity > 0, do: :ok

  defp validate_capacity(capacity, backend),
    do: {:error, {:invalid_browser_capacity, backend, capacity}}

  @spec stop_started_instance(module(), Instance.t()) :: :ok
  defp stop_started_instance(backend, instance) do
    case backend.stop_instance(instance) do
      _result -> :ok
    end
  rescue
    _error -> :ok
  catch
    _, _ -> :ok
  end

  @spec backend_info(term(), Instance.t()) ::
          :ignore | {:ok, Instance.t()} | {:instance_down, term()}
  defp backend_info(message, %Instance{backend: backend} = instance) do
    if function_exported?(backend, :handle_info, 2) do
      backend.handle_info(message, instance)
    else
      :ignore
    end
  end

  @spec protocol_info(term(), Instance.t()) ::
          :ignore | {:ok, Instance.t()} | {:tab_closed, term()} | {:instance_down, term()}
  defp protocol_info(message, %Instance{protocol: protocol} = instance) do
    if function_exported?(protocol, :handle_info, 2) do
      protocol.handle_info(message, instance)
    else
      :ignore
    end
  end
end
