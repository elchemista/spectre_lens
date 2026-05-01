defmodule SpectreLens.TimeoutError do
  @moduledoc "Returned when an operation exceeds its deadline."

  defexception [:operation, :timeout_ms, :message]

  @type t :: %__MODULE__{
          operation: term(),
          timeout_ms: non_neg_integer() | nil,
          message: binary()
        }

  @doc "Builds a timeout error."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    operation = Keyword.get(opts, :operation)
    timeout_ms = Keyword.get(opts, :timeout_ms)

    message =
      case {operation, timeout_ms} do
        {nil, nil} -> "operation timed out"
        {op, nil} -> "#{op} timed out"
        {op, ms} -> "#{op || "operation"} timed out after #{ms}ms"
      end

    %__MODULE__{operation: operation, timeout_ms: timeout_ms, message: message}
  end
end
