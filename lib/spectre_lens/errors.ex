defmodule SpectreLens.Errors do
  @moduledoc """
  Agent-readable error normalization.

  Browser automation errors often arrive as protocol details, exceptions, or
  tuples. This module keeps those shapes useful for agents by converting them
  into a compact map with retry guidance and a next-step hint.
  """

  @type agent_error :: %{
          type: atom(),
          message: binary(),
          retryable?: boolean(),
          hint: binary() | nil,
          operation: term() | nil,
          target: term() | nil,
          details: term()
        }

  @doc "Converts a Spectre Lens error, exception, or tuple into an agent-readable map."
  @spec to_agent(term()) :: agent_error()
  def to_agent({:error, reason}), do: to_agent(reason)

  def to_agent(%SpectreLens.CaughtError{} = error) do
    packet(
      :caught,
      error.message,
      retryable_caught?(error),
      "Spectre Lens caught an unexpected failure and returned it instead of raising.",
      error.operation,
      nil,
      %{kind: error.kind, reason: error.reason}
    )
  end

  def to_agent(%SpectreLens.ElementNotFoundError{} = error) do
    packet(
      :element_not_found,
      error.message,
      true,
      "Refresh the page map with zoom_out/2 or choose a selector/action ref from view.actions.",
      nil,
      error.ref,
      error
    )
  end

  def to_agent(%SpectreLens.TimeoutError{} = error) do
    packet(
      :timeout,
      error.message,
      true,
      "Increase the timeout or wait for a selector/navigation event before retrying.",
      error.operation,
      nil,
      error
    )
  end

  def to_agent(%SpectreLens.ConnectionError{} = error) do
    packet(
      :connection,
      error.message,
      true,
      "Check that Lightpanda is running and that the CDP endpoint is reachable.",
      :connect,
      nil,
      error.reason
    )
  end

  def to_agent(%SpectreLens.CDPError{} = error) do
    packet(
      :cdp,
      error.message,
      retryable_cdp?(error),
      cdp_hint(error),
      error.method,
      nil,
      %{code: error.code, method: error.method}
    )
  end

  def to_agent(%SpectreLens.JavaScriptError{} = error) do
    packet(
      :javascript,
      error.message,
      false,
      "Check the selector/expression. The page script threw while Spectre Lens evaluated it.",
      :evaluate,
      nil,
      error
    )
  end

  def to_agent(%SpectreLens.UnsupportedError{} = error) do
    packet(
      :unsupported,
      error.message,
      false,
      unsupported_hint(error),
      error.feature,
      nil,
      error.reason
    )
  end

  def to_agent(%{__exception__: true} = error) do
    packet(:exception, Exception.message(error), false, nil, nil, nil, error)
  end

  def to_agent({type, details}) when is_atom(type) do
    packet(type, "#{type}: #{inspect(details)}", false, generic_hint(type), nil, nil, details)
  end

  def to_agent(reason) do
    packet(:error, inspect(reason), false, nil, nil, nil, reason)
  end

  @doc "Returns true when an error is likely worth retrying."
  @spec retryable?(term()) :: boolean()
  def retryable?(reason), do: to_agent(reason).retryable?

  @doc "Returns the suggested next action for an error, when available."
  @spec hint(term()) :: binary() | nil
  def hint(reason), do: to_agent(reason).hint

  @doc "Runs a function and converts raise/throw/exit into `{:error, caught_error}`."
  @spec safe(term(), (-> result)) :: result | {:error, SpectreLens.CaughtError.t()}
        when result: term()
  def safe(operation, fun) when is_function(fun, 0) do
    fun.()
  rescue
    exception ->
      {:error, SpectreLens.CaughtError.new(:error, exception, __STACKTRACE__, operation)}
  catch
    kind, reason when kind in [:throw, :exit] ->
      {:error, SpectreLens.CaughtError.new(kind, reason, __STACKTRACE__, operation)}
  end

  @spec packet(atom(), binary(), boolean(), binary() | nil, term(), term(), term()) ::
          agent_error()
  defp packet(type, message, retryable?, hint, operation, target, details) do
    %{
      type: type,
      message: message,
      retryable?: retryable?,
      hint: hint,
      operation: operation,
      target: target,
      details: details
    }
  end

  @spec retryable_cdp?(SpectreLens.CDPError.t()) :: boolean()
  defp retryable_cdp?(%SpectreLens.CDPError{code: code}) when code in [-32_000, -32_001],
    do: true

  defp retryable_cdp?(_error), do: false

  @spec retryable_caught?(SpectreLens.CaughtError.t()) :: boolean()
  defp retryable_caught?(%SpectreLens.CaughtError{kind: :exit}), do: true
  defp retryable_caught?(_error), do: false

  @spec cdp_hint(SpectreLens.CDPError.t()) :: binary()
  defp cdp_hint(%SpectreLens.CDPError{method: method}) when method in ["DOM.querySelector"] do
    "The selector may not exist yet. Try wait_for_selector/3 or zoom_out/2 before acting."
  end

  defp cdp_hint(_error) do
    "Inspect the method and parameters. This browser may not support the requested command shape."
  end

  @spec unsupported_hint(SpectreLens.UnsupportedError.t()) :: binary()
  defp unsupported_hint(%SpectreLens.UnsupportedError{feature: :pdf}) do
    "This browser did not provide Page.printToPDF. Export HTML or screenshot instead."
  end

  defp unsupported_hint(%SpectreLens.UnsupportedError{feature: feature}) do
    "The active browser driver does not support #{feature}. Use a different driver or fallback export."
  end

  @spec generic_hint(atom()) :: binary() | nil
  defp generic_hint(:tab_capacity_exceeded) do
    "Close unused tabs or start SpectreLens.open/1 with more instances or a larger max_tabs_per_instance."
  end

  defp generic_hint(:unknown_action) do
    "Use one of the supported actions: navigate, click, fill, submit, or scroll."
  end

  defp generic_hint(:unknown_export) do
    "Use one of the supported exports: screenshot, html, markdown, or pdf."
  end

  defp generic_hint(:llms_txt_not_found) do
    "The site did not expose llms.txt at the discovered locations. Pass a direct /llms.txt URL if it lives elsewhere."
  end

  defp generic_hint(_type), do: nil
end
