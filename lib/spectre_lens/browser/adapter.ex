defmodule SpectreLens.Browser.Adapter do
  @moduledoc """
  Convenience defaults for a Lens browser runtime backend.

  The using module still implements resource allocation and shutdown. The
  adapter supplies the declared default protocol and a configurable capacity,
  keeping small external-service integrations focused on their lifecycle.

      use SpectreLens.Browser.Adapter,
        protocol: MyApp.BrowserProtocol,
        max_tabs: 4
  """

  defmacro __using__(opts) do
    protocol = Keyword.fetch!(opts, :protocol)
    max_tabs = Keyword.get(opts, :max_tabs, 1)

    quote do
      @behaviour SpectreLens.Browser

      @impl SpectreLens.Browser
      def default_protocol, do: unquote(protocol)

      @impl SpectreLens.Browser
      def max_tabs(_instance, opts) do
        Keyword.get(opts, :max_tabs_per_instance, unquote(max_tabs))
      end

      defoverridable default_protocol: 0, max_tabs: 2
    end
  end
end
