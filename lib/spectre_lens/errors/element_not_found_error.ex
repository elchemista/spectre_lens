defmodule SpectreLens.ElementNotFoundError do
  @moduledoc "Returned when a selector or element reference cannot be found."

  defexception [:ref, :message]

  @type t :: %__MODULE__{ref: term(), message: binary()}

  @doc "Builds an element-not-found error for a selector, action ref, or opaque ref."
  @spec new(term()) :: t()
  def new(ref) do
    %__MODULE__{ref: ref, message: "element not found: #{inspect(ref)}"}
  end
end
