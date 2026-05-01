defmodule SpectreLens.Region do
  @moduledoc "One meaningful page region in a `SpectreLens.PageMap`."

  @type purpose ::
          :navigation
          | :hero
          | :sidebar
          | :gallery
          | :contact_form
          | :search_form
          | :form
          | :footer
          | :link_collection
          | :content_section

  @type t :: %__MODULE__{
          id: binary() | nil,
          kind: atom(),
          purpose: purpose(),
          label: binary() | nil,
          position: binary() | nil,
          text: binary() | nil,
          selector: binary() | nil,
          links: [map()],
          fields: [map()],
          stats: map()
        }

  defstruct [
    :id,
    :kind,
    :purpose,
    :label,
    :position,
    :text,
    :selector,
    links: [],
    fields: [],
    stats: %{}
  ]
end
