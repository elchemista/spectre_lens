defmodule SpectreLens.Protocol.CDP do
  @moduledoc """
  Browser-neutral protocol backed by Chrome DevTools Protocol.

  This adapter uses only standard CDP domains and DOM JavaScript fallbacks.
  Lightpanda-specific extensions live in `SpectreLens.Protocol.Lightpanda`.
  """

  @behaviour SpectreLens.Protocol

  alias SpectreLens.CDP.Connection
  alias SpectreLens.Tab

  @impl SpectreLens.Protocol
  def new_tab(instance, opts \\ []) do
    opts =
      opts
      |> Keyword.put(:protocol, __MODULE__)
      |> Keyword.put(:runtime, opts[:runtime])
      |> Keyword.put(:instance_id, instance.id)
      |> Keyword.put(:endpoint, instance.endpoint)

    SpectreLens.Page.new(instance.connection, opts)
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

  @impl SpectreLens.Protocol
  def capture_session(%Tab{} = tab, opts), do: SpectreLens.Page.session_snapshot(tab, opts)

  @impl SpectreLens.Protocol
  def restore_session(%Tab{} = tab, session, opts),
    do: SpectreLens.Page.restore_session(tab, session, opts)

  @impl SpectreLens.Protocol
  def tab_key(%Tab{target_id: target_id}) when is_binary(target_id),
    do: {:target, target_id}

  def tab_key(%Tab{session_id: session_id}) when is_binary(session_id),
    do: {:session, session_id}

  def tab_key(%Tab{id: id}), do: {:tab, id}

  @impl SpectreLens.Protocol
  def handle_tab_closed(%Tab{} = tab) do
    SpectreLens.Page.target_closed(tab)
  end

  @impl SpectreLens.Protocol
  def subscribe(instance, subscriber) do
    :ok =
      Connection.subscribe_event(
        instance.connection,
        "Target.targetDestroyed",
        nil,
        subscriber
      )

    Connection.subscribe_event(
      instance.connection,
      "Target.detachedFromTarget",
      nil,
      subscriber
    )
  end

  @impl SpectreLens.Protocol
  def handle_info(
        {:spectre_lens_cdp_event, connection, "Target.targetDestroyed", _session_id,
         %{"targetId" => target_id}},
        %{connection: connection}
      ),
      do: {:tab_closed, {:target, target_id}}

  def handle_info(
        {:spectre_lens_cdp_event, connection, "Target.detachedFromTarget", _session_id,
         %{"targetId" => target_id}},
        %{connection: connection}
      ),
      do: {:tab_closed, {:target, target_id}}

  def handle_info({:EXIT, connection, reason}, %{connection: connection}),
    do: {:instance_down, {:connection_down, reason}}

  def handle_info(_message, _instance), do: :ignore
end
