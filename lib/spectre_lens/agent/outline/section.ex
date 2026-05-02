defmodule SpectreLens.Outline.Section do
  @moduledoc "One compact page section in a `SpectreLens.Outline`."

  @type t :: %__MODULE__{
          id: binary() | nil,
          title: binary(),
          purpose: SpectreLens.Region.purpose(),
          selector: binary() | nil,
          label: binary() | nil,
          text: binary() | nil,
          links: [binary()],
          fields: [binary()],
          stats: map()
        }

  defstruct [
    :id,
    :title,
    :purpose,
    :selector,
    :label,
    :text,
    links: [],
    fields: [],
    stats: %{}
  ]
end
