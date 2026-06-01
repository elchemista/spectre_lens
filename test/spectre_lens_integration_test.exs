defmodule SpectreLensIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @real_content_pages [
    {"https://google.com", "google.com"},
    {"https://www.paginebianche.it/aziende?qs=IT&dv=Italia", "paginebianche.it"},
    {"https://filmix.my/", "filmix.my"},
    {"https://www.paginegialle.it/supermercati-aperti", "paginegialle.it"}
  ]
  @real_content_timeout 90_000

  test "opens a runtime, navigates, and exports markdown when Lightpanda is available" do
    assert {:ok, _path} = SpectreLens.Lightpanda.detect()
    assert {:ok, lens} = SpectreLens.open(instances: 1)

    try do
      assert {:ok, tab} = SpectreLens.new_tab(lens, url: "https://example.com")
      assert {:ok, view} = SpectreLens.look(tab, include: [:markdown, :semantic_tree, :links])
      assert view.url =~ "example.com"
      assert is_binary(view.markdown)
      assert is_map(view.semantic_tree)
    after
      SpectreLens.close(lens)
    end
  end

  test "ignores max_tabs_per_instance for Lightpanda and reports tab capacity" do
    assert {:ok, _path} = SpectreLens.Lightpanda.detect()
    assert {:ok, lens} = SpectreLens.open(instances: 1, max_tabs_per_instance: 8)

    try do
      assert {:ok, _tab} = SpectreLens.new_tab(lens, url: "https://example.com")

      assert {:error, :tab_capacity_exceeded} =
               SpectreLens.new_tab(lens, url: "https://elchemista.com")
    after
      SpectreLens.close(lens)
    end
  end

  test "balances concurrent Lightpanda tabs across instances" do
    assert {:ok, _path} = SpectreLens.Lightpanda.detect()
    assert {:ok, lens} = SpectreLens.open(instances: 2)

    try do
      assert {:ok, first} = SpectreLens.new_tab(lens, url: "https://example.com")
      assert {:ok, second} = SpectreLens.new_tab(lens, url: "https://elchemista.com")
      assert first.instance_id != second.instance_id
    after
      SpectreLens.close(lens)
    end
  end

  test "exports content from real multi-instance pages" do
    assert {:ok, _path} = SpectreLens.Lightpanda.detect()
    assert {:ok, lens} = SpectreLens.open(instances: 2)

    try do
      for {url, expected_host} <- @real_content_pages do
        assert {:ok, tab} = SpectreLens.new_tab(lens, url: url, timeout: @real_content_timeout)

        try do
          assert {:ok, view} =
                   SpectreLens.look(tab,
                     include: [
                       :markdown,
                       :semantic_tree,
                       :interactive,
                       :forms,
                       :links,
                       :structured_data
                     ],
                     timeout: @real_content_timeout
                   )

          assert_real_page_content(view, expected_host)
          assert_agent_views_have_content(tab)
        after
          SpectreLens.close_tab(tab)
        end
      end
    after
      SpectreLens.close(lens)
    end
  end

  test "captures markdown from paginebianche company search with exact multi-instance flow" do
    assert {:ok, _path} = SpectreLens.Lightpanda.detect()
    assert {:ok, lens} = SpectreLens.open(instances: 2)

    try do
      assert {:ok, tab} =
               SpectreLens.new_tab(lens,
                 url: "https://www.paginebianche.it/aziende?qs=IT&dv=Italia",
                 timeout: @real_content_timeout
               )

      assert {:ok, view} =
               SpectreLens.look(tab,
                 include: [
                   :markdown,
                   :semantic_tree,
                   :interactive,
                   :forms,
                   :links,
                   :structured_data
                 ],
                 timeout: @real_content_timeout
               )

      assert view.url =~ "paginebianche.it"
      assert view.title =~ "PagineBianche"
      assert byte_size(view.markdown) > 500
      refute Enum.empty?(view.links)
      refute Enum.empty?(view.interactive)
      assert semantic_child_count(view.semantic_tree) > 0
      refute Enum.any?(view.errors, &match?({:empty_page_projection, _}, &1))
    after
      SpectreLens.close(lens)
    end
  end

  test "clicks and navigates links by text" do
    assert {:ok, _path} = SpectreLens.Lightpanda.detect()
    assert {:ok, lens} = SpectreLens.open(instances: 1)

    try do
      assert {:ok, tab} = SpectreLens.new_tab(lens, url: "https://elchemista.com")
      assert {:ok, view} = SpectreLens.look(tab, include: [:links, :interactive])

      refute Enum.any?(view.interactive, &Map.has_key?(&1, "href"))
      assert :ok = SpectreLens.act(tab, {:click, text: "Latest articles"})

      assert {:ok, %{"result" => %{"value" => url}}} =
               SpectreLens.cdp(tab, "Runtime.evaluate", %{
                 expression: "window.location.href",
                 returnByValue: true
               })

      assert url =~ "#latest-articles"

      assert :ok = SpectreLens.act(tab, {:navigate, text: "Coding With AI Agents"})
    after
      SpectreLens.close(lens)
    end
  end

  test "actions return element errors for bad refs" do
    assert {:ok, _path} = SpectreLens.Lightpanda.detect()
    {:ok, server} = start_http_server("<html><body><button id=\"ok\">OK</button></body></html>")
    assert {:ok, lens} = SpectreLens.open(instances: 1)

    try do
      assert {:ok, tab} = SpectreLens.new_tab(lens, url: "http://127.0.0.1:#{server.port}/")

      assert {:error, %SpectreLens.ElementNotFoundError{}} =
               SpectreLens.act(tab, {:click, ref: "#missing-button"})

      assert {:error, %SpectreLens.ElementNotFoundError{}} =
               SpectreLens.act(tab, {:fill, ref: "#missing-input", value: "nope"})

      assert {:error, %SpectreLens.ElementNotFoundError{}} =
               SpectreLens.act(tab, {:click, ref: %{"href" => "https://example.com/missing"}})

      assert {:error, %SpectreLens.ElementNotFoundError{}} =
               SpectreLens.act(tab, {:click, ref: %{"backendNodeId" => -1}})
    after
      SpectreLens.close(lens)
      stop_http_server(server)
    end
  end

  test "outline can inspect a URL with a temporary runtime" do
    assert {:ok, _path} = SpectreLens.Lightpanda.detect()

    {:ok, server} =
      start_http_server("""
      <html>
        <body>
          <section class="hero"><h1>Temporary outline</h1><a href="#next">Next</a></section>
          <footer>Done</footer>
        </body>
      </html>
      """)

    try do
      assert {:ok, outline} =
               SpectreLens.outline(url: "http://127.0.0.1:#{server.port}/", detailed: true)

      assert outline.text =~ "Temporary outline"
      assert Enum.any?(outline.sections, &(&1.purpose == :hero))
    after
      stop_http_server(server)
    end
  end

  test "copies saved cookies and web storage into isolated session tabs" do
    assert {:ok, _path} = SpectreLens.Lightpanda.detect()
    {:ok, server} = start_http_server("<html><body>session test</body></html>")
    assert {:ok, lens} = SpectreLens.open(instances: 2)

    url = "http://127.0.0.1:#{server.port}/"

    try do
      assert {:ok, tab} = SpectreLens.new_tab(lens, url: url, session: :login)
      assert is_binary(tab.browser_context_id)
      assert tab.session_key == :login

      assert {:ok, _} =
               SpectreLens.cdp(tab, "Runtime.evaluate", %{
                 expression: """
                 (() => {
                   document.cookie = 'lens_cookie=one; path=/';
                   window.localStorage.setItem('token', 'one');
                   window.sessionStorage.setItem('nonce', 'one');
                   return true;
                 })()
                 """,
                 returnByValue: true,
                 awaitPromise: true
               })

      assert {:ok, saved} = SpectreLens.save_session(tab)
      assert Enum.any?(saved.cookies, &match?(%{"name" => "lens_cookie", "value" => "one"}, &1))
      assert saved.local_storage[url_origin(url)] == %{"token" => "one"}
      assert saved.session_storage[url_origin(url)] == %{"nonce" => "one"}

      assert {:ok, second} = SpectreLens.new_tab(lens, url: url, session: :login)
      assert second.instance_id != tab.instance_id

      assert %{"cookie" => cookie, "local" => "one", "session" => "one"} =
               browser_storage(second)

      assert cookie =~ "lens_cookie=one"

      assert {:ok, _} =
               SpectreLens.cdp(second, "Runtime.evaluate", %{
                 expression: "window.localStorage.setItem('token', 'two'); true",
                 returnByValue: true,
                 awaitPromise: true
               })

      assert {:ok, unchanged} = SpectreLens.get_session(lens, :login)
      assert unchanged.local_storage[url_origin(url)] == %{"token" => "one"}

      assert {:ok, updated} = SpectreLens.save_session(second)
      assert updated.local_storage[url_origin(url)] == %{"token" => "two"}
    after
      SpectreLens.close(lens)
      stop_http_server(server)
    end
  end

  test "require_session? rejects unknown logical sessions before opening a tab" do
    assert {:ok, _path} = SpectreLens.Lightpanda.detect()
    assert {:ok, lens} = SpectreLens.open(instances: 1, max_tabs_per_instance: 1)

    try do
      assert {:error, {:unknown_session, :missing}} =
               SpectreLens.new_tab(lens, session: :missing, require_session?: true)
    after
      SpectreLens.close(lens)
    end
  end

  defp browser_storage(tab) do
    assert {:ok, %{"result" => %{"value" => storage}}} =
             SpectreLens.cdp(tab, "Runtime.evaluate", %{
               expression: """
               ({
                 cookie: document.cookie,
                 local: window.localStorage.getItem('token'),
                 session: window.sessionStorage.getItem('nonce')
               })
               """,
               returnByValue: true,
               awaitPromise: true
             })

    storage
  end

  defp url_origin(url) do
    uri = URI.parse(url)
    "#{uri.scheme}://#{uri.host}:#{uri.port}"
  end

  defp assert_real_page_content(view, expected_host) do
    assert view.url =~ expected_host
    assert is_binary(view.title)
    assert byte_size(view.title) > 0
    assert byte_size(view.markdown) > 500
    refute Enum.empty?(view.links)
    refute Enum.empty?(view.interactive)
    assert semantic_child_count(view.semantic_tree) > 0
  end

  defp assert_agent_views_have_content(tab) do
    assert {:ok, outline} =
             SpectreLens.outline(tab, detailed: true, timeout: @real_content_timeout)

    assert byte_size(outline.text) > 0
    refute Enum.empty?(outline.sections)

    assert {:ok, page_map} = SpectreLens.zoom_out(tab, timeout: @real_content_timeout)
    assert byte_size(page_map.description) > 0
    refute Enum.empty?(page_map.regions)

    selector =
      outline.sections
      |> Enum.map(& &1.selector)
      |> Enum.find(&is_binary/1)

    assert is_binary(selector)

    assert {:ok, focused} = SpectreLens.zoom_in(tab, selector, timeout: @real_content_timeout)
    assert byte_size(focused.description) > 0
    refute Enum.empty?(focused.regions)

    assert {:ok, markdown} = SpectreLens.export(tab, :markdown, timeout: @real_content_timeout)
    assert byte_size(markdown) > 500

    assert {:ok, html} = SpectreLens.export(tab, :html, timeout: @real_content_timeout)
    assert byte_size(html) > 1_000
  end

  defp semantic_child_count(%{"children" => children}) when is_list(children),
    do: length(children)

  defp semantic_child_count(_tree), do: 0

  defp start_http_server(body) do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)

    pid =
      spawn_link(fn ->
        receive do
          :go -> :ok
        end

        http_server_loop(socket, body)
      end)

    :ok = :gen_tcp.controlling_process(socket, pid)
    send(pid, :go)
    {:ok, %{pid: pid, port: port}}
  end

  defp stop_http_server(%{pid: pid}) do
    if Process.alive?(pid) do
      Process.unlink(pid)
      Process.exit(pid, :shutdown)
    end

    :ok
  end

  defp http_server_loop(socket, body) do
    case :gen_tcp.accept(socket) do
      {:ok, client} ->
        _ = :gen_tcp.recv(client, 0, 1_000)
        response = http_response(body)
        :ok = :gen_tcp.send(client, response)
        :ok = :gen_tcp.close(client)
        http_server_loop(socket, body)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        http_server_loop(socket, body)
    end
  end

  defp http_response(body) do
    [
      "HTTP/1.1 200 OK\r\n",
      "content-type: text/html; charset=utf-8\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n",
      "\r\n",
      body
    ]
  end
end
