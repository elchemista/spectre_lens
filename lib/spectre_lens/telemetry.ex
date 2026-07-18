defmodule SpectreLens.Telemetry do
  @moduledoc """
  Telemetry helpers for Spectre Lens.

  The library emits low-level protocol spans and higher-level agent actions,
  but it does not attach loggers or write logs itself. Consumers can subscribe
  to these events and decide how to route them.
  """

  @type event :: [atom()]
  @type measurements :: map()
  @type metadata :: map()
  @type span_fun(result) :: (-> result | {result, metadata()})

  @span_roots [
    [:spectre_lens, :cdp, :command],
    [:spectre_lens, :page, :navigate],
    [:spectre_lens, :page, :evaluate],
    [:spectre_lens, :page, :operation],
    [:spectre_lens, :runtime, :start],
    [:spectre_lens, :runtime, :new_tab],
    [:spectre_lens, :lightpanda, :install],
    [:spectre_lens, :lightpanda, :start_instance],
    [:spectre_lens, :agent, :llms]
  ]

  @point_events [
    [:spectre_lens, :cdp, :decode_error],
    [:spectre_lens, :page, :step],
    [:spectre_lens, :runtime, :tab_released],
    [:spectre_lens, :lightpanda, :download_fallback],
    [:spectre_lens, :lightpanda, :ready_timeout],
    [:spectre_lens, :network, :blocked],
    [:spectre_lens, :watcher, :initial],
    [:spectre_lens, :watcher, :changed],
    [:spectre_lens, :watcher, :error]
  ]

  @allowed_metadata_keys MapSet.new([
                           :action,
                           :adapter,
                           :error_kind,
                           :format,
                           :include,
                           :instance_id,
                           :instances,
                           :max_tabs_per_instance,
                           :method,
                           :node_id,
                           :operation,
                           :outcome,
                           :reason,
                           :region_count,
                           :runtime,
                           :session_id,
                           :source,
                           :target_id,
                           :url,
                           :watcher
                         ])

  @doc "Returns all Spectre Lens telemetry events, including span suffixes."
  @spec events() :: [event()]
  def events do
    span_events() ++ @point_events
  end

  @doc "Returns all span events emitted by Spectre Lens."
  @spec span_events() :: [event()]
  def span_events do
    Enum.flat_map(@span_roots, fn event ->
      [event ++ [:start], event ++ [:stop]]
    end)
  end

  @doc """
  Wraps a function in a telemetry span and converts raised/caught failures to errors.

  If the function returns `{result, metadata}`, the second element is merged
  into the stop metadata. Otherwise the original metadata is reused.
  """
  @spec span(event(), metadata(), span_fun(result)) ::
          result | {:error, SpectreLens.CaughtError.t()}
        when result: term()
  def span(event, metadata, fun)
      when is_list(event) and is_map(metadata) and is_function(fun, 0) do
    start_time = System.monotonic_time()
    emit(event ++ [:start], %{system_time: System.system_time()}, metadata)

    {result, stop_metadata} = run_span_fun(fun, metadata)
    duration = System.monotonic_time() - start_time
    emit(event ++ [:stop], %{duration: duration}, Map.merge(stop_metadata, outcome(result)))
    result
  end

  @doc "Emits a point-in-time Spectre Lens telemetry event."
  @spec emit(event(), measurements(), metadata()) :: :ok
  def emit(event, measurements \\ %{}, metadata \\ %{})
      when is_list(event) and is_map(measurements) and is_map(metadata) do
    :telemetry.execute(event, measurements, sanitize_metadata(metadata))
  end

  @spec run_span_fun(span_fun(result), metadata()) ::
          {result | {:error, SpectreLens.CaughtError.t()}, metadata()}
        when result: term()
  defp run_span_fun(fun, metadata) do
    case SpectreLens.Errors.safe(:telemetry_span, fun) do
      {result, extra_metadata} when is_tuple(result) and is_map(extra_metadata) ->
        {result, Map.merge(metadata, extra_metadata)}

      result ->
        {result, metadata}
    end
  end

  @spec sanitize_metadata(metadata()) :: metadata()
  defp sanitize_metadata(metadata) do
    Enum.reduce(metadata, %{}, fn {key, value}, acc ->
      if MapSet.member?(@allowed_metadata_keys, key) do
        Map.put(acc, key, sanitize_value(key, value))
      else
        acc
      end
    end)
  end

  @spec sanitize_value(atom(), term()) :: term()
  defp sanitize_value(:url, value), do: SpectreLens.URLPolicy.sanitize(value)
  defp sanitize_value(:reason, value), do: error_kind(value)

  defp sanitize_value(_key, value)
       when is_atom(value) or is_boolean(value) or is_integer(value) or is_nil(value),
       do: value

  defp sanitize_value(_key, value) when is_binary(value), do: String.slice(value, 0, 120)

  defp sanitize_value(_key, values) when is_list(values) do
    values
    |> Enum.take(20)
    |> Enum.map(fn
      value when is_atom(value) or is_integer(value) -> value
      _value -> :redacted
    end)
  end

  defp sanitize_value(_key, _value), do: :redacted

  @spec outcome(term()) :: map()
  defp outcome(:ok), do: %{outcome: :ok}
  defp outcome({:ok, _value}), do: %{outcome: :ok}
  defp outcome({:error, reason}), do: %{outcome: :error, error_kind: error_kind(reason)}
  defp outcome(_result), do: %{outcome: :ok}

  @spec error_kind(term()) :: atom()
  defp error_kind(%{__struct__: module}) when is_atom(module), do: module
  defp error_kind({kind, _rest}) when is_atom(kind), do: kind
  defp error_kind({kind, _left, _right}) when is_atom(kind), do: kind
  defp error_kind(kind) when is_atom(kind), do: kind
  defp error_kind(_reason), do: :unknown
end
