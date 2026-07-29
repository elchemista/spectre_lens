defmodule SpectreLens.PageCDPContractTest do
  use ExUnit.Case, async: true

  alias SpectreLens.ActionRef
  alias SpectreLens.CDP.RequestGuard
  alias SpectreLens.Page
  alias SpectreLens.PageMap
  alias SpectreLens.Protocol.CDP
  alias SpectreLens.Protocol.Lightpanda
  alias SpectreLens.Session
  alias SpectreLens.TestCDP

  setup do
    {:ok, conn} = TestCDP.start(owner: self())
    instance = %{id: 7, endpoint: "test://browser", connection: conn}

    assert {:ok, tab} =
             CDP.new_tab(instance,
               network_policy: :public,
               allowed_ports: [80, 443]
             )

    on_exit(fn ->
      RequestGuard.stop(tab.request_guard)
      if Process.alive?(conn), do: GenServer.stop(conn)
    end)

    %{conn: conn, instance: instance, tab: tab}
  end

  test "generic CDP projections return browser-neutral values", %{tab: tab} do
    assert tab.protocol == CDP
    assert tab.instance_id == 7
    assert tab.endpoint == "test://browser"
    assert is_binary(tab.id)
    assert is_pid(tab.request_guard)

    assert {:ok, %{"echo" => "ok"}} =
             TestCDP.queue_reply(tab.conn, "Test.echo", {:ok, %{"echo" => "ok"}})
             |> then(fn :ok -> CDP.command(tab, "Test.echo", %{}, []) end)

    assert :ok =
             CDP.navigate(tab, "https://example.com/page",
               timeout: 100,
               wait_for_content?: false
             )

    assert {:ok, true} = CDP.evaluate(tab, "1 + 1", [])
    assert {:ok, "https://example.com/page"} = CDP.url(tab)
    assert {:ok, "Example title"} = CDP.title(tab)
    assert {:ok, "<html><body>Example</body></html>"} = CDP.html(tab, [])
    assert {:ok, "# Example\n\nBody"} = CDP.markdown(tab, [])

    assert {:ok, %{"nodes" => nodes}} = CDP.semantic_tree(tab, [])
    assert length(nodes) == 2

    assert {:ok, text_tree} = CDP.semantic_tree(tab, format: :text)
    assert text_tree =~ "[1] heading: Example"
    assert text_tree =~ "[2] button"

    assert {:ok, [%{"name" => "Save"}]} = CDP.interactive_elements(tab, [])
    assert {:ok, %{"json_ld" => [%{"@type" => "Article"}]}} = CDP.structured_data(tab, [])
    assert {:ok, [%{"text" => "Docs"}]} = CDP.links(tab, [])
    assert {:ok, [%{"id" => "search"}]} = CDP.forms(tab, [])

    assert {:ok, "png-bytes"} =
             CDP.screenshot(tab,
               format: :png,
               quality: 80,
               capture_beyond_viewport: true
             )

    assert {:ok, "pdf-bytes"} =
             CDP.pdf(tab,
               print_background: false,
               landscape: true,
               paper_width: 8.5,
               paper_height: 11
             )
  end

  test "page maps turn raw DOM evidence into bounded agent descriptions", %{tab: tab} do
    assert {:ok, %PageMap{} = page_map} = CDP.page_map(tab, max_regions: 20)
    assert length(page_map.regions) == 11
    assert page_map.trust == :untrusted
    assert page_map.source == :dom
    assert page_map.description =~ "navigation bar"
    assert page_map.description =~ "hero or intro section"
    assert page_map.description =~ "contact form"
    assert page_map.description =~ "with 4 images"
    assert page_map.description =~ "with fields: Email, message, submit"

    assert {:ok, %PageMap{} = focused} = CDP.focus(tab, "#region-4", max_regions: 4)
    assert focused.description =~ "Zoomed in, this area is organized as follows"

    assert {:ok, %PageMap{} = focused_from_ref} =
             CDP.focus(tab, %ActionRef{selector: "#region-4"}, [])

    assert focused_from_ref.regions != []

    assert {:error, %SpectreLens.ElementNotFoundError{}} =
             CDP.focus(tab, %ActionRef{kind: :button}, [])

    assert {:error, %SpectreLens.ElementNotFoundError{}} = CDP.focus(tab, %{bad: :ref}, [])
  end

  test "interactions resolve portable refs and keep navigation waits ordered", %{tab: tab} do
    assert :ok = CDP.click(tab, 42, [])
    assert :ok = CDP.click(tab, %ActionRef{node_id: 42}, [])
    assert :ok = CDP.click(tab, %ActionRef{selector: "#save"}, [])
    assert :ok = CDP.click(tab, %{"nodeId" => 42}, [])
    assert :ok = CDP.click(tab, %{"backendNodeId" => 200}, [])
    assert :ok = CDP.click(tab, %{"backendDOMNodeId" => 201}, [])
    assert :ok = CDP.click(tab, %{"selector" => "#save"}, [])
    assert :ok = CDP.click(tab, %{"href" => "/docs"}, [])
    assert :ok = CDP.click(tab, %ActionRef{kind: :link, href: "/docs"}, [])

    assert :ok = CDP.fill(tab, "#email", "agent@example.com", [])

    assert :ok =
             CDP.submit(
               tab,
               "#search",
               %{"#q" => "spectre", "#page" => 2},
               timeout: 100
             )

    assert :ok = CDP.wait_for_selector(tab, "#save", timeout: 10, interval: 0)

    assert :ok =
             CDP.wait_for_navigation(
               tab,
               fn ->
                 CDP.command(tab, "Page.navigate", %{url: "https://example.com/next"}, [])
               end,
               timeout: 100
             )

    assert :ok = CDP.scroll(tab, x: 10, by: 200)
    assert :ok = CDP.scroll(tab, ref: "#panel", x: 1, y: 2)
    assert :ok = CDP.scroll(tab, selector: "#panel", by: 3)

    assert {:error, %SpectreLens.ElementNotFoundError{}} = CDP.click(tab, :bad_ref, [])
    assert {:error, %SpectreLens.ElementNotFoundError{}} = CDP.click(tab, "#missing", [])

    assert {:error, %SpectreLens.ElementNotFoundError{}} =
             CDP.click(tab, %{"backendNodeId" => 0}, [])
  end

  test "session context creation, capture, and restore stay portable", %{
    conn: conn,
    instance: instance,
    tab: tab
  } do
    session =
      Session.new(
        cookies: [
          %{
            "name" => "sid",
            "value" => "secret",
            "domain" => "example.com",
            "path" => "/",
            "expires" => -1,
            "sameSite" => "ignored"
          }
        ],
        local_storage: %{"https://example.com" => %{"theme" => "dark"}},
        session_storage: %{"https://example.com" => %{"step" => "1"}}
      )

    assert {:ok, context_tab} =
             CDP.new_tab(instance,
               session_key: :work,
               session_snapshot: session,
               url: "https://example.com/app",
               network_policy: :any,
               wait_for_content?: false,
               timeout: 100
             )

    assert context_tab.browser_context_id == "context-1"
    assert context_tab.session_key == :work

    cookie_command =
      conn
      |> TestCDP.commands()
      |> Enum.find(&(&1.method == "Storage.setCookies"))

    [cookie] = cookie_command.params["cookies"]
    refute Map.has_key?(cookie, "expires")
    refute Map.has_key?(cookie, "sameSite")

    assert {:ok, captured} = CDP.capture_session(context_tab, [])
    assert captured.cookies == [%{"name" => "sid", "value" => "secret"}]
    assert captured.local_storage == %{"https://example.com" => %{"theme" => "dark"}}
    assert captured.session_storage == %{"https://example.com" => %{"step" => "2"}}

    assert :ok =
             CDP.restore_session(context_tab, session, reload_after_session_restore?: false)

    assert :ok = CDP.restore_session(context_tab, Session.new(), [])
    assert :ok = CDP.restore_session(context_tab, Session.to_map(session), timeout: 100)

    assert {:error, :missing_browser_context} = Page.session_snapshot(tab)
    assert :ok = CDP.close_tab(context_tab)
  end

  test "Lightpanda enrichments fall back only for an unsupported native CDP method", %{
    conn: conn,
    instance: instance,
    tab: generic_tab
  } do
    tab = %{generic_tab | protocol: Lightpanda}

    assert {:ok, "# Native"} = Lightpanda.markdown(tab, node_id: 1, backend_node_id: 2)
    assert {:ok, %{"role" => "main"}} = Lightpanda.semantic_tree(tab, format: :json, prune: true)
    assert {:ok, %{"role" => "main"}} = Lightpanda.semantic_tree(tab, format: "text")
    assert {:ok, [%{"name" => "Save"}]} = Lightpanda.interactive_elements(tab, [])
    assert {:ok, %{"title" => "Example"}} = Lightpanda.structured_data(tab, [])

    :ok = TestCDP.queue_reply(conn, "LP.getMarkdown", {:error, -32_601, "method missing"})
    assert {:ok, "# Example\n\nBody"} = Lightpanda.markdown(tab, [])

    assert :ok = Lightpanda.navigate(tab, "https://example.com", wait_for_content?: false)
    assert {:ok, true} = Lightpanda.evaluate(tab, "true", [])
    assert {:ok, "https://example.com/page"} = Lightpanda.url(tab)
    assert {:ok, "Example title"} = Lightpanda.title(tab)
    assert {:ok, "<html><body>Example</body></html>"} = Lightpanda.html(tab, [])
    assert {:ok, %PageMap{}} = Lightpanda.page_map(tab, [])
    assert {:ok, %PageMap{}} = Lightpanda.focus(tab, "#region-1", [])
    assert {:ok, [_]} = Lightpanda.links(tab, [])
    assert {:ok, [_]} = Lightpanda.forms(tab, [])
    assert {:ok, "png-bytes"} = Lightpanda.screenshot(tab, [])
    assert {:ok, "pdf-bytes"} = Lightpanda.pdf(tab, [])
    assert :ok = Lightpanda.click(tab, 42, [])
    assert :ok = Lightpanda.fill(tab, 42, "value", [])

    assert :ok =
             Lightpanda.submit(tab, "#search", %{}, timeout: 100)

    assert :ok = Lightpanda.wait_for_selector(tab, "#save", timeout: 10, interval: 0)

    assert :ok =
             Lightpanda.wait_for_navigation(
               tab,
               fn -> Lightpanda.command(tab, "Page.reload", %{}, []) end,
               timeout: 100
             )

    assert :ok = Lightpanda.scroll(tab, by: 10)
    assert {:ok, %Session{}} = Lightpanda.capture_session(%{tab | browser_context_id: "ctx"}, [])
    assert :ok = Lightpanda.restore_session(tab, Session.new(), [])
    assert Lightpanda.tab_key(tab) == {:target, tab.target_id}

    assert :ok = Lightpanda.subscribe(instance, self())
    assert Lightpanda.handle_info(:other, instance) == :ignore
  end

  test "malformed browser replies become typed errors instead of crashes", %{conn: conn, tab: tab} do
    :ok =
      TestCDP.queue_reply(
        conn,
        "Runtime.evaluate",
        {:ok,
         %{
           "exceptionDetails" => %{
             "exception" => %{"description" => "ReferenceError: missing"}
           }
         }}
      )

    assert {:error, %SpectreLens.JavaScriptError{message: "ReferenceError: missing"}} =
             CDP.evaluate(tab, "missing()", [])

    :ok =
      TestCDP.queue_reply(
        conn,
        "Runtime.evaluate",
        {:ok, %{"exceptionDetails" => %{"text" => "bad script"}}}
      )

    assert {:error, %SpectreLens.JavaScriptError{}} = CDP.evaluate(tab, "bad()", [])

    :ok =
      TestCDP.queue_reply(
        conn,
        "Runtime.evaluate",
        {:ok, %{"result" => %{"type" => "undefined"}}}
      )

    assert {:ok, nil} = CDP.evaluate(tab, "undefined", [])

    :ok = TestCDP.queue_reply(conn, "Page.printToPDF", {:ok, %{"unexpected" => true}})
    assert {:error, %SpectreLens.UnsupportedError{}} = CDP.pdf(tab, [])

    :ok = TestCDP.queue_reply(conn, "Page.printToPDF", {:error, -1, "printing disabled"})
    assert {:error, %SpectreLens.UnsupportedError{}} = CDP.pdf(tab, [])

    :ok = TestCDP.queue_reply(conn, "Page.captureScreenshot", {:ok, %{"data" => "not-base64"}})
    assert {:error, _reason} = CDP.screenshot(tab, [])

    :ok = TestCDP.queue_reply(conn, "DOM.pushNodesByBackendIdsToFrontend", {:ok, %{}})

    assert {:error, %SpectreLens.ElementNotFoundError{}} =
             CDP.click(tab, %{"backendNodeId" => 999}, [])

    :ok = TestCDP.queue_reply(conn, "DOM.querySelector", {:error, -1, "DOM failure"})
    assert {:error, %SpectreLens.ElementNotFoundError{}} = CDP.click(tab, "#save", [])
  end

  test "failed target setup cleans every partially allocated resource", %{
    conn: conn,
    instance: instance
  } do
    :ok = TestCDP.queue_reply(conn, "Target.createTarget", {:error, -1, "cannot create"})

    assert {:error, %SpectreLens.CDPError{method: "Target.createTarget"}} =
             CDP.new_tab(instance, session_key: :failed, session_snapshot: Session.new())

    :ok = TestCDP.queue_reply(conn, "Target.attachToTarget", {:error, -2, "cannot attach"})

    assert {:error, %SpectreLens.CDPError{method: "Target.attachToTarget"}} =
             CDP.new_tab(instance, [])

    :ok = TestCDP.queue_reply(conn, "Fetch.enable", {:error, -3, "fetch unavailable"})

    assert {:error, {:request_guard_unavailable, %SpectreLens.CDPError{}}} =
             CDP.new_tab(instance, [])

    :ok = TestCDP.queue_reply(conn, "Page.navigate", {:error, -4, "navigation rejected"})

    assert {:error, %SpectreLens.CDPError{method: "Page.navigate"}} =
             CDP.new_tab(instance,
               url: "https://example.com",
               network_policy: :any,
               wait_for_content?: false
             )

    commands = TestCDP.commands(conn)
    assert Enum.any?(commands, &(&1.method == "Target.closeTarget"))
    assert Enum.any?(commands, &(&1.method == "Target.disposeBrowserContext"))
  end

  test "Page default arities preserve the same complete browser contract", %{
    conn: conn,
    tab: tab
  } do
    assert {:ok, extra} = Page.new(conn)

    assert {:ok, %{}} = Page.command(tab, "Runtime.enable")
    assert :ok = Page.navigate(tab, "https://example.com/defaults")
    assert {:ok, true} = Page.evaluate(tab, "true")
    assert {:ok, "https://example.com/page"} = Page.url(tab)
    assert {:ok, "Example title"} = Page.title(tab)
    assert {:ok, "<html><body>Example</body></html>"} = Page.html(tab)
    assert {:ok, "# Example\n\nBody"} = Page.markdown(tab)
    assert {:ok, %{"nodes" => [_ | _]}} = Page.semantic_tree(tab)
    assert {:ok, [%{"name" => "Save"}]} = Page.interactive_elements(tab)
    assert {:ok, %{"json_ld" => [_]}} = Page.structured_data(tab)
    assert {:ok, %PageMap{}} = Page.page_map(tab)
    assert {:ok, %PageMap{}} = Page.focus(tab, "#region-1")
    assert {:ok, [%{"text" => "Docs"}]} = Page.links(tab)
    assert {:ok, [%{"id" => "search"}]} = Page.forms(tab)
    assert {:ok, "png-bytes"} = Page.screenshot(tab)
    assert {:ok, "pdf-bytes"} = Page.pdf(tab)
    assert :ok = Page.click(tab, 42)
    assert :ok = Page.fill(tab, 42, "value")
    assert :ok = Page.submit(tab, "#search")
    assert :ok = Page.wait_for_selector(tab, "#save")

    assert :ok =
             Page.wait_for_navigation(tab, fn ->
               Page.command(tab, "Page.reload")
             end)

    assert :ok = Page.scroll(tab)
    assert :ok = Page.restore_session(tab, Session.new())

    assert {:ok, %Session{}} =
             Page.session_snapshot(%{tab | browser_context_id: "context-default"})

    assert :ok = Page.target_closed(extra)
  end

  test "Page converts polling, lookup and session edge cases into stable errors", %{
    conn: conn,
    tab: tab
  } do
    :ok =
      TestCDP.queue_reply(
        conn,
        "Runtime.evaluate",
        {:ok, %{"result" => %{"description" => "remote object"}}}
      )

    assert {:ok, nil} = Page.evaluate(tab, "remoteObject()")

    assert {:error, %SpectreLens.TimeoutError{operation: :wait_for_selector}} =
             Page.wait_for_selector(tab, "#missing", timeout: 0, interval: 0)

    assert {:error, :action_failed} =
             Page.wait_for_navigation(
               tab,
               fn -> {:error, :action_failed} end,
               timeout: 10
             )

    :ok =
      TestCDP.queue_reply(
        conn,
        "Runtime.evaluate",
        {:ok, %{"result" => %{"value" => nil}}}
      )

    assert {:error, %SpectreLens.ElementNotFoundError{}} =
             Page.click(tab, %{"href" => "/missing"}, [])

    :ok = TestCDP.queue_reply(conn, "Runtime.evaluate", {:error, -1, "evaluation failed"})

    assert {:error, %SpectreLens.CDPError{}} =
             Page.click(tab, %{"href" => "/failed"}, [])

    assert {:error, %SpectreLens.ElementNotFoundError{}} =
             Page.click(tab, %{"backendNodeId" => "bad"}, [])

    assert {:error, %SpectreLens.ElementNotFoundError{}} =
             Page.click(tab, %{unknown: :ref}, [])

    assert {:error, %SpectreLens.ElementNotFoundError{}} =
             Page.submit(tab, "#search", %{"#missing" => "value"},
               timeout: 100,
               interval: 0
             )

    opaque = Session.new(local_storage: %{"https://example.com" => %{"theme" => "dark"}})

    :ok =
      TestCDP.queue_reply(
        conn,
        "Runtime.evaluate",
        {:ok, %{"result" => %{"value" => "null"}}}
      )

    assert {:error, {:opaque_origin, "https://example.com/page"}} =
             Page.restore_session(tab, opaque)

    :ok = TestCDP.queue_reply(conn, "Runtime.evaluate", {:error, -2, "origin unavailable"})

    assert {:error, %SpectreLens.CDPError{}} =
             Page.restore_session(tab, opaque)

    assert {:error, :missing_browser_context} =
             Page.session_snapshot(%{tab | browser_context_id: nil})
  end

  test "Page cleanup reports target errors before context errors", %{conn: conn, tab: tab} do
    closing = %{tab | target_id: "closing", browser_context_id: "context-closing"}

    :ok = TestCDP.queue_reply(conn, "Target.closeTarget", {:error, -1, "target close failed"})

    :ok =
      TestCDP.queue_reply(
        conn,
        "Target.disposeBrowserContext",
        {:error, -2, "context close failed"}
      )

    assert {:error, %SpectreLens.CDPError{method: "Target.closeTarget"}} =
             Page.close(closing)

    context_only = %{tab | target_id: nil, browser_context_id: "context-only"}

    :ok =
      TestCDP.queue_reply(
        conn,
        "Target.disposeBrowserContext",
        {:error, -3, "context close failed"}
      )

    assert {:error, %SpectreLens.CDPError{method: "Target.disposeBrowserContext"}} =
             Page.close(context_only)

    assert :ok = Page.close(%{tab | target_id: nil, browser_context_id: nil})
  end

  test "session context creation normalizes cookies and disposes invalid snapshots", %{conn: conn} do
    session =
      Session.new(
        cookies: [
          %{
            "name" => "session",
            "value" => "one",
            "domain" => "example.com",
            "expires" => -1,
            "ignored" => "secret"
          },
          %{
            "name" => "persistent",
            "value" => "two",
            "domain" => "example.com",
            "expires" => 2_000_000_000
          }
        ]
      )

    assert {:ok, tab} =
             Page.new(conn,
               session_key: :login,
               session_snapshot: session,
               network_policy: :any
             )

    set_cookies =
      conn
      |> TestCDP.commands()
      |> Enum.find(&(&1.method == "Storage.setCookies"))

    assert [
             %{"name" => "session", "value" => "one", "domain" => "example.com"},
             %{
               "name" => "persistent",
               "value" => "two",
               "domain" => "example.com",
               "expires" => 2_000_000_000
             }
           ] = set_cookies.params["cookies"]

    assert :ok = Page.close(tab)

    assert {:error, :invalid_session} =
             Page.new(conn,
               session_key: :invalid,
               session_snapshot: :invalid,
               network_policy: :any
             )

    assert Enum.any?(TestCDP.commands(conn), &(&1.method == "Target.disposeBrowserContext"))
  end
end
