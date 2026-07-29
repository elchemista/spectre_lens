defmodule SpectreLens.Browser.Instance do
  @moduledoc """
  Normalized live browser instance owned by `SpectreLens.Runtime`.

  `connection` and `owner` are intentionally opaque, process-local values.
  They never appear in `SpectreLens.TabRef`, Spectre State, or Run
  checkpoints.
  """

  @enforce_keys [:id, :backend, :protocol]
  defstruct [
    :id,
    :backend,
    :protocol,
    :endpoint,
    :connection,
    :owner,
    max_tabs: 1,
    metadata: %{},
    tabs: %{},
    reservations: %{}
  ]

  @type t :: %__MODULE__{
          id: pos_integer(),
          backend: module(),
          protocol: module(),
          endpoint: binary() | nil,
          connection: term(),
          owner: term(),
          max_tabs: pos_integer(),
          metadata: map(),
          tabs: map(),
          reservations: map()
        }
end
