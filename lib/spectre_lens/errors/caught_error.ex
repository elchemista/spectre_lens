defmodule SpectreLens.CaughtError do
  @moduledoc "Returned when Spectre Lens catches a raised, thrown, or exited failure."

  defexception [:kind, :reason, :operation, :stacktrace, :message]

  @type t :: %__MODULE__{
          kind: :error | :exit | :throw,
          reason: term(),
          operation: term(),
          stacktrace: Exception.stacktrace(),
          message: binary()
        }

  @doc "Builds a caught error with operation context."
  @spec new(:error | :exit | :throw, term(), Exception.stacktrace(), term()) :: t()
  def new(kind, reason, stacktrace, operation \\ nil) do
    %__MODULE__{
      kind: kind,
      reason: reason,
      operation: operation,
      stacktrace: stacktrace,
      message: message(kind, reason, operation)
    }
  end

  @spec message(:error | :exit | :throw, term(), term()) :: binary()
  defp message(kind, reason, operation) do
    prefix = if operation, do: "#{operation} failed", else: "operation failed"
    "#{prefix}: caught #{kind} #{inspect(reason)}"
  end
end
