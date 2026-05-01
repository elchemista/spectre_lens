defmodule SpectreLens.UnsupportedError do
  @moduledoc "Returned when a browser capability is unavailable."

  defexception [:feature, :reason, :message]

  @type t :: %__MODULE__{feature: atom(), reason: term() | nil, message: binary()}

  @doc "Builds an unsupported-feature error."
  @spec new(atom(), term() | nil) :: t()
  def new(feature, reason \\ nil) do
    detail = if reason, do: ": #{inspect(reason)}", else: ""
    %__MODULE__{feature: feature, reason: reason, message: "#{feature} is not supported#{detail}"}
  end
end
