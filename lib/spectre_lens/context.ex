defmodule SpectreLens.Context do
  @moduledoc """
  Mutable carrier passed through the Spectre Lens plug pipeline.

  Each `SpectreLens.look/2` call starts with a tab, an empty
  `%SpectreLens.View{}`, and the requested projection list. Pipeline plugs add
  view fields, warnings, errors, and private assigns as they run.
  """

  @type t :: %__MODULE__{
          tab: SpectreLens.Tab.t(),
          view: SpectreLens.View.t(),
          include: [atom()],
          assigns: map(),
          halted?: boolean()
        }

  defstruct [:tab, view: %SpectreLens.View{}, include: [], assigns: %{}, halted?: false]
end
