defmodule SpectreLens.ConnectionError do
  @moduledoc "Returned when Spectre Lens cannot connect to a browser endpoint."

  defexception [:reason, :message]

  @type t :: %__MODULE__{reason: term(), message: binary()}

  @doc "Builds a connection error from the underlying transport reason."
  @spec new(term()) :: t()
  def new(reason) do
    %__MODULE__{reason: reason, message: "connection failed: #{inspect(reason)}"}
  end
end
