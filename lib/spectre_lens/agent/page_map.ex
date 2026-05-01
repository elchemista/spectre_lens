defmodule SpectreLens.PageMap do
  @moduledoc """
  High-level composition map of a page for agent reasoning.

  `description` is meant to be read directly by an agent. `regions` keeps the
  structured evidence used to build the prose.
  """

  @type t :: %__MODULE__{
          description: binary(),
          regions: [SpectreLens.Region.t()],
          warnings: [term()],
          source: :dom | :semantic_tree | atom()
        }

  defstruct description: "", regions: [], warnings: [], source: :dom
end
