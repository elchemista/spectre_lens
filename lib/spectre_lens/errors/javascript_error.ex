defmodule SpectreLens.JavaScriptError do
  @moduledoc "Returned when page JavaScript evaluation throws."

  defexception [:message]

  @type t :: %__MODULE__{message: binary()}

  @doc "Builds a JavaScript error from a browser exception description."
  @spec new(term()) :: t()
  def new(description), do: %__MODULE__{message: to_string(description)}
end
