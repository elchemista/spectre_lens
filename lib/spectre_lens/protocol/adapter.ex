defmodule SpectreLens.Protocol.Adapter do
  @moduledoc """
  Defaults for incrementally implementing a Lens page protocol.

  An adapter can `use SpectreLens.Protocol.Adapter` and override only the
  capabilities it actually provides. Every remaining callback fails explicitly
  with `SpectreLens.UnsupportedError`, while still satisfying the complete
  runtime contract. This is useful for focused ExGram, ExWapp, Playwright,
  WebDriver BiDi, MCP, and hosted-browser integrations.
  """

  defmacro __using__(_opts) do
    quote generated: true do
      @behaviour SpectreLens.Protocol

      alias SpectreLens.Protocol.Adapter, as: SpectreLensProtocolAdapter

      @impl SpectreLens.Protocol
      def new_tab(_instance, _opts),
        do: SpectreLensProtocolAdapter.unsupported(:new_tab)

      @impl SpectreLens.Protocol
      def close_tab(_tab),
        do: SpectreLensProtocolAdapter.unsupported(:close_tab)

      @impl SpectreLens.Protocol
      def command(_tab, _method, _params, _opts),
        do: SpectreLensProtocolAdapter.unsupported(:command)

      @impl SpectreLens.Protocol
      def navigate(_tab, _url, _opts),
        do: SpectreLensProtocolAdapter.unsupported(:navigate)

      @impl SpectreLens.Protocol
      def evaluate(_tab, _expression, _opts),
        do: SpectreLensProtocolAdapter.unsupported(:evaluate)

      @impl SpectreLens.Protocol
      def url(_tab), do: SpectreLensProtocolAdapter.unsupported(:url)

      @impl SpectreLens.Protocol
      def title(_tab), do: SpectreLensProtocolAdapter.unsupported(:title)

      @impl SpectreLens.Protocol
      def html(_tab, _opts), do: SpectreLensProtocolAdapter.unsupported(:html)

      @impl SpectreLens.Protocol
      def markdown(_tab, _opts),
        do: SpectreLensProtocolAdapter.unsupported(:markdown)

      @impl SpectreLens.Protocol
      def semantic_tree(_tab, _opts),
        do: SpectreLensProtocolAdapter.unsupported(:semantic_tree)

      @impl SpectreLens.Protocol
      def interactive_elements(_tab, _opts),
        do: SpectreLensProtocolAdapter.unsupported(:interactive_elements)

      @impl SpectreLens.Protocol
      def structured_data(_tab, _opts),
        do: SpectreLensProtocolAdapter.unsupported(:structured_data)

      @impl SpectreLens.Protocol
      def page_map(_tab, _opts),
        do: SpectreLensProtocolAdapter.unsupported(:page_map)

      @impl SpectreLens.Protocol
      def focus(_tab, _ref, _opts),
        do: SpectreLensProtocolAdapter.unsupported(:focus)

      @impl SpectreLens.Protocol
      def links(_tab, _opts), do: SpectreLensProtocolAdapter.unsupported(:links)

      @impl SpectreLens.Protocol
      def forms(_tab, _opts), do: SpectreLensProtocolAdapter.unsupported(:forms)

      @impl SpectreLens.Protocol
      def screenshot(_tab, _opts),
        do: SpectreLensProtocolAdapter.unsupported(:screenshot)

      @impl SpectreLens.Protocol
      def pdf(_tab, _opts), do: SpectreLensProtocolAdapter.unsupported(:pdf)

      @impl SpectreLens.Protocol
      def click(_tab, _ref, _opts),
        do: SpectreLensProtocolAdapter.unsupported(:click)

      @impl SpectreLens.Protocol
      def fill(_tab, _ref, _value, _opts),
        do: SpectreLensProtocolAdapter.unsupported(:fill)

      @impl SpectreLens.Protocol
      def submit(_tab, _ref, _fields, _opts),
        do: SpectreLensProtocolAdapter.unsupported(:submit)

      @impl SpectreLens.Protocol
      def wait_for_selector(_tab, _selector, _opts),
        do: SpectreLensProtocolAdapter.unsupported(:wait_for_selector)

      @impl SpectreLens.Protocol
      def wait_for_navigation(_tab, _fun, _opts),
        do: SpectreLensProtocolAdapter.unsupported(:wait_for_navigation)

      @impl SpectreLens.Protocol
      def scroll(_tab, _opts), do: SpectreLensProtocolAdapter.unsupported(:scroll)

      defoverridable new_tab: 2,
                     close_tab: 1,
                     command: 4,
                     navigate: 3,
                     evaluate: 3,
                     url: 1,
                     title: 1,
                     html: 2,
                     markdown: 2,
                     semantic_tree: 2,
                     interactive_elements: 2,
                     structured_data: 2,
                     page_map: 2,
                     focus: 3,
                     links: 2,
                     forms: 2,
                     screenshot: 2,
                     pdf: 2,
                     click: 3,
                     fill: 4,
                     submit: 4,
                     wait_for_selector: 3,
                     wait_for_navigation: 3,
                     scroll: 2
    end
  end

  @doc false
  @spec unsupported(atom()) :: {:error, SpectreLens.UnsupportedError.t()}
  def unsupported(feature), do: {:error, SpectreLens.UnsupportedError.new(feature)}
end
