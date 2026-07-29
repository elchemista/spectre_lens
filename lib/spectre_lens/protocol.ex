defmodule SpectreLens.Protocol do
  @moduledoc """
  Browser page-protocol behaviour and dispatcher for Spectre Lens.

  CDP is not the stable public contract of Spectre Lens. It is one possible
  transport. This behaviour defines the agent-facing tab operations used by
  the rest of the library. Browser process lifecycle belongs to
  `SpectreLens.Browser`, so protocol modules remain independent from local
  binaries, cloud allocation, and pool ownership.
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
  @callback subscribe(map(), pid()) :: :ok | {:error, term()}
  @callback handle_info(term(), map()) ::
              :ignore | {:ok, map()} | {:tab_closed, term()} | {:instance_down, term()}
  @callback capture_session(Tab.t(), keyword()) :: result(SpectreLens.Session.t())
  @callback restore_session(Tab.t(), SpectreLens.Session.t() | map(), keyword()) ::
              :ok | {:error, term()}
  @callback tab_key(Tab.t()) :: term()
  @callback handle_tab_closed(Tab.t()) :: :ok

  @optional_callbacks subscribe: 2,
                      handle_info: 2,
                      capture_session: 2,
                      restore_session: 3,
                      tab_key: 1,
                      handle_tab_closed: 1

  @required_callbacks [
    new_tab: 2,
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
  ]

  @doc "Returns the protocol bound to a tab or live browser instance."
  @spec resolve(Tab.t() | map()) :: module()
  def resolve(%Tab{protocol: protocol}) when is_atom(protocol) and not is_nil(protocol),
    do: protocol

  def resolve(%{protocol: protocol}) when is_atom(protocol) and not is_nil(protocol),
    do: protocol

  @doc "Validates the complete page protocol before a runtime is started."
  @spec validate(module()) :: :ok | {:error, term()}
  def validate(module) when is_atom(module) and not is_nil(module) do
    if Code.ensure_loaded?(module) do
      missing =
        Enum.reject(@required_callbacks, fn {name, arity} ->
          function_exported?(module, name, arity)
        end)

      case missing do
        [] -> :ok
        callbacks -> {:error, {:invalid_browser_protocol, module, callbacks}}
      end
    else
      {:error, {:browser_protocol_unavailable, module}}
    end
  end

  def validate(module), do: {:error, {:invalid_browser_protocol, module}}

  def new_tab(instance, opts \\ []), do: resolve(instance).new_tab(instance, opts)
  def close_tab(%Tab{} = tab), do: resolve(tab).close_tab(tab)

  def command(%Tab{} = tab, method, params \\ %{}, opts \\ []),
    do: resolve(tab).command(tab, method, params, opts)

  def navigate(%Tab{} = tab, url, opts \\ []) do
    policy_opts = SpectreLens.URLPolicy.merge_options(tab.url_policy, opts)

    with {:ok, url} <- SpectreLens.URLPolicy.validate(url, policy_opts) do
      resolve(tab).navigate(tab, url, opts)
    end
  end

  def evaluate(%Tab{} = tab, expression, opts \\ []),
    do: resolve(tab).evaluate(tab, expression, opts)

  def url(%Tab{} = tab), do: resolve(tab).url(tab)
  def title(%Tab{} = tab), do: resolve(tab).title(tab)
  def html(%Tab{} = tab, opts \\ []), do: resolve(tab).html(tab, opts)
  def markdown(%Tab{} = tab, opts \\ []), do: resolve(tab).markdown(tab, opts)
  def semantic_tree(%Tab{} = tab, opts \\ []), do: resolve(tab).semantic_tree(tab, opts)

  def interactive_elements(%Tab{} = tab, opts \\ []),
    do: resolve(tab).interactive_elements(tab, opts)

  def structured_data(%Tab{} = tab, opts \\ []), do: resolve(tab).structured_data(tab, opts)
  def page_map(%Tab{} = tab, opts \\ []), do: resolve(tab).page_map(tab, opts)
  def focus(%Tab{} = tab, ref, opts \\ []), do: resolve(tab).focus(tab, ref, opts)
  def links(%Tab{} = tab, opts \\ []), do: resolve(tab).links(tab, opts)
  def forms(%Tab{} = tab, opts \\ []), do: resolve(tab).forms(tab, opts)
  def screenshot(%Tab{} = tab, opts \\ []), do: resolve(tab).screenshot(tab, opts)
  def pdf(%Tab{} = tab, opts \\ []), do: resolve(tab).pdf(tab, opts)
  def click(%Tab{} = tab, ref, opts \\ []), do: resolve(tab).click(tab, ref, opts)
  def fill(%Tab{} = tab, ref, value, opts \\ []), do: resolve(tab).fill(tab, ref, value, opts)

  def submit(%Tab{} = tab, ref, fields \\ %{}, opts \\ []),
    do: resolve(tab).submit(tab, ref, fields, opts)

  def wait_for_selector(%Tab{} = tab, selector, opts \\ []),
    do: resolve(tab).wait_for_selector(tab, selector, opts)

  def wait_for_navigation(%Tab{} = tab, fun, opts \\ []),
    do: resolve(tab).wait_for_navigation(tab, fun, opts)

  def scroll(%Tab{} = tab, opts \\ []), do: resolve(tab).scroll(tab, opts)

  @doc false
  @spec tab_key(Tab.t()) :: term()
  def tab_key(%Tab{} = tab) do
    protocol = resolve(tab)

    if function_exported?(protocol, :tab_key, 1) do
      protocol.tab_key(tab)
    else
      tab.id
    end
  end

  @doc false
  @spec handle_tab_closed(Tab.t()) :: :ok
  def handle_tab_closed(%Tab{} = tab) do
    protocol = resolve(tab)

    if function_exported?(protocol, :handle_tab_closed, 1) do
      protocol.handle_tab_closed(tab)
    else
      :ok
    end
  catch
    _, _ -> :ok
  end

  @doc false
  def capture_session(%Tab{} = tab, opts \\ []) do
    protocol = resolve(tab)

    if function_exported?(protocol, :capture_session, 2) do
      protocol.capture_session(tab, opts)
    else
      {:error, {:browser_session_unsupported, protocol}}
    end
  end

  @doc false
  def restore_session(%Tab{} = tab, session, opts \\ []) do
    protocol = resolve(tab)

    if function_exported?(protocol, :restore_session, 3) do
      protocol.restore_session(tab, session, opts)
    else
      {:error, {:browser_session_unsupported, protocol}}
    end
  end
end
