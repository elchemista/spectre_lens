defmodule SpectreLens.Protocol.LightpandaCDP do
  @moduledoc """
  Spectre Lens protocol driver backed by Lightpanda's CDP endpoint.

  This is the default driver. It uses standard CDP for browser primitives and
  Lightpanda's `LP.*` domain for agent-first page projections.
  """

  @behaviour SpectreLens.Protocol

  alias SpectreLens.Tab

  @impl SpectreLens.Protocol
  def new_tab(instance, opts \\ []) do
    opts =
      opts
      |> Keyword.put(:driver, __MODULE__)
      |> Keyword.put(:runtime, opts[:runtime])
      |> Keyword.put(:instance_id, instance.id)
      |> Keyword.put(:endpoint, instance.endpoint)

    SpectreLens.Page.new(instance.conn, opts)
  end

  @impl SpectreLens.Protocol
  def close_tab(%Tab{} = tab), do: SpectreLens.Page.close(tab)

  @impl SpectreLens.Protocol
  def command(%Tab{} = tab, method, params, opts),
    do: SpectreLens.Page.command(tab, method, params, opts)

  @impl SpectreLens.Protocol
  def navigate(%Tab{} = tab, url, opts), do: SpectreLens.Page.navigate(tab, url, opts)

  @impl SpectreLens.Protocol
  def evaluate(%Tab{} = tab, expression, opts),
    do: SpectreLens.Page.evaluate(tab, expression, opts)

  @impl SpectreLens.Protocol
  def url(%Tab{} = tab), do: SpectreLens.Page.url(tab)

  @impl SpectreLens.Protocol
  def title(%Tab{} = tab), do: SpectreLens.Page.title(tab)

  @impl SpectreLens.Protocol
  def html(%Tab{} = tab, opts), do: SpectreLens.Page.html(tab, opts)

  @impl SpectreLens.Protocol
  def markdown(%Tab{} = tab, opts), do: SpectreLens.Page.markdown(tab, opts)

  @impl SpectreLens.Protocol
  def semantic_tree(%Tab{} = tab, opts), do: SpectreLens.Page.semantic_tree(tab, opts)

  @impl SpectreLens.Protocol
  def interactive_elements(%Tab{} = tab, opts),
    do: SpectreLens.Page.interactive_elements(tab, opts)

  @impl SpectreLens.Protocol
  def structured_data(%Tab{} = tab, opts), do: SpectreLens.Page.structured_data(tab, opts)

  @impl SpectreLens.Protocol
  def page_map(%Tab{} = tab, opts), do: SpectreLens.Page.page_map(tab, opts)

  @impl SpectreLens.Protocol
  def focus(%Tab{} = tab, ref, opts), do: SpectreLens.Page.focus(tab, ref, opts)

  @impl SpectreLens.Protocol
  def links(%Tab{} = tab, opts), do: SpectreLens.Page.links(tab, opts)

  @impl SpectreLens.Protocol
  def forms(%Tab{} = tab, opts), do: SpectreLens.Page.forms(tab, opts)

  @impl SpectreLens.Protocol
  def screenshot(%Tab{} = tab, opts), do: SpectreLens.Page.screenshot(tab, opts)

  @impl SpectreLens.Protocol
  def pdf(%Tab{} = tab, opts), do: SpectreLens.Page.pdf(tab, opts)

  @impl SpectreLens.Protocol
  def click(%Tab{} = tab, ref, opts), do: SpectreLens.Page.click(tab, ref, opts)

  @impl SpectreLens.Protocol
  def fill(%Tab{} = tab, ref, value, opts), do: SpectreLens.Page.fill(tab, ref, value, opts)

  @impl SpectreLens.Protocol
  def submit(%Tab{} = tab, ref, fields, opts), do: SpectreLens.Page.submit(tab, ref, fields, opts)

  @impl SpectreLens.Protocol
  def wait_for_selector(%Tab{} = tab, selector, opts),
    do: SpectreLens.Page.wait_for_selector(tab, selector, opts)

  @impl SpectreLens.Protocol
  def wait_for_navigation(%Tab{} = tab, fun, opts),
    do: SpectreLens.Page.wait_for_navigation(tab, fun, opts)

  @impl SpectreLens.Protocol
  def scroll(%Tab{} = tab, opts), do: SpectreLens.Page.scroll(tab, opts)
end
