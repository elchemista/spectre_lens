defmodule SpectreLens.Context do
  @moduledoc "Mutable carrier passed through the Spectre Lens plug pipeline."

  @type t :: %__MODULE__{
          tab: SpectreLens.Tab.t(),
          view: SpectreLens.View.t(),
          include: [atom()],
          assigns: map(),
          halted?: boolean()
        }

  defstruct [:tab, view: %SpectreLens.View{}, include: [], assigns: %{}, halted?: false]
end
