defmodule SpectreLens.Tab do
  @moduledoc """
  Handle for one browser target.

  This is a process-local handle: connection, runtime, and request-guard fields
  make it deliberately non-serializable. Use `%SpectreLens.TabRef{}` whenever
  tab identity must cross a durable Spectre State or Run boundary. Public
  functions dispatch through `SpectreLens.Protocol`, so the live tab can be
  backed by CDP, WebDriver BiDi, MCP, or another browser protocol.
  """

  @type t :: %__MODULE__{
          id: binary() | nil,
          handle: term(),
          conn: term(),
          protocol: module() | nil,
          runtime: pid() | nil,
          instance_id: term(),
          target_id: binary() | nil,
          session_id: binary() | nil,
          browser_context_id: binary() | nil,
          session_key: term(),
          endpoint: binary() | nil,
          url_policy: keyword(),
          request_guard: pid() | nil
        }

  defstruct [
    :id,
    :handle,
    :conn,
    :protocol,
    :runtime,
    :instance_id,
    :target_id,
    :session_id,
    :browser_context_id,
    :session_key,
    :endpoint,
    :request_guard,
    url_policy: []
  ]
end
