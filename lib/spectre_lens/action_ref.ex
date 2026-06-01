defmodule SpectreLens.ActionRef do
  @moduledoc """
  Stable-ish action handle generated from links, forms, and interactive elements.

  Action refs are intentionally adapter-neutral. A caller can pass one back to
  `SpectreLens.act/3` without caring whether the original page element came
  from CDP, Lightpanda's `LP.*` APIs, or another future driver.
  """

  @type kind :: :link | :button | :input | :select | :textarea | :form | :custom

  @type t :: %__MODULE__{
          id: binary() | nil,
          kind: kind(),
          label: binary() | nil,
          selector: binary() | nil,
          xpath: binary() | nil,
          node_id: integer() | nil,
          href: binary() | nil,
          role: binary() | nil,
          name: binary() | nil
        }

  defstruct [:id, :kind, :label, :selector, :xpath, :node_id, :href, :role, :name]
end
