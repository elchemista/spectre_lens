defmodule SpectreLens.Page do
  @moduledoc """
  Page-level browser actions and agent-readable extraction helpers.
  """

  alias SpectreLens.CDP.Connection
  alias SpectreLens.Session
  alias SpectreLens.Tab
  alias SpectreLens.Telemetry

  @default_timeout 15_000
  @navigation_timeout 30_000

  @doc false
  @spec new(pid(), keyword()) :: {:ok, Tab.t()} | {:error, term()}
  def new(conn, opts \\ []) when is_pid(conn) do
    target_url = opts[:url] || "about:blank"

    with {:ok, browser_context_id} <- prepare_browser_context(conn, opts) do
      case open_target(conn, target_url, browser_context_id, opts) do
        {:ok, tab} ->
          {:ok, tab}

        {:error, reason} ->
          dispose_browser_context(conn, browser_context_id)
          {:error, reason}
      end
    end
  end

  @doc "Closes a tab target."
  @spec close(Tab.t()) :: :ok | {:error, term()}
  def close(%Tab{runtime: runtime} = tab) do
    target_result = close_target(tab)
    context_result = dispose_browser_context(tab.conn, tab.browser_context_id)

    if is_pid(runtime), do: SpectreLens.Runtime.release_tab(runtime, tab)

    case {target_result, context_result} do
      {{:error, _} = error, _} -> error
      {:ok, {:error, _} = error} -> error
      _ -> :ok
    end
  end

  @doc "Sends a raw CDP command to this tab session."
  @spec command(Tab.t(), binary(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def command(%Tab{conn: conn, session_id: sid}, method, params \\ %{}, opts \\ []) do
    Connection.send_command(conn, method, params, opts[:timeout] || @default_timeout, sid)
  end

  @doc "Navigates to a URL and waits for the load event."
  @spec navigate(Tab.t(), binary(), keyword()) :: :ok | {:error, term()}
  def navigate(%Tab{conn: conn, session_id: sid}, url, opts \\ []) do
    timeout = opts[:timeout] || @navigation_timeout

    Telemetry.span([:spectre_lens, :page, :navigate], %{url: url, session_id: sid}, fn ->
      wait_ref = Connection.register_event_waiter(conn, "Page.loadEventFired", sid)

      result =
        with {:ok, _} <- Connection.send_command(conn, "Page.navigate", %{url: url}, timeout, sid),
             {:ok, _} <- Connection.await_event(wait_ref, timeout),
             :ok <- maybe_wait_for_usable_document(conn, sid, opts, timeout) do
          :ok
        end

      span_result(result)
    end)
  end

  @doc "Evaluates JavaScript in the current page."
  @spec evaluate(Tab.t(), binary(), keyword()) :: {:ok, term()} | {:error, term()}
  def evaluate(%Tab{} = tab, expression, opts \\ []) do
    timeout = opts[:timeout] || @default_timeout
    metadata = %{session_id: tab.session_id, expression: String.slice(expression, 0, 80)}

    Telemetry.span([:spectre_lens, :page, :evaluate], metadata, fn ->
      result =
        case command(
               tab,
               "Runtime.evaluate",
               %{expression: expression, returnByValue: true, awaitPromise: true},
               timeout: timeout
             ) do
          {:ok, payload} -> parse_evaluate_result(payload)
          {:error, _} = error -> error
        end

      {result, %{result: result}}
    end)
  end

  @doc "Returns the current URL."
  @spec url(Tab.t()) :: {:ok, binary()} | {:error, term()}
  def url(%Tab{} = tab), do: evaluate(tab, "window.location.href")

  @doc "Returns the current document title."
  @spec title(Tab.t()) :: {:ok, binary() | nil} | {:error, term()}
  def title(%Tab{} = tab), do: evaluate(tab, "document.title")

  @doc "Returns the current rendered HTML."
  @spec html(Tab.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def html(%Tab{} = tab, opts \\ []) do
    page_operation(tab, :html, %{}, fn ->
      timeout = opts[:timeout] || @default_timeout

      with {:ok, %{"root" => %{"nodeId" => root_id}}} <-
             command(tab, "DOM.getDocument", %{}, timeout: timeout),
           {:ok, %{"outerHTML" => html}} <-
             command(tab, "DOM.getOuterHTML", %{nodeId: root_id}, timeout: timeout) do
        {:ok, html}
      end
    end)
  end

  @doc "Returns Lightpanda-native markdown for the current DOM."
  @spec markdown(Tab.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def markdown(%Tab{} = tab, opts \\ []) do
    page_operation(tab, :markdown, %{}, fn ->
      params =
        %{}
        |> maybe_put("nodeId", opts[:node_id])
        |> maybe_put("backendNodeId", opts[:backend_node_id])

      with {:ok, result} <- command(tab, "LP.getMarkdown", params, opts) do
        {:ok, result["markdown"] || result["text"] || ""}
      end
    end)
  end

  @doc "Returns Lightpanda semantic tree output."
  @spec semantic_tree(Tab.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def semantic_tree(%Tab{} = tab, opts \\ []) do
    page_operation(tab, :semantic_tree, %{}, fn ->
      format = opts[:format] || :json

      params =
        %{}
        |> maybe_put("format", semantic_tree_format(format))
        |> maybe_put("prune", opts[:prune])

      with {:ok, result} <- command(tab, "LP.getSemanticTree", params, opts) do
        {:ok, result["semanticTree"] || result["tree"] || result["nodes"] || result}
      end
    end)
  end

  @doc "Returns every interactive element reported by Lightpanda."
  @spec interactive_elements(Tab.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def interactive_elements(%Tab{} = tab, opts \\ []) do
    page_operation(tab, :interactive_elements, %{}, fn ->
      with {:ok, result} <- command(tab, "LP.getInteractiveElements", %{}, opts) do
        {:ok, result["elements"] || []}
      end
    end)
  end

  @doc "Returns structured metadata extracted by Lightpanda."
  @spec structured_data(Tab.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def structured_data(%Tab{} = tab, opts \\ []) do
    page_operation(tab, :structured_data, %{}, fn ->
      command(tab, "LP.getStructuredData", %{}, opts)
    end)
  end

  @doc """
  Returns a high-level composition map of the page for agents.

  This is semantic and heuristic: it uses DOM landmarks, roles, headings,
  classes, links, forms, images, DOM order, and available bounding boxes to
  describe regions such as navigation, hero, sidebar, gallery, contact form,
  and footer.
  """
  @spec page_map(Tab.t(), keyword()) :: {:ok, SpectreLens.PageMap.t()} | {:error, term()}
  def page_map(%Tab{} = tab, opts \\ []) do
    page_operation(tab, :page_map, %{}, fn ->
      with {:ok, regions} <- evaluate(tab, layout_script(nil, opts), opts) do
        result = build_page_map(regions, opts)
        Telemetry.emit([:spectre_lens, :page, :step], %{}, page_step(tab, :page_map, result))
        {:ok, result}
      end
    end)
  end

  @doc "Returns a focused composition map for one selector or action ref."
  @spec focus(Tab.t(), term(), keyword()) :: {:ok, SpectreLens.PageMap.t()} | {:error, term()}
  def focus(%Tab{} = tab, ref, opts \\ []) do
    page_operation(tab, :focus, %{target: inspect(ref)}, fn ->
      do_focus(tab, ref, opts)
    end)
  end

  @doc "Returns a simple link inventory via page JavaScript."
  @spec links(Tab.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def links(%Tab{} = tab, _opts \\ []) do
    evaluate(tab, """
    Array.from(document.querySelectorAll('a[href]')).map((a, index) => ({
      index,
      href: a.href,
      text: (a.innerText || a.textContent || '').trim(),
      title: a.getAttribute('title'),
      id: a.id || null,
      selector: a.id ? `#${CSS.escape(a.id)}` : null
    }))
    """)
  end

  @doc "Returns form structure via page JavaScript fallback."
  @spec forms(Tab.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def forms(%Tab{} = tab, _opts \\ []) do
    evaluate(tab, """
    Array.from(document.forms).map((form, formIndex) => ({
      index: formIndex,
      id: form.id || null,
      name: form.getAttribute('name'),
      action: form.action || null,
      method: (form.method || 'get').toLowerCase(),
      selector: form.id ? `#${CSS.escape(form.id)}` : `form:nth-of-type(${formIndex + 1})`,
      fields: Array.from(form.querySelectorAll('input, textarea, select, button')).map((el, index) => ({
        index,
        tag: el.tagName.toLowerCase(),
        type: el.getAttribute('type') || el.tagName.toLowerCase(),
        name: el.getAttribute('name'),
        id: el.id || null,
        label: (
          el.labels && el.labels[0] ? el.labels[0].innerText :
          el.getAttribute('aria-label') ||
          el.getAttribute('placeholder') ||
          el.getAttribute('name') ||
          el.id ||
          ''
        ).trim(),
        required: !!el.required,
        disabled: !!el.disabled,
        value: el.type === 'password' ? null : el.value,
        selector: el.id ? `#${CSS.escape(el.id)}` : null,
        options: el.tagName.toLowerCase() === 'select'
          ? Array.from(el.options).map(o => ({value: o.value, text: o.text, selected: o.selected}))
          : []
      }))
    }))
    """)
  end

  @doc "Captures a PNG screenshot."
  @spec screenshot(Tab.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def screenshot(%Tab{} = tab, opts \\ []) do
    page_operation(tab, :screenshot, %{format: to_string(opts[:format] || "png")}, fn ->
      params =
        %{"format" => to_string(opts[:format] || "png")}
        |> maybe_put("quality", opts[:quality])
        |> maybe_put("captureBeyondViewport", opts[:capture_beyond_viewport])

      with {:ok, %{"data" => data}} <- command(tab, "Page.captureScreenshot", params, opts) do
        Base.decode64(data)
      end
    end)
  end

  @doc "Prints the page to PDF when the browser supports `Page.printToPDF`."
  @spec pdf(Tab.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def pdf(%Tab{} = tab, opts \\ []) do
    page_operation(tab, :pdf, %{}, fn ->
      params =
        %{}
        |> maybe_put("printBackground", Keyword.get(opts, :print_background, true))
        |> maybe_put("landscape", opts[:landscape])
        |> maybe_put("paperWidth", opts[:paper_width])
        |> maybe_put("paperHeight", opts[:paper_height])

      case command(tab, "Page.printToPDF", params, opts) do
        {:ok, %{"data" => data}} ->
          Base.decode64(data)

        {:ok, other} ->
          {:error, SpectreLens.UnsupportedError.new(:pdf, {:unexpected_response, other})}

        {:error, reason} ->
          {:error, SpectreLens.UnsupportedError.new(:pdf, reason)}
      end
    end)
  end

  @doc "Clicks an element by selector, node id, or action ref."
  @spec click(Tab.t(), term(), keyword()) :: :ok | {:error, term()}
  def click(%Tab{} = tab, ref, opts \\ []) do
    page_operation(tab, :click, %{target: inspect(ref)}, fn ->
      timeout = opts[:timeout] || @default_timeout

      with {:ok, node_id} <- node_id(tab, ref, timeout),
           {:ok, {x, y}} <- click_point(tab, node_id, timeout),
           :ok <- dispatch_click(tab, x, y, timeout) do
        Telemetry.emit([:spectre_lens, :page, :step], %{}, %{
          action: :click,
          session_id: tab.session_id,
          target: inspect(ref),
          node_id: node_id
        })

        :ok
      end
    end)
  end

  @doc "Fills a text-like field."
  @spec fill(Tab.t(), term(), binary(), keyword()) :: :ok | {:error, term()}
  def fill(%Tab{} = tab, ref, value, opts \\ []) do
    page_operation(tab, :fill, %{target: inspect(ref)}, fn ->
      timeout = opts[:timeout] || @default_timeout

      with {:ok, node_id} <- node_id(tab, ref, timeout),
           {:ok, object_id} <- resolve_node(tab, node_id, timeout),
           :ok <- focus_element(tab, object_id, timeout),
           :ok <- clear_element(tab, object_id, timeout),
           {:ok, _} <- command(tab, "Input.insertText", %{text: value}, timeout: timeout) do
        Telemetry.emit([:spectre_lens, :page, :step], %{}, %{
          action: :fill,
          session_id: tab.session_id,
          target: inspect(ref),
          node_id: node_id
        })

        :ok
      end
    end)
  end

  @doc "Fills optional fields, submits a form, and waits for navigation."
  @spec submit(Tab.t(), term(), map(), keyword()) :: :ok | {:error, term()}
  def submit(%Tab{} = tab, form_ref, fields \\ %{}, opts \\ []) do
    page_operation(tab, :submit, %{target: inspect(form_ref)}, fn ->
      timeout = opts[:timeout] || @navigation_timeout

      with :ok <- fill_fields(tab, fields, opts) do
        wait_for_navigation(tab, form_submit_fun(tab, form_ref, timeout), timeout: timeout)
      end
    end)
  end

  @doc "Waits until an element exists."
  @spec wait_for_selector(Tab.t(), binary(), keyword()) :: :ok | {:error, term()}
  def wait_for_selector(%Tab{} = tab, selector, opts \\ []) do
    page_operation(tab, :wait_for_selector, %{target: selector}, fn ->
      timeout = opts[:timeout] || @default_timeout
      interval = opts[:interval] || 100
      deadline = System.monotonic_time(:millisecond) + timeout
      do_wait_for_selector(tab, selector, interval, deadline, timeout)
    end)
  end

  @doc "Runs `fun` and waits for `Page.loadEventFired`."
  @spec wait_for_navigation(Tab.t(), (-> term()), keyword()) :: :ok | {:error, term()}
  def wait_for_navigation(%Tab{conn: conn, session_id: sid} = tab, fun, opts \\ []) do
    page_operation(tab, :wait_for_navigation, %{}, fn ->
      timeout = opts[:timeout] || @navigation_timeout
      wait_ref = Connection.register_event_waiter(conn, "Page.loadEventFired", sid)
      await_after(fun, wait_ref, timeout)
    end)
  end

  @doc "Scrolls the page or element."
  @spec scroll(Tab.t(), keyword()) :: :ok | {:error, term()}
  def scroll(%Tab{} = tab, opts \\ []) do
    page_operation(tab, :scroll, %{target: inspect(opts[:ref] || opts[:selector])}, fn ->
      tab
      |> evaluate(scroll_expression(opts))
      |> ok_result()
    end)
  end

  @doc false
  @spec restore_session(Tab.t(), Session.t() | map(), keyword()) :: :ok | {:error, term()}
  def restore_session(tab, session, opts \\ [])

  def restore_session(%Tab{} = tab, %Session{} = session, opts) do
    with {:ok, origin} <- current_origin(tab, opts) do
      {local_storage, session_storage} = Session.storage_for_origin(session, origin)
      restore_origin_storage(tab, local_storage, session_storage, opts)
    end
  end

  def restore_session(%Tab{} = tab, session, opts) do
    with {:ok, session} <- Session.normalize(session) do
      restore_session(tab, session, opts)
    end
  end

  @doc false
  @spec session_snapshot(Tab.t(), keyword()) :: {:ok, Session.t()} | {:error, term()}
  def session_snapshot(tab, opts \\ [])

  def session_snapshot(%Tab{browser_context_id: nil}, _opts) do
    {:error, :missing_browser_context}
  end

  def session_snapshot(%Tab{} = tab, opts) do
    timeout = opts[:timeout] || @default_timeout

    with {:ok, %{"cookies" => cookies}} <-
           Connection.send_command(
             tab.conn,
             "Storage.getCookies",
             %{"browserContextId" => tab.browser_context_id},
             timeout
           ),
         {:ok, origin} <- current_origin(tab, opts),
         {:ok, storage} <- evaluate(tab, storage_snapshot_script(), opts) do
      {:ok,
       Session.new(
         cookies: cookies,
         local_storage: %{origin => Map.get(storage, "localStorage", %{})},
         session_storage: %{origin => Map.get(storage, "sessionStorage", %{})}
       )}
    end
  end

  @spec prepare_browser_context(pid(), keyword()) :: {:ok, binary() | nil} | {:error, term()}
  defp prepare_browser_context(conn, opts) do
    if Keyword.has_key?(opts, :session_key) do
      create_session_browser_context(conn, opts[:session_snapshot])
    else
      {:ok, nil}
    end
  end

  @spec create_session_browser_context(pid(), Session.t() | map() | nil) ::
          {:ok, binary()} | {:error, term()}
  defp create_session_browser_context(conn, session) do
    with {:ok, %{"browserContextId" => browser_context_id}} <-
           Connection.send_command(conn, "Target.createBrowserContext", %{}, 5_000) do
      seed_browser_context(conn, browser_context_id, session)
    end
  end

  @spec seed_browser_context(pid(), binary(), Session.t() | map() | nil) ::
          {:ok, binary()} | {:error, term()}
  defp seed_browser_context(conn, browser_context_id, session) do
    case set_context_cookies(conn, browser_context_id, session) do
      :ok ->
        {:ok, browser_context_id}

      {:error, _} = error ->
        dispose_browser_context(conn, browser_context_id)
        error
    end
  end

  @spec set_context_cookies(pid(), binary(), Session.t() | map() | nil) :: :ok | {:error, term()}
  defp set_context_cookies(_conn, _browser_context_id, nil), do: :ok

  defp set_context_cookies(conn, browser_context_id, session) do
    with {:ok, %Session{} = session} <- Session.normalize(session) do
      set_context_cookie_params(conn, browser_context_id, session.cookies)
    end
  end

  @spec set_context_cookie_params(pid(), binary(), [map()]) :: :ok | {:error, term()}
  defp set_context_cookie_params(_conn, _browser_context_id, []), do: :ok

  defp set_context_cookie_params(conn, browser_context_id, cookies) do
    cookie_params = Enum.map(cookies, &cookie_param/1)

    with {:ok, _} <-
           Connection.send_command(
             conn,
             "Storage.setCookies",
             %{"browserContextId" => browser_context_id, "cookies" => cookie_params},
             5_000
           ) do
      :ok
    end
  end

  @spec cookie_param(map()) :: map()
  defp cookie_param(cookie) do
    cookie
    |> Map.take([
      "name",
      "value",
      "url",
      "domain",
      "path",
      "secure",
      "httpOnly",
      "expires"
    ])
    |> drop_session_expiry()
  end

  @spec drop_session_expiry(map()) :: map()
  defp drop_session_expiry(%{"expires" => expires} = cookie) when expires < 0 do
    Map.delete(cookie, "expires")
  end

  defp drop_session_expiry(cookie), do: cookie

  @spec open_target(pid(), binary(), binary() | nil, keyword()) ::
          {:ok, Tab.t()} | {:error, term()}
  defp open_target(conn, target_url, browser_context_id, opts) do
    with {:ok, %{"targetId" => target_id}} <-
           Connection.send_command(
             conn,
             "Target.createTarget",
             create_target_params(target_url, browser_context_id)
           ),
         {:ok, %{"sessionId" => session_id}} <-
           Connection.send_command(conn, "Target.attachToTarget", %{
             targetId: target_id,
             flatten: true
           }),
         {:ok, _} <- cdp(conn, session_id, "Page.enable", %{}, 5_000),
         {:ok, _} <- cdp(conn, session_id, "DOM.enable", %{}, 5_000),
         {:ok, _} <- cdp(conn, session_id, "Runtime.enable", %{}, 5_000) do
      {:ok, build_tab(conn, target_id, session_id, browser_context_id, opts)}
    end
  end

  @spec create_target_params(binary(), binary() | nil) :: map()
  defp create_target_params(target_url, browser_context_id) do
    %{url: target_url}
    |> maybe_put("browserContextId", browser_context_id)
  end

  @spec build_tab(pid(), binary(), binary(), binary() | nil, keyword()) :: Tab.t()
  defp build_tab(conn, target_id, session_id, browser_context_id, opts) do
    %Tab{
      conn: conn,
      driver: opts[:driver] || SpectreLens.Protocol.LightpandaCDP,
      session_id: session_id,
      target_id: target_id,
      browser_context_id: browser_context_id,
      session_key: opts[:session_key],
      runtime: opts[:runtime],
      instance_id: opts[:instance_id],
      endpoint: opts[:endpoint]
    }
  end

  @spec close_target(Tab.t()) :: :ok | {:error, term()}
  defp close_target(%Tab{conn: conn, target_id: target_id}) do
    if target_id do
      case Connection.send_command(conn, "Target.closeTarget", %{targetId: target_id}, 5_000) do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
    else
      :ok
    end
  end

  @spec dispose_browser_context(pid(), binary() | nil) :: :ok | {:error, term()}
  defp dispose_browser_context(_conn, nil), do: :ok

  defp dispose_browser_context(conn, browser_context_id) do
    case Connection.send_command(
           conn,
           "Target.disposeBrowserContext",
           %{"browserContextId" => browser_context_id},
           5_000
         ) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @spec page_operation(Tab.t(), atom(), map(), (-> result)) :: result when result: term()
  defp page_operation(%Tab{} = tab, operation, metadata, fun)
       when is_atom(operation) and is_map(metadata) and is_function(fun, 0) do
    metadata =
      Map.merge(metadata, %{
        operation: operation,
        session_id: tab.session_id,
        target_id: tab.target_id
      })

    Telemetry.span([:spectre_lens, :page, :operation], metadata, fn ->
      result = fun.()
      span_result(result)
    end)
  end

  @spec page_step(Tab.t(), atom(), SpectreLens.PageMap.t()) :: map()
  defp page_step(tab, action, page_map) do
    %{
      action: action,
      session_id: tab.session_id,
      region_count: length(page_map.regions),
      summary: page_map.description
    }
  end

  @spec do_focus(Tab.t(), term(), keyword()) ::
          {:ok, SpectreLens.PageMap.t()} | {:error, term()}
  defp do_focus(tab, ref, opts) do
    case selector_for(ref) do
      nil ->
        {:error, SpectreLens.ElementNotFoundError.new(ref)}

      selector ->
        build_focused_map(tab, selector, opts)
    end
  end

  @spec build_focused_map(Tab.t(), binary(), keyword()) ::
          {:ok, SpectreLens.PageMap.t()} | {:error, term()}
  defp build_focused_map(tab, selector, opts) do
    with {:ok, regions} <- evaluate(tab, layout_script(selector, opts), opts) do
      result = build_page_map(regions, Keyword.put(opts, :focused?, true))
      Telemetry.emit([:spectre_lens, :page, :step], %{}, page_step(tab, :focus, result))
      {:ok, result}
    end
  end

  @spec form_submit_fun(Tab.t(), term(), non_neg_integer()) :: (-> {:ok, term()}
                                                                   | {:error, term()})
  defp form_submit_fun(tab, form_ref, timeout) do
    fn ->
      form_selector = selector_for(form_ref)
      evaluate(tab, form_submit_script(form_selector), timeout: timeout)
    end
  end

  @spec form_submit_script(binary() | nil) :: binary()
  defp form_submit_script(form_selector) do
    """
    (() => {
      const selector = #{Jason.encode!(form_selector)};
      const form = document.querySelector(selector);
      if (!form) throw new Error(`Form not found: ${selector}`);
      if (typeof form.requestSubmit === 'function') form.requestSubmit();
      else form.submit();
    })()
    """
  end

  @spec await_after((-> term()), reference(), non_neg_integer()) :: :ok | {:error, term()}
  defp await_after(fun, wait_ref, timeout) do
    case fun.() do
      {:error, _} = error -> error
      _ -> await_navigation_event(wait_ref, timeout)
    end
  end

  @spec await_navigation_event(reference(), non_neg_integer()) :: :ok | {:error, term()}
  defp await_navigation_event(wait_ref, timeout) do
    case Connection.await_event(wait_ref, timeout) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @spec maybe_wait_for_usable_document(pid(), binary(), keyword(), non_neg_integer()) ::
          :ok | {:error, term()}
  defp maybe_wait_for_usable_document(conn, sid, opts, timeout) do
    if Keyword.get(opts, :wait_for_content?, true) do
      interval = opts[:content_interval] || 100
      deadline = System.monotonic_time(:millisecond) + (opts[:content_timeout] || timeout)
      do_wait_for_usable_document(conn, sid, interval, deadline)
    else
      :ok
    end
  end

  @spec do_wait_for_usable_document(pid(), binary(), non_neg_integer(), integer(), map() | nil) ::
          :ok | {:error, term()}
  defp do_wait_for_usable_document(conn, sid, interval, deadline, last_state \\ nil) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    cond do
      remaining == 0 ->
        {:error, {:empty_document_after_navigation, last_state || %{}}}

      true ->
        case usable_document_state(conn, sid, min(remaining, 1_000)) do
          {:ok, %{"usable" => true}} ->
            :ok

          {:ok, state} ->
            Process.sleep(min(interval, remaining))
            do_wait_for_usable_document(conn, sid, interval, deadline, state)

          {:error, reason} ->
            Process.sleep(min(interval, remaining))
            do_wait_for_usable_document(conn, sid, interval, deadline, %{error: inspect(reason)})
        end
    end
  end

  @spec usable_document_state(pid(), binary(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  defp usable_document_state(conn, sid, timeout) do
    expression = """
    (() => {
      const root = document.documentElement;
      const body = document.body;
      const htmlLength = root ? root.outerHTML.length : 0;
      const childCount = root ? root.childElementCount : 0;
      const bodyTextLength = body ? (body.innerText || body.textContent || '').trim().length : 0;

      return {
        url: window.location.href,
        title: document.title,
        readyState: document.readyState,
        htmlLength,
        childCount,
        bodyTextLength,
        usable: !!root && childCount > 0 && htmlLength > 39
      };
    })()
    """

    with {:ok, payload} <-
           cdp(
             conn,
             sid,
             "Runtime.evaluate",
             %{expression: expression, returnByValue: true, awaitPromise: true},
             timeout
           ) do
      parse_evaluate_result(payload)
    end
  end

  @spec scroll_expression(keyword()) :: binary()
  defp scroll_expression(opts) do
    x = opts[:x] || 0
    y = opts[:y] || opts[:by] || 0

    case opts[:ref] || opts[:selector] do
      nil -> window_scroll_expression(x, y)
      ref -> element_scroll_expression(selector_for(ref), x, y)
    end
  end

  @spec window_scroll_expression(number(), number()) :: binary()
  defp window_scroll_expression(x, y) do
    "window.scrollBy(#{Jason.encode!(x)}, #{Jason.encode!(y)}); true"
  end

  @spec element_scroll_expression(binary() | nil, number(), number()) :: binary()
  defp element_scroll_expression(selector, x, y) do
    """
    (() => {
      const el = document.querySelector(#{Jason.encode!(selector)});
      if (!el) throw new Error('Element not found: #{selector}');
      el.scrollBy(#{Jason.encode!(x)}, #{Jason.encode!(y)});
      return true;
    })()
    """
  end

  @spec ok_result({:ok, term()} | {:error, term()}) :: :ok | {:error, term()}
  defp ok_result({:ok, _}), do: :ok
  defp ok_result({:error, _} = error), do: error

  @spec span_result(term()) :: term() | {term(), map()}
  defp span_result(:ok), do: :ok
  defp span_result(result), do: {result, %{result: result}}

  @spec current_origin(Tab.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  defp current_origin(tab, opts) do
    case evaluate(tab, "window.location.origin", opts) do
      {:ok, origin} when is_binary(origin) and origin not in ["", "null"] ->
        {:ok, origin}

      {:ok, _} ->
        with {:ok, url} <- url(tab) do
          {:error, {:opaque_origin, url}}
        end

      {:error, _} = error ->
        error
    end
  end

  @spec storage_snapshot_script() :: binary()
  defp storage_snapshot_script do
    """
    (() => {
      const copy = (storage) => {
        const entries = {};
        for (let index = 0; index < storage.length; index++) {
          const key = storage.key(index);
          entries[key] = storage.getItem(key);
        }
        return entries;
      };

      return {
        localStorage: copy(window.localStorage),
        sessionStorage: copy(window.sessionStorage)
      };
    })()
    """
  end

  @spec restore_storage_script(map(), map()) :: binary()
  defp restore_storage_script(local_storage, session_storage) do
    """
    (() => {
      const localStorageValues = #{Jason.encode!(local_storage)};
      const sessionStorageValues = #{Jason.encode!(session_storage)};

      window.localStorage.clear();
      for (const [key, value] of Object.entries(localStorageValues)) {
        window.localStorage.setItem(key, value);
      }

      window.sessionStorage.clear();
      for (const [key, value] of Object.entries(sessionStorageValues)) {
        window.sessionStorage.setItem(key, value);
      }

      return true;
    })()
    """
  end

  @spec restore_origin_storage(Tab.t(), map(), map(), keyword()) :: :ok | {:error, term()}
  defp restore_origin_storage(_tab, local_storage, session_storage, _opts)
       when map_size(local_storage) == 0 and map_size(session_storage) == 0,
       do: :ok

  defp restore_origin_storage(tab, local_storage, session_storage, opts) do
    with {:ok, _} <- evaluate(tab, restore_storage_script(local_storage, session_storage), opts) do
      maybe_reload_after_session_restore(tab, local_storage, session_storage, opts)
    end
  end

  @spec maybe_reload_after_session_restore(Tab.t(), map(), map(), keyword()) ::
          :ok | {:error, term()}
  defp maybe_reload_after_session_restore(tab, local_storage, session_storage, opts) do
    if Keyword.get(opts, :reload_after_session_restore?, true) do
      with :ok <- reload(tab, opts),
           {:ok, _} <- evaluate(tab, restore_storage_script(local_storage, session_storage), opts) do
        :ok
      end
    else
      :ok
    end
  end

  @spec reload(Tab.t(), keyword()) :: :ok | {:error, term()}
  defp reload(%Tab{conn: conn, session_id: sid}, opts) do
    timeout = opts[:timeout] || @navigation_timeout
    wait_ref = Connection.register_event_waiter(conn, "Page.loadEventFired", sid)

    with {:ok, _} <- Connection.send_command(conn, "Page.reload", %{}, timeout, sid),
         {:ok, _} <- Connection.await_event(wait_ref, timeout) do
      :ok
    end
  end

  @spec cdp(pid(), binary(), binary(), map(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  defp cdp(conn, sid, method, params, timeout) do
    Connection.send_command(conn, method, params, timeout, sid)
  end

  @spec node_id(Tab.t(), term(), non_neg_integer()) :: {:ok, integer()} | {:error, term()}
  defp node_id(_tab, node_id, _timeout) when is_integer(node_id), do: {:ok, node_id}

  defp node_id(tab, %SpectreLens.ActionRef{node_id: id}, timeout) when is_integer(id),
    do: node_id(tab, id, timeout)

  defp node_id(tab, %SpectreLens.ActionRef{selector: selector}, timeout) when is_binary(selector),
    do: node_id(tab, selector, timeout)

  defp node_id(tab, %SpectreLens.ActionRef{kind: :link, href: href}, timeout)
       when is_binary(href),
       do: link_node_id(tab, href, timeout)

  defp node_id(tab, %{"nodeId" => id}, timeout) when is_integer(id), do: node_id(tab, id, timeout)
  defp node_id(tab, %{"backendNodeId" => id}, timeout), do: backend_node_id(tab, id, timeout)
  defp node_id(tab, %{"backendDOMNodeId" => id}, timeout), do: backend_node_id(tab, id, timeout)

  defp node_id(tab, %{"selector" => selector}, timeout) when is_binary(selector),
    do: node_id(tab, selector, timeout)

  defp node_id(tab, %{"href" => href}, timeout), do: link_node_id(tab, href, timeout)

  defp node_id(%Tab{} = tab, selector, timeout) when is_binary(selector) do
    with {:ok, %{"root" => %{"nodeId" => root_id}}} <-
           command(tab, "DOM.getDocument", %{}, timeout: timeout),
         {:ok, %{"nodeId" => id}} <-
           command(tab, "DOM.querySelector", %{nodeId: root_id, selector: selector},
             timeout: timeout
           ) do
      if id == 0, do: {:error, SpectreLens.ElementNotFoundError.new(selector)}, else: {:ok, id}
    else
      {:error, %SpectreLens.CDPError{}} ->
        {:error, SpectreLens.ElementNotFoundError.new(selector)}

      {:error, _} = error ->
        error
    end
  end

  defp node_id(_tab, other, _timeout), do: {:error, SpectreLens.ElementNotFoundError.new(other)}

  @spec backend_node_id(Tab.t(), term(), non_neg_integer()) :: {:ok, integer()} | {:error, term()}
  defp backend_node_id(%Tab{} = tab, backend_node_id, timeout)
       when is_integer(backend_node_id) and backend_node_id > 0 do
    case command(
           tab,
           "DOM.pushNodesByBackendIdsToFrontend",
           %{"backendNodeIds" => [backend_node_id]},
           timeout: timeout
         ) do
      {:ok, %{"nodeIds" => [node_id | _]}} when is_integer(node_id) ->
        {:ok, node_id}

      {:ok, _} ->
        {:error, SpectreLens.ElementNotFoundError.new(%{"backendNodeId" => backend_node_id})}

      {:error, _} = error ->
        error
    end
  end

  defp backend_node_id(_tab, other, _timeout),
    do: {:error, SpectreLens.ElementNotFoundError.new(%{"backendNodeId" => other})}

  @spec link_node_id(Tab.t(), term(), non_neg_integer()) :: {:ok, integer()} | {:error, term()}
  defp link_node_id(%Tab{} = tab, href, timeout) when is_binary(href) do
    script = """
    (() => {
      const href = #{Jason.encode!(href)};
      const links = Array.from(document.querySelectorAll('a[href]'));
      const el = links.find((a) => a.href === href || a.getAttribute('href') === href);
      if (!el) return null;

      let token = el.getAttribute('data-spectre-lens-ref');
      if (!token) {
        token = `link-${Date.now()}-${Math.random().toString(36).slice(2)}`;
        el.setAttribute('data-spectre-lens-ref', token);
      }

      return `[data-spectre-lens-ref="${CSS.escape(token)}"]`;
    })()
    """

    case evaluate(tab, script, timeout: timeout) do
      {:ok, selector} when is_binary(selector) -> node_id(tab, selector, timeout)
      {:ok, _} -> {:error, SpectreLens.ElementNotFoundError.new(%{"href" => href})}
      {:error, _} = error -> error
    end
  end

  defp link_node_id(_tab, other, _timeout),
    do: {:error, SpectreLens.ElementNotFoundError.new(%{"href" => other})}

  @spec click_point(Tab.t(), integer(), non_neg_integer()) ::
          {:ok, {number(), number()}} | {:error, term()}
  defp click_point(tab, node_id, timeout) do
    with {:ok, %{"model" => %{"content" => [x1, y1, x2, y2, x3, y3, x4, y4]}}} <-
           command(tab, "DOM.getBoxModel", %{nodeId: node_id}, timeout: timeout) do
      {:ok, {Enum.sum([x1, x2, x3, x4]) / 4, Enum.sum([y1, y2, y3, y4]) / 4}}
    end
  end

  @spec dispatch_click(Tab.t(), number(), number(), non_neg_integer()) :: :ok | {:error, term()}
  defp dispatch_click(tab, x, y, timeout) do
    base = %{x: x, y: y, button: "left", clickCount: 1}

    with {:ok, _} <-
           command(tab, "Input.dispatchMouseEvent", Map.put(base, :type, "mousePressed"),
             timeout: timeout
           ),
         {:ok, _} <-
           command(tab, "Input.dispatchMouseEvent", Map.put(base, :type, "mouseReleased"),
             timeout: timeout
           ) do
      :ok
    end
  end

  @spec resolve_node(Tab.t(), integer(), non_neg_integer()) :: {:ok, binary()} | {:error, term()}
  defp resolve_node(tab, node_id, timeout) do
    with {:ok, %{"object" => %{"objectId" => object_id}}} <-
           command(tab, "DOM.resolveNode", %{nodeId: node_id}, timeout: timeout) do
      {:ok, object_id}
    end
  end

  @spec focus_element(Tab.t(), binary(), non_neg_integer()) :: :ok | {:error, term()}
  defp focus_element(tab, object_id, timeout) do
    call_on_element(tab, object_id, "function() { this.focus(); }", timeout)
  end

  @spec clear_element(Tab.t(), binary(), non_neg_integer()) :: :ok | {:error, term()}
  defp clear_element(tab, object_id, timeout) do
    call_on_element(
      tab,
      object_id,
      "function() { if ('value' in this) this.value = ''; this.textContent = this.isContentEditable ? '' : this.textContent; }",
      timeout
    )
  end

  @spec call_on_element(Tab.t(), binary(), binary(), non_neg_integer()) :: :ok | {:error, term()}
  defp call_on_element(tab, object_id, function, timeout) do
    with {:ok, _} <-
           command(
             tab,
             "Runtime.callFunctionOn",
             %{objectId: object_id, functionDeclaration: function},
             timeout: timeout
           ) do
      :ok
    end
  end

  @spec fill_fields(Tab.t(), map(), keyword()) :: :ok | {:error, term()}
  defp fill_fields(_tab, fields, _opts) when map_size(fields) == 0, do: :ok

  defp fill_fields(tab, fields, opts) do
    Enum.reduce_while(fields, :ok, fn {selector, value}, :ok ->
      case fill(tab, selector, to_string(value), opts) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @spec do_wait_for_selector(Tab.t(), binary(), non_neg_integer(), integer(), non_neg_integer()) ::
          :ok | {:error, term()}
  defp do_wait_for_selector(tab, selector, interval, deadline, timeout) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, SpectreLens.TimeoutError.new(operation: :wait_for_selector, timeout_ms: timeout)}
    else
      case node_id(tab, selector, 1_000) do
        {:ok, _} ->
          :ok

        {:error, _} ->
          Process.sleep(interval)
          do_wait_for_selector(tab, selector, interval, deadline, timeout)
      end
    end
  end

  @spec parse_evaluate_result(map()) :: {:ok, term()} | {:error, SpectreLens.JavaScriptError.t()}
  defp parse_evaluate_result(%{
         "exceptionDetails" => %{"exception" => %{"description" => description}}
       }) do
    {:error, SpectreLens.JavaScriptError.new(description)}
  end

  defp parse_evaluate_result(%{"exceptionDetails" => details}) do
    {:error, SpectreLens.JavaScriptError.new(inspect(details))}
  end

  defp parse_evaluate_result(%{"result" => %{"type" => "undefined"}}), do: {:ok, nil}
  defp parse_evaluate_result(%{"result" => %{"value" => value}}), do: {:ok, value}
  defp parse_evaluate_result(%{"result" => result}), do: {:ok, result["value"]}

  @spec semantic_tree_format(atom() | binary()) :: binary() | nil
  defp semantic_tree_format(:json), do: nil
  defp semantic_tree_format("json"), do: nil
  defp semantic_tree_format(:text), do: "text"
  defp semantic_tree_format(other), do: to_string(other)

  @spec selector_for(term()) :: binary() | nil
  defp selector_for(%SpectreLens.ActionRef{selector: selector}) when is_binary(selector),
    do: selector

  defp selector_for(%SpectreLens.ActionRef{}), do: nil
  defp selector_for(%{"selector" => selector}) when is_binary(selector), do: selector
  defp selector_for(selector) when is_binary(selector), do: selector
  defp selector_for(_other), do: nil

  @spec layout_script(binary() | nil, keyword()) :: binary()
  defp layout_script(selector, opts) do
    max_regions = opts[:max_regions] || 18

    scope =
      if selector, do: "document.querySelector(#{Jason.encode!(selector)})", else: "document.body"

    """
    (() => {
      const scope = #{scope};
      if (!scope) throw new Error('Scope not found: #{selector || "document.body"}');
      const maxRegions = #{Jason.encode!(max_regions)};
      const query = [
        'header', 'nav', 'main', 'aside', 'footer', 'section', 'article', 'form',
        '[role="navigation"]', '[role="banner"]', '[role="main"]', '[role="contentinfo"]',
        '[role="complementary"]', '[role="search"]', '[class*="hero" i]',
        '[class*="sidebar" i]', '[class*="gallery" i]', '[class*="contact" i]',
        '[class*="header" i]', '[class*="navbar" i]', '[class*="nav" i]',
        '[class*="newsletter" i]', '[class*="subscribe" i]', '[class*="pricing" i]'
      ].join(',');
      const candidates = Array.from(scope.querySelectorAll(query));
      if (scope !== document.body && scope !== document.documentElement) candidates.unshift(scope);
      if (candidates.length === 0) candidates.push(scope);

      const seen = new Set();
      const viewportWidth = window.innerWidth || document.documentElement.clientWidth || 0;
      const viewportHeight = window.innerHeight || document.documentElement.clientHeight || 0;
      const docHeight = Math.max(document.body.scrollHeight || 0, document.documentElement.scrollHeight || 0, viewportHeight);

      const clean = (text, max = 220) => (text || '').replace(/\\s+/g, ' ').trim().slice(0, max);

      function cssPath(el) {
        if (!el || el === document.body) return 'body';
        if (el.id) return `#${CSS.escape(el.id)}`;
        const parts = [];
        let node = el;
        while (node && node.nodeType === 1 && node !== document.body && parts.length < 4) {
          let part = node.tagName.toLowerCase();
          const parent = node.parentElement;
          if (parent) {
            const siblings = Array.from(parent.children).filter(child => child.tagName === node.tagName);
            if (siblings.length > 1) part += `:nth-of-type(${siblings.indexOf(node) + 1})`;
          }
          parts.unshift(part);
          node = parent;
        }
        return parts.join(' > ');
      }

      function roleOf(el) {
        const tag = el.tagName.toLowerCase();
        const role = el.getAttribute('role');
        if (role) return role;
        if (tag === 'header') return 'banner';
        if (tag === 'nav') return 'navigation';
        if (tag === 'main') return 'main';
        if (tag === 'aside') return 'complementary';
        if (tag === 'footer') return 'contentinfo';
        if (tag === 'form') return 'form';
        if (tag === 'article') return 'article';
        return tag;
      }

      function labelOf(el) {
        const heading = el.querySelector('h1,h2,h3,[role="heading"]');
        return clean(el.getAttribute('aria-label') || el.getAttribute('data-title') || (heading && heading.textContent) || '', 120);
      }

      function positionOf(rect, order, total) {
        if (!rect || (rect.width === 0 && rect.height === 0 && rect.top === 0)) {
          if (order === 0) return 'at the start of the page';
          if (order >= total - 2) return 'near the end of the page';
          return 'in the middle flow of the page';
        }
        const centerX = rect.left + rect.width / 2;
        const centerY = window.scrollY + rect.top + rect.height / 2;
        const horizontal = viewportWidth && centerX < viewportWidth * 0.34 ? 'left' : viewportWidth && centerX > viewportWidth * 0.66 ? 'right' : 'center';
        const vertical = docHeight && centerY < docHeight * 0.25 ? 'top' : docHeight && centerY > docHeight * 0.75 ? 'bottom' : 'middle';
        return horizontal === 'center' ? `${vertical} of the page` : `${vertical} ${horizontal} of the page`;
      }

      function purposeOf(el, role, label, stats, order) {
        const haystack = `${el.tagName} ${role} ${label} ${el.id} ${el.className}`.toLowerCase();
        if (role === 'navigation' || el.tagName.toLowerCase() === 'nav') return 'navigation';
        if (role === 'contentinfo' || el.tagName.toLowerCase() === 'footer') return 'footer';
        if (role === 'complementary' || el.tagName.toLowerCase() === 'aside' || haystack.includes('sidebar')) return 'sidebar';
        if (role === 'form' || el.tagName.toLowerCase() === 'form') {
          if (haystack.includes('contact') || label.includes('contact')) return 'contact_form';
          if (haystack.includes('search')) return 'search_form';
          return 'form';
        }
        if (haystack.includes('hero') || el.querySelector('h1') || (order === 0 && stats.headings > 0)) return 'hero';
        if (stats.fields > 0 || haystack.includes('newsletter') || haystack.includes('subscribe')) return 'form';
        if (haystack.includes('gallery') || stats.images >= 3) return 'gallery';
        if (stats.links >= 5 && stats.textLength < 500) return 'link_collection';
        return 'content_section';
      }

      return candidates
        .filter(el => {
          if (seen.has(el)) return false;
          seen.add(el);
          const text = clean(el.innerText || el.textContent || '', 40);
          return text || el.querySelector('a,button,input,textarea,select,img,form');
        })
        .slice(0, maxRegions)
        .map((el, index, all) => {
          const rect = el.getBoundingClientRect ? el.getBoundingClientRect() : null;
          const links = Array.from(el.querySelectorAll('a[href]')).slice(0, 8).map(a => ({text: clean(a.innerText || a.textContent, 80), href: a.href}));
          const fields = Array.from(el.querySelectorAll('input,textarea,select')).slice(0, 12).map(field => ({
            tag: field.tagName.toLowerCase(),
            type: field.getAttribute('type') || field.tagName.toLowerCase(),
            name: field.getAttribute('name') || field.id || null,
            label: clean(field.getAttribute('aria-label') || field.getAttribute('placeholder') || (field.labels && field.labels[0] && field.labels[0].innerText) || field.getAttribute('name') || field.id || '', 80)
          }));
          const stats = {
            links: links.length,
            fields: fields.length,
            images: el.querySelectorAll('img,picture').length,
            buttons: el.querySelectorAll('button,[role="button"]').length,
            headings: el.querySelectorAll('h1,h2,h3,[role="heading"]').length,
            textLength: clean(el.innerText || el.textContent || '', 2000).length
          };
          const role = roleOf(el);
          const label = labelOf(el);
          return {
            id: `r${index + 1}`,
            kind: role,
            purpose: purposeOf(el, role, label.toLowerCase(), stats, index),
            label,
            position: positionOf(rect, index, all.length),
            text: clean(el.innerText || el.textContent || '', 260),
            selector: cssPath(el),
            links,
            fields,
            stats
          };
        });
    })()
    """
  end

  @spec build_page_map(term(), keyword()) :: SpectreLens.PageMap.t()
  defp build_page_map(raw_regions, opts) do
    regions =
      raw_regions
      |> List.wrap()
      |> Enum.map(&region_from_map/1)

    %SpectreLens.PageMap{
      description: describe_regions(regions, opts),
      regions: regions,
      warnings: [],
      source: :dom
    }
  end

  @spec region_from_map(map()) :: SpectreLens.Region.t()
  defp region_from_map(region) when is_map(region) do
    %SpectreLens.Region{
      id: get_any(region, "id"),
      kind: normalize_known_atom(get_any(region, "kind"), :section),
      purpose: normalize_known_atom(get_any(region, "purpose"), :content_section),
      label: blank_to_nil(get_any(region, "label")),
      position: blank_to_nil(get_any(region, "position")),
      text: blank_to_nil(get_any(region, "text")),
      selector: blank_to_nil(get_any(region, "selector")),
      links: get_any(region, "links", []),
      fields: get_any(region, "fields", []),
      stats: get_any(region, "stats", %{})
    }
  end

  @spec describe_regions([SpectreLens.Region.t()], keyword()) :: binary()
  defp describe_regions([], _opts), do: "The page has no clear semantic regions."

  defp describe_regions(regions, opts) do
    intro =
      if opts[:focused?],
        do: "Zoomed in, this area is organized as follows:",
        else: "Zoomed out, the page is organized as follows:"

    intro <> " " <> Enum.map_join(regions, " Then ", &describe_region/1)
  end

  @spec describe_region(SpectreLens.Region.t()) :: binary()
  defp describe_region(region) do
    subject =
      case region.label do
        nil -> purpose_name(region)
        label -> "#{purpose_name(region)} labeled #{inspect(label)}"
      end

    details =
      [
        region.position && "positioned #{region.position}",
        link_summary(region.links),
        field_summary(region.fields),
        image_summary(region.stats),
        text_summary(region.text)
      ]
      |> Enum.reject(&is_nil/1)

    if details == [] do
      "there is a #{subject}."
    else
      "there is a #{subject}, " <> Enum.join(details, ", ") <> "."
    end
  end

  @spec purpose_name(SpectreLens.Region.t()) :: binary()
  defp purpose_name(%{purpose: :navigation}), do: "navigation bar"
  defp purpose_name(%{purpose: :hero}), do: "hero or intro section"
  defp purpose_name(%{purpose: :sidebar}), do: "sidebar"
  defp purpose_name(%{purpose: :gallery}), do: "gallery section"
  defp purpose_name(%{purpose: :contact_form}), do: "contact form"
  defp purpose_name(%{purpose: :search_form}), do: "search form"
  defp purpose_name(%{purpose: :form}), do: "form"
  defp purpose_name(%{purpose: :footer}), do: "footer"
  defp purpose_name(%{purpose: :link_collection}), do: "link collection"
  defp purpose_name(_region), do: "content section"

  @spec link_summary([map()]) :: binary() | nil
  defp link_summary([]), do: nil

  defp link_summary(links) do
    labels =
      links
      |> Enum.map(&(get_any(&1, "text") || get_any(&1, "href")))
      |> Enum.reject(&blank?/1)
      |> Enum.take(5)

    if labels == [], do: "#{length(links)} links", else: "with links: #{Enum.join(labels, ", ")}"
  end

  @spec field_summary([map()]) :: binary() | nil
  defp field_summary([]), do: nil

  defp field_summary(fields) do
    labels =
      fields
      |> Enum.map(&(get_any(&1, "label") || get_any(&1, "name") || get_any(&1, "type")))
      |> Enum.reject(&blank?/1)
      |> Enum.take(6)

    "with fields: #{Enum.join(labels, ", ")}"
  end

  @spec image_summary(map()) :: binary() | nil
  defp image_summary(stats) do
    case get_any(stats, "images", 0) do
      count when is_integer(count) and count >= 3 -> "with #{count} images"
      _ -> nil
    end
  end

  @spec text_summary(binary() | nil) :: binary() | nil
  defp text_summary(nil), do: nil

  defp text_summary(text) do
    text = String.trim(text)
    if text == "", do: nil, else: ~s(with text starting "#{String.slice(text, 0, 120)}")
  end

  @spec get_any(map(), binary(), term()) :: term()
  defp get_any(map, key, default \\ nil)

  defp get_any(map, key, default) when is_map(map),
    do: Map.get(map, key) || Map.get(map, known_atom_key(key), default)

  defp get_any(_other, _key, default), do: default

  @spec known_atom_key(binary()) :: atom() | nil
  defp known_atom_key("fields"), do: :fields
  defp known_atom_key("id"), do: :id
  defp known_atom_key("images"), do: :images
  defp known_atom_key("kind"), do: :kind
  defp known_atom_key("label"), do: :label
  defp known_atom_key("links"), do: :links
  defp known_atom_key("position"), do: :position
  defp known_atom_key("purpose"), do: :purpose
  defp known_atom_key("selector"), do: :selector
  defp known_atom_key("stats"), do: :stats
  defp known_atom_key("text"), do: :text
  defp known_atom_key(_key), do: nil

  @spec normalize_known_atom(term(), atom()) :: atom()
  defp normalize_known_atom(value, _default) when is_atom(value), do: value

  defp normalize_known_atom(value, default) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
    |> String.trim("_")
    |> known_region_atom(default)
  end

  defp normalize_known_atom(_value, default), do: default

  @spec known_region_atom(binary(), atom()) :: atom()
  defp known_region_atom("article", _default), do: :article
  defp known_region_atom("banner", _default), do: :banner
  defp known_region_atom("complementary", _default), do: :complementary
  defp known_region_atom("contact_form", _default), do: :contact_form
  defp known_region_atom("content_section", _default), do: :content_section
  defp known_region_atom("contentinfo", _default), do: :contentinfo
  defp known_region_atom("footer", _default), do: :footer
  defp known_region_atom("form", _default), do: :form
  defp known_region_atom("gallery", _default), do: :gallery
  defp known_region_atom("hero", _default), do: :hero
  defp known_region_atom("link_collection", _default), do: :link_collection
  defp known_region_atom("main", _default), do: :main
  defp known_region_atom("navigation", _default), do: :navigation
  defp known_region_atom("search_form", _default), do: :search_form
  defp known_region_atom("section", _default), do: :section
  defp known_region_atom("sidebar", _default), do: :sidebar
  defp known_region_atom(_value, default), do: default

  @spec blank_to_nil(term()) :: term() | nil
  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(value), do: value

  @spec blank?(term()) :: boolean()
  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  @spec maybe_put(map(), term(), term()) :: map()
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
