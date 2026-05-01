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
    [:spectre_lens, :watcher, :initial],
    [:spectre_lens, :watcher, :changed],
    [:spectre_lens, :watcher, :error]
  ]

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
    emit(event ++ [:stop], %{duration: duration}, Map.put(stop_metadata, :result, result))
    result
  end

  @doc "Emits a point-in-time Spectre Lens telemetry event."
  @spec emit(event(), measurements(), metadata()) :: :ok
  def emit(event, measurements \\ %{}, metadata \\ %{})
      when is_list(event) and is_map(measurements) and is_map(metadata) do
    :telemetry.execute(event, measurements, metadata)
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
end
