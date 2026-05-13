defmodule SpectreLens.Discovery.Candidate do
  @moduledoc "A ranked navigation candidate discovered for an agent goal."

  @type t :: %__MODULE__{
          url: binary(),
          text: binary() | nil,
          selector: binary() | nil,
          source_url: binary(),
          region: atom() | nil,
          score: float(),
          reason: binary() | nil,
          metadata: map()
        }

  defstruct [
    :url,
    :text,
    :selector,
    :source_url,
    :region,
    score: 0.0,
    reason: nil,
    metadata: %{}
  ]
end
