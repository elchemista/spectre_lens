defmodule SpectreLens.View do
  @moduledoc """
  Agent-readable projection of the current page state.

  Views are the main boundary object returned by `SpectreLens.look/2`. Missing
  optional projections remain `nil` or empty lists, while recoverable projection
  failures are collected in `warnings` or `errors`.
  """

  @type t :: %__MODULE__{
          url: binary() | nil,
          title: binary() | nil,
          markdown: binary() | nil,
          html: binary() | nil,
          semantic_tree: map() | list() | nil,
          semantic_text: binary() | nil,
          interactive: [map()],
          forms: [map()],
          links: [map()],
          structured_data: map(),
          llms: SpectreLens.LlmsTxt.t() | nil,
          llms_context: binary() | nil,
          actions: [SpectreLens.ActionRef.t()],
          warnings: [term()],
          errors: [term()]
        }

  defstruct [
    :url,
    :title,
    :markdown,
    :html,
    :semantic_tree,
    :semantic_text,
    interactive: [],
    forms: [],
    links: [],
    structured_data: %{},
    llms: nil,
    llms_context: nil,
    actions: [],
    warnings: [],
    errors: []
  ]
end
