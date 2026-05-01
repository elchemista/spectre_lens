defmodule SpectreLens.Protocol.LightpandaCDP do
  @moduledoc """
  Spectre Lens protocol driver backed by Lightpanda's CDP endpoint.

  This is the default driver. It uses standard CDP for browser primitives and
  Lightpanda's `LP.*` domain for agent-first page projections.
  """

  @behaviour SpectreLens.Protocol

  alias SpectreLens.Tab

  @impl true
  def new_tab(instance, opts \\ []) do
    opts =
      opts
      |> Keyword.put(:driver, __MODULE__)
      |> Keyword.put(:runtime, opts[:runtime])
      |> Keyword.put(:instance_id, instance.id)
      |> Keyword.put(:endpoint, instance.endpoint)

    SpectreLens.Page.new(instance.conn, opts)
  end

  @impl true
  def close_tab(%Tab{} = tab), do: SpectreLens.Page.close(tab)

  @impl true
  def command(%Tab{} = tab, method, params, opts),
    do: SpectreLens.Page.command(tab, method, params, opts)

  @impl true
  def navigate(%Tab{} = tab, url, opts), do: SpectreLens.Page.navigate(tab, url, opts)

  @impl true
  def evaluate(%Tab{} = tab, expression, opts),
    do: SpectreLens.Page.evaluate(tab, expression, opts)

  @impl true
  def url(%Tab{} = tab), do: SpectreLens.Page.url(tab)

  @impl true
  def title(%Tab{} = tab), do: SpectreLens.Page.title(tab)

  @impl true
  def html(%Tab{} = tab, opts), do: SpectreLens.Page.html(tab, opts)

  @impl true
  def markdown(%Tab{} = tab, opts), do: SpectreLens.Page.markdown(tab, opts)

  @impl true
  def semantic_tree(%Tab{} = tab, opts), do: SpectreLens.Page.semantic_tree(tab, opts)

  @impl true
  def interactive_elements(%Tab{} = tab, opts),
    do: SpectreLens.Page.interactive_elements(tab, opts)

  @impl true
  def structured_data(%Tab{} = tab, opts), do: SpectreLens.Page.structured_data(tab, opts)

  @impl true
  def page_map(%Tab{} = tab, opts), do: SpectreLens.Page.page_map(tab, opts)

  @impl true
  def focus(%Tab{} = tab, ref, opts), do: SpectreLens.Page.focus(tab, ref, opts)

  @impl true
  def links(%Tab{} = tab, opts), do: SpectreLens.Page.links(tab, opts)

  @impl true
  def forms(%Tab{} = tab, opts), do: SpectreLens.Page.forms(tab, opts)

  @impl true
  def screenshot(%Tab{} = tab, opts), do: SpectreLens.Page.screenshot(tab, opts)

  @impl true
  def pdf(%Tab{} = tab, opts), do: SpectreLens.Page.pdf(tab, opts)

  @impl true
  def click(%Tab{} = tab, ref, opts), do: SpectreLens.Page.click(tab, ref, opts)

  @impl true
  def fill(%Tab{} = tab, ref, value, opts), do: SpectreLens.Page.fill(tab, ref, value, opts)

  @impl true
  def submit(%Tab{} = tab, ref, fields, opts), do: SpectreLens.Page.submit(tab, ref, fields, opts)

  @impl true
  def wait_for_selector(%Tab{} = tab, selector, opts),
    do: SpectreLens.Page.wait_for_selector(tab, selector, opts)

  @impl true
  def wait_for_navigation(%Tab{} = tab, fun, opts),
    do: SpectreLens.Page.wait_for_navigation(tab, fun, opts)

  @impl true
  def scroll(%Tab{} = tab, opts), do: SpectreLens.Page.scroll(tab, opts)
end
