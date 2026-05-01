defmodule SpectreLens.Protocol do
  @moduledoc """
  Browser-driver behaviour and dispatcher for Spectre Lens.

  CDP is not the stable public contract of Spectre Lens. It is one possible
  transport. This behaviour defines the agent-facing browser protocol used by
  the rest of the library. A driver can be backed by Lightpanda CDP today and
  by WebDriver BiDi, MCP, Chrome CDP, or another adapter later.
  """

  alias SpectreLens.Tab

  @type instance :: map()
  @type result(value) :: {:ok, value} | {:error, term()}

  @callback new_tab(instance(), keyword()) :: result(Tab.t())
  @callback close_tab(Tab.t()) :: :ok | {:error, term()}
  @callback command(Tab.t(), binary(), map(), keyword()) :: result(map())
  @callback navigate(Tab.t(), binary(), keyword()) :: :ok | {:error, term()}
  @callback evaluate(Tab.t(), binary(), keyword()) :: result(term())
  @callback url(Tab.t()) :: result(binary())
  @callback title(Tab.t()) :: result(binary() | nil)
  @callback html(Tab.t(), keyword()) :: result(binary())
  @callback markdown(Tab.t(), keyword()) :: result(binary())
  @callback semantic_tree(Tab.t(), keyword()) :: result(term())
  @callback interactive_elements(Tab.t(), keyword()) :: result([map()])
  @callback structured_data(Tab.t(), keyword()) :: result(map())
  @callback page_map(Tab.t(), keyword()) :: result(SpectreLens.PageMap.t())
  @callback focus(Tab.t(), term(), keyword()) :: result(SpectreLens.PageMap.t())
  @callback links(Tab.t(), keyword()) :: result([map()])
  @callback forms(Tab.t(), keyword()) :: result([map()])
  @callback screenshot(Tab.t(), keyword()) :: result(binary())
  @callback pdf(Tab.t(), keyword()) :: result(binary())
  @callback click(Tab.t(), term(), keyword()) :: :ok | {:error, term()}
  @callback fill(Tab.t(), term(), binary(), keyword()) :: :ok | {:error, term()}
  @callback submit(Tab.t(), term(), map(), keyword()) :: :ok | {:error, term()}
  @callback wait_for_selector(Tab.t(), binary(), keyword()) :: :ok | {:error, term()}
  @callback wait_for_navigation(Tab.t(), (-> term()), keyword()) :: :ok | {:error, term()}
  @callback scroll(Tab.t(), keyword()) :: :ok | {:error, term()}

  @doc "Returns the driver for a tab or instance."
  @spec driver(Tab.t() | map() | keyword()) :: module()
  def driver(%Tab{driver: driver}) when is_atom(driver) and not is_nil(driver), do: driver
  def driver(%{driver: driver}) when is_atom(driver) and not is_nil(driver), do: driver

  def driver(opts) when is_list(opts),
    do: Keyword.get(opts, :driver, SpectreLens.Protocol.LightpandaCDP)

  def driver(_), do: SpectreLens.Protocol.LightpandaCDP

  def new_tab(instance, opts \\ []), do: driver(instance).new_tab(instance, opts)
  def close_tab(%Tab{} = tab), do: driver(tab).close_tab(tab)

  def command(%Tab{} = tab, method, params \\ %{}, opts \\ []),
    do: driver(tab).command(tab, method, params, opts)

  def navigate(%Tab{} = tab, url, opts \\ []), do: driver(tab).navigate(tab, url, opts)

  def evaluate(%Tab{} = tab, expression, opts \\ []),
    do: driver(tab).evaluate(tab, expression, opts)

  def url(%Tab{} = tab), do: driver(tab).url(tab)
  def title(%Tab{} = tab), do: driver(tab).title(tab)
  def html(%Tab{} = tab, opts \\ []), do: driver(tab).html(tab, opts)
  def markdown(%Tab{} = tab, opts \\ []), do: driver(tab).markdown(tab, opts)
  def semantic_tree(%Tab{} = tab, opts \\ []), do: driver(tab).semantic_tree(tab, opts)

  def interactive_elements(%Tab{} = tab, opts \\ []),
    do: driver(tab).interactive_elements(tab, opts)

  def structured_data(%Tab{} = tab, opts \\ []), do: driver(tab).structured_data(tab, opts)
  def page_map(%Tab{} = tab, opts \\ []), do: driver(tab).page_map(tab, opts)
  def focus(%Tab{} = tab, ref, opts \\ []), do: driver(tab).focus(tab, ref, opts)
  def links(%Tab{} = tab, opts \\ []), do: driver(tab).links(tab, opts)
  def forms(%Tab{} = tab, opts \\ []), do: driver(tab).forms(tab, opts)
  def screenshot(%Tab{} = tab, opts \\ []), do: driver(tab).screenshot(tab, opts)
  def pdf(%Tab{} = tab, opts \\ []), do: driver(tab).pdf(tab, opts)
  def click(%Tab{} = tab, ref, opts \\ []), do: driver(tab).click(tab, ref, opts)
  def fill(%Tab{} = tab, ref, value, opts \\ []), do: driver(tab).fill(tab, ref, value, opts)

  def submit(%Tab{} = tab, ref, fields \\ %{}, opts \\ []),
    do: driver(tab).submit(tab, ref, fields, opts)

  def wait_for_selector(%Tab{} = tab, selector, opts \\ []),
    do: driver(tab).wait_for_selector(tab, selector, opts)

  def wait_for_navigation(%Tab{} = tab, fun, opts \\ []),
    do: driver(tab).wait_for_navigation(tab, fun, opts)

  def scroll(%Tab{} = tab, opts \\ []), do: driver(tab).scroll(tab, opts)
end
