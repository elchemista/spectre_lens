defmodule SpectreLens.CDPError do
  @moduledoc "Returned when the Chrome DevTools Protocol endpoint reports an error."

  defexception [:code, :method, :message]

  @type t :: %__MODULE__{code: integer(), method: binary() | nil, message: binary()}

  @doc "Builds a CDP protocol error."
  @spec new(integer(), binary(), binary() | nil) :: t()
  def new(code, message, method \\ nil) do
    prefix = if method, do: "#{method} failed", else: "CDP command failed"
    %__MODULE__{code: code, method: method, message: "#{prefix}: #{code} #{message}"}
  end
end
