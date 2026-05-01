defmodule SpectreLens.Tab do
  @moduledoc """
  Handle for one browser target.

  The struct is intentionally small and serializable except for the connection
  pid. Public functions dispatch through `SpectreLens.Protocol`, so the tab can
  be backed by CDP, WebDriver BiDi, MCP, or another future browser driver.
  """

  @type t :: %__MODULE__{
          conn: pid(),
          driver: module(),
          runtime: pid() | nil,
          instance_id: term(),
          target_id: binary() | nil,
          session_id: binary(),
          browser_context_id: binary() | nil,
          session_key: term(),
          endpoint: binary() | nil
        }

  defstruct [
    :conn,
    :driver,
    :runtime,
    :instance_id,
    :target_id,
    :session_id,
    :browser_context_id,
    :session_key,
    :endpoint
  ]
end
