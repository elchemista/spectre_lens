defmodule SpectreLens.Discovery.Page do
  @moduledoc "One page visited during goal-scoped discovery."

  @type t :: %__MODULE__{
          url: binary(),
          title: binary() | nil,
          outline: SpectreLens.Outline.t() | nil,
          summary: binary() | nil,
          depth: non_neg_integer(),
          hash: binary() | nil
        }

  defstruct [:url, :title, :outline, :summary, :depth, :hash]
end
