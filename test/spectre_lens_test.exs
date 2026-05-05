defmodule SpectreLensTest do
  use ExUnit.Case, async: true

  alias SpectreLens.{
    ActionRef,
    ConnectionError,
    Context,
    Lightpanda,
    LlmsTxt,
    Outline,
    PageMap,
    PlugPipeline,
    Region,
    Session,
    Tab,
    Telemetry,
    View
  }

  alias SpectreLens.CDP.Connection
  alias SpectreLens.Plugs

  defmodule AssignPlug do
    @behaviour SpectreLens.Plug

    def call(context, opts) do
      put_in(context.assigns[:plug_value], opts[:value] || :called)
    end
  end

  defmodule HaltPlug do
    @behaviour SpectreLens.Plug

    def call(context, _opts), do: {:halt, put_in(context.assigns[:halted], true)}
  end

  defmodule RaisePlug do
    @behaviour SpectreLens.Plug

    def call(_context, _opts), do: raise("plug failed")
  end

  defmodule TelemetryHandler do
    def handle_event(event, measurements, metadata, parent) do
      send(parent, {:telemetry_event, event, measurements, metadata})
    end
  end

  defmodule FakeProtocol do
    @behaviour SpectreLens.Protocol

    def new_tab(_instance, _opts), do: {:error, :unused}
    def close_tab(_tab), do: :ok
    def command(_tab, method, params, _opts), do: {:ok, %{method: method, params: params}}

    def navigate(_tab, _url, _opts), do: :ok

    def evaluate(_tab, _expression, _opts), do: {:ok, nil}
    def url(_tab), do: {:ok, "https://fake.local/"}
    def title(_tab), do: {:ok, "Fake"}
    def html(_tab, _opts), do: {:ok, "<html></html>"}
    def markdown(_tab, _opts), do: {:ok, "# Fake"}
    def semantic_tree(_tab, opts), do: {:ok, %{format: opts[:format]}}
    def interactive_elements(_tab, _opts), do: {:ok, [%{"tagName" => "button", "name" => "Go"}]}
    def structured_data(_tab, _opts), do: {:ok, %{"meta" => %{"title" => "Fake"}}}

    def page_map(_tab, _opts) do
      {:ok,
       %PageMap{
         description:
           "Zoomed out, the page has a navigation bar, a hero, a gallery, and a contact form.",
         regions: [
           %Region{purpose: :navigation, position: "top of the page"},
           %Region{
             purpose: :hero,
             label: "Welcome",
             position: "top of the page",
             selector: "#hero"
           },
           %Region{purpose: :gallery, position: "middle of the page"},
           %Region{purpose: :contact_form, position: "bottom of the page"}
         ]
       }}
    end

    def focus(_tab, ref, _opts) do
      {:ok,
       %PageMap{
         description: "Zoomed in, #{inspect(ref)} is a contact form.",
         regions: [%Region{purpose: :contact_form, selector: ref}]
       }}
    end

    def links(_tab, _opts), do: {:ok, [%{"href" => "https://fake.local/a", "text" => "A"}]}
    def forms(_tab, _opts), do: {:ok, []}
    def screenshot(_tab, _opts), do: {:ok, "png"}
    def pdf(_tab, _opts), do: {:ok, "pdf"}

    def click(_tab, _ref, _opts), do: :ok

    def fill(_tab, _ref, _value, _opts), do: :ok
    def submit(_tab, _ref, _fields, _opts), do: :ok
    def wait_for_selector(_tab, _selector, _opts), do: :ok
    def wait_for_navigation(_tab, fun, _opts), do: fun.()
    def scroll(_tab, _opts), do: :ok
  end

  defmodule LlmsProtocol do
    @behaviour SpectreLens.Protocol

    def new_tab(_instance, _opts), do: {:error, :unused}
    def close_tab(_tab), do: :ok
    def command(_tab, _method, _params, _opts), do: {:ok, %{}}

    def navigate(_tab, _url, _opts), do: :ok

    def evaluate(_tab, _expression, _opts) do
      {:ok, [%{"href" => "/llms.txt", "rel" => "llms.txt", "source" => "link"}]}
    end

    def url(_tab), do: {:ok, "https://llms.local/docs/page"}
    def title(_tab), do: {:ok, "LLMS"}
    def html(_tab, _opts), do: {:ok, "<html></html>"}
    def markdown(_tab, _opts), do: {:ok, "# LLMS"}
    def semantic_tree(_tab, _opts), do: {:ok, %{}}
    def interactive_elements(_tab, _opts), do: {:ok, []}
    def structured_data(_tab, _opts), do: {:ok, %{}}
    def page_map(_tab, _opts), do: {:ok, %PageMap{}}
    def focus(_tab, _ref, _opts), do: {:ok, %PageMap{}}
    def links(_tab, _opts), do: {:ok, []}
    def forms(_tab, _opts), do: {:ok, []}
    def screenshot(_tab, _opts), do: {:ok, "png"}
    def pdf(_tab, _opts), do: {:ok, "pdf"}

    def click(_tab, _ref, _opts), do: :ok

    def fill(_tab, _ref, _value, _opts), do: :ok
    def submit(_tab, _ref, _fields, _opts), do: :ok
    def wait_for_selector(_tab, _selector, _opts), do: :ok
    def wait_for_navigation(_tab, fun, _opts), do: fun.()
    def scroll(_tab, _opts), do: :ok
  end

  defmodule ViewShapeProtocol do
    @behaviour SpectreLens.Protocol

    def new_tab(_instance, _opts), do: {:error, :unused}
    def close_tab(_tab), do: :ok
    def command(_tab, _method, _params, _opts), do: {:ok, %{}}

    def navigate(_tab, url, _opts) do
      if parent = Process.get(:action_parent), do: send(parent, {:navigate, url})
      :ok
    end

    def evaluate(_tab, _expression, _opts), do: {:ok, nil}
    def url(_tab), do: {:ok, "https://shape.local/"}
    def title(_tab), do: {:ok, "Shape"}
    def html(_tab, _opts), do: {:ok, ""}
    def markdown(_tab, _opts), do: {:ok, ""}
    def semantic_tree(_tab, _opts), do: {:ok, %{}}
    def interactive_elements(_tab, _opts), do: {:ok, Process.get(:interactive_elements, [])}
    def structured_data(_tab, _opts), do: {:ok, %{}}
    def page_map(_tab, _opts), do: {:ok, %PageMap{}}
    def focus(_tab, _ref, _opts), do: {:ok, %PageMap{}}
    def links(_tab, _opts), do: {:ok, Process.get(:links, [])}
    def forms(_tab, _opts), do: {:ok, []}
    def screenshot(_tab, _opts), do: {:ok, ""}
    def pdf(_tab, _opts), do: {:ok, ""}

    def click(_tab, ref, _opts) do
      if parent = Process.get(:action_parent), do: send(parent, {:click, ref})
      :ok
    end

    def fill(_tab, _ref, _value, _opts), do: :ok
    def submit(_tab, _ref, _fields, _opts), do: :ok
    def wait_for_selector(_tab, _selector, _opts), do: :ok
    def wait_for_navigation(_tab, fun, _opts), do: fun.()
    def scroll(_tab, _opts), do: :ok
  end

  describe "lightpanda install helpers" do
    test "resolves linux x86_64 nightly URL" do
      assert {:ok, url} =
               Lightpanda.install_url(
                 os: {:unix, :linux},
                 arch: "x86_64-pc-linux-gnu",
                 channel: "nightly"
               )

      assert url ==
               "https://github.com/lightpanda-io/browser/releases/download/nightly/lightpanda-x86_64-linux"
    end

    test "resolves macOS arm64 nightly URL" do
      assert {:ok, url} =
               Lightpanda.install_url(
                 os: {:unix, :darwin},
                 arch: "aarch64-apple-darwin"
               )

      assert String.ends_with?(url, "/lightpanda-aarch64-macos")
    end

    test "returns an unsupported platform error" do
      assert {:error, {:unsupported_platform, {:win32, :nt}}} =
               Lightpanda.install_url(os: {:win32, :nt}, arch: "x86_64")
    end
  end

  describe "plug pipeline" do
    test "runs custom plugs without builtins" do
      context = %Context{view: %View{}}

      assert {:ok, result} =
               PlugPipeline.run(context,
                 builtin_plugs?: false,
                 plugs: [{AssignPlug, value: :ok}]
               )

      assert result.assigns.plug_value == :ok
    end

    test "halts without running later plugs" do
      context = %Context{view: %View{}}

      assert {:ok, result} =
               PlugPipeline.run(context,
                 builtin_plugs?: false,
                 plugs: [HaltPlug, {AssignPlug, value: :after_halt}]
               )

      assert result.halted?
      assert result.assigns.halted
      refute Map.has_key?(result.assigns, :plug_value)
    end

    test "returns invalid plug and raised plug failures as errors" do
      context = %Context{view: %View{}}

      assert {:error, {:plug_not_available, :not_a_module}} =
               PlugPipeline.run(context, builtin_plugs?: false, plugs: [:not_a_module])

      assert {:error, {RuntimeError, "plug failed"}} =
               PlugPipeline.run(context, builtin_plugs?: false, plugs: [RaisePlug])
    end
  end

  describe "browser session snapshots" do
    test "normalizes imported JSON-safe maps" do
      assert {:ok, session} =
               Session.normalize(%{
                 "version" => 1,
                 "cookies" => [%{"name" => "sid", "value" => "abc"}],
                 "local_storage" => %{"https://example.com" => %{"token" => 123}},
                 "session_storage" => %{"https://example.com" => %{"nonce" => :ok}},
                 "metadata" => %{source: :test}
               })

      assert session.cookies == [%{"name" => "sid", "value" => "abc"}]
      assert session.local_storage == %{"https://example.com" => %{"token" => "123"}}
      assert session.session_storage == %{"https://example.com" => %{"nonce" => "ok"}}
      assert session.metadata == %{"source" => "test"}
      assert %{"version" => 1, "cookies" => [_]} = Session.to_map(session)
    end

    test "rejects unsupported snapshot versions" do
      assert {:error, {:unsupported_session_version, 2}} =
               Session.normalize(%{"version" => 2})
    end

    test "merges captured cookies and origin storage into an existing session" do
      existing =
        Session.new(
          cookies: [%{"name" => "old", "value" => "1"}],
          local_storage: %{"https://example.com" => %{"old" => "1"}},
          session_storage: %{"https://example.com" => %{"nonce" => "old"}},
          metadata: %{"source" => "old"}
        )

      captured =
        Session.new(
          cookies: [%{"name" => "new", "value" => "2"}],
          local_storage: %{"https://example.com" => %{"token" => "2"}},
          session_storage: %{"https://other.example" => %{"nonce" => "new"}},
          metadata: %{"source" => "new"}
        )

      merged = Session.merge(existing, captured)

      assert merged.cookies == [%{"name" => "new", "value" => "2"}]
      assert merged.local_storage["https://example.com"] == %{"old" => "1", "token" => "2"}
      assert merged.session_storage["https://example.com"] == %{"nonce" => "old"}
      assert merged.session_storage["https://other.example"] == %{"nonce" => "new"}
      assert merged.metadata == %{"source" => "new"}
      assert merged.created_at == existing.created_at
    end
  end

  describe "browser protocol" do
    test "look dispatches through the tab driver instead of hard-coding CDP" do
      tab = %Tab{driver: FakeProtocol}

      assert {:ok, view} =
               SpectreLens.look(tab,
                 llms?: false,
                 include: [:markdown, :interactive, :links, :structured_data]
               )

      assert view.url == "https://fake.local/"
      assert view.title == "Fake"
      assert view.markdown == "# Fake"
      assert Enum.any?(view.actions, &match?(%ActionRef{kind: :button}, &1))
      assert Enum.any?(view.actions, &match?(%ActionRef{kind: :link}, &1))
    end

    test "look reports completely empty requested page projections" do
      tab = %Tab{driver: ViewShapeProtocol}

      assert {:ok, view} =
               SpectreLens.look(tab,
                 llms?: false,
                 include: [:markdown, :semantic_tree, :interactive, :forms, :links]
               )

      assert {:empty_page_projection,
              %{
                url: "https://shape.local/",
                title: "Shape",
                markdown_size: 0,
                semantic_children: 0,
                interactive_count: 0,
                form_count: 0,
                link_count: 0
              }} in view.errors
    end

    test "public act/export/cdp dispatch through protocol driver" do
      tab = %Tab{driver: FakeProtocol}
      export_path = Path.join(System.tmp_dir!(), "spectre-lens-export-test.png")
      File.rm(export_path)

      assert :ok = SpectreLens.close_tab(tab)
      assert :ok = SpectreLens.act(tab, {:click, ref: "#go"})
      assert :ok = SpectreLens.act(tab, {:fill, ref: "#q", value: "lens"})
      assert {:ok, "png"} = SpectreLens.export(tab, :screenshot)
      assert {:ok, ^export_path} = SpectreLens.export(tab, :screenshot, path: export_path)
      assert File.read!(export_path) == "png"
      pdf_path = Path.join(System.tmp_dir!(), "spectre-lens-export-test.pdf")
      File.rm(pdf_path)

      assert {:ok, ^pdf_path} = SpectreLens.export(tab, :pdf, path: pdf_path)
      assert File.read!(pdf_path) == "pdf"

      assert {:ok, %{method: "Browser.getVersion", params: %{}}} =
               SpectreLens.cdp(tab, "Browser.getVersion")
    end

    test "public API catches driver exceptions" do
      defmodule ExplodingProtocol do
        @behaviour SpectreLens.Protocol

        def new_tab(_instance, _opts), do: raise("new tab exploded")
        def close_tab(_tab), do: :ok
        def command(_tab, _method, _params, _opts), do: raise("cdp exploded")
        def navigate(_tab, _url, _opts), do: raise("navigate exploded")
        def evaluate(_tab, _expression, _opts), do: {:ok, nil}
        def url(_tab), do: {:ok, "https://boom.local/"}
        def title(_tab), do: {:ok, "Boom"}
        def html(_tab, _opts), do: {:ok, ""}
        def markdown(_tab, _opts), do: {:ok, ""}
        def semantic_tree(_tab, _opts), do: {:ok, %{}}
        def interactive_elements(_tab, _opts), do: {:ok, []}
        def structured_data(_tab, _opts), do: {:ok, %{}}
        def page_map(_tab, _opts), do: raise("map exploded")
        def focus(_tab, _ref, _opts), do: raise("focus exploded")
        def links(_tab, _opts), do: {:ok, []}
        def forms(_tab, _opts), do: {:ok, []}
        def screenshot(_tab, _opts), do: raise("shot exploded")
        def pdf(_tab, _opts), do: {:ok, ""}
        def click(_tab, _ref, _opts), do: raise("click exploded")
        def fill(_tab, _ref, _value, _opts), do: :ok
        def submit(_tab, _ref, _fields, _opts), do: :ok
        def wait_for_selector(_tab, _selector, _opts), do: :ok
        def wait_for_navigation(_tab, fun, _opts), do: fun.()
        def scroll(_tab, _opts), do: :ok
      end

      tab = %Tab{driver: ExplodingProtocol}

      assert {:error, %SpectreLens.CaughtError{operation: :act}} =
               SpectreLens.act(tab, {:navigate, "https://boom.local"})

      assert {:error, %SpectreLens.CaughtError{operation: :export}} =
               SpectreLens.export(tab, :screenshot)

      assert {:error, %SpectreLens.CaughtError{operation: :zoom_out}} =
               SpectreLens.zoom_out(tab)

      assert {:error, %SpectreLens.CaughtError{operation: :cdp}} =
               SpectreLens.cdp(tab, "Browser.getVersion")
    end

    test "zoom_out, unfocus, and zoom_in dispatch through protocol driver" do
      tab = %Tab{driver: FakeProtocol}

      assert {:ok, map} = SpectreLens.zoom_out(tab)
      assert map.description =~ "navigation bar"
      assert Enum.map(map.regions, & &1.purpose) == [:navigation, :hero, :gallery, :contact_form]

      assert {:ok, unfocused} = SpectreLens.unfocus(tab)
      assert unfocused.description =~ "Zoomed out"

      assert {:ok, focused} = SpectreLens.zoom_in(tab, "#contact")
      assert focused.description =~ "#contact"
      assert [%Region{purpose: :contact_form}] = focused.regions
    end

    test "outline returns compact and detailed section outlines" do
      tab = %Tab{driver: FakeProtocol}

      assert {:ok, %Outline{} = outline} = SpectreLens.outline(tab)
      assert outline.text =~ "[Navigation]"
      assert outline.text =~ "[Hero / Welcome]"

      assert Enum.map(outline.sections, & &1.purpose) == [
               :navigation,
               :hero,
               :gallery,
               :contact_form
             ]

      assert {:ok, detailed} = SpectreLens.outline(tab, [:detailed])
      assert detailed.detailed?
      assert detailed.text =~ "[ Hero / Welcome ]"
      assert detailed.text =~ "[end Hero / Welcome]"
    end

    test "outline handles empty and unlabeled generic sections" do
      assert %Outline{text: "", sections: []} = Outline.from_regions([], [])

      regions = [
        %Region{purpose: :content_section, text: "boilerplate"},
        %Region{purpose: :form, label: "Subscribe", selector: "#subscribe"}
      ]

      assert %Outline{text: "[Form / Subscribe]", sections: [%Outline.Section{} = section]} =
               Outline.from_regions(regions, [])

      assert section.selector == "#subscribe"
    end

    test "zoom_in accepts an outline section" do
      tab = %Tab{driver: FakeProtocol}

      assert {:ok, outline} = SpectreLens.outline(tab)
      section = Enum.find(outline.sections, &(&1.purpose == :hero))

      assert {:ok, focused} = SpectreLens.zoom_in(tab, section)
      assert focused.description =~ section.selector
    end
  end

  describe "built-in action refs" do
    test "builds actions from interactive elements" do
      [action] =
        Plugs.ActionRefs.build_from_interactive([
          %{
            "tagName" => "button",
            "role" => "button",
            "name" => "Search",
            "id" => "search-btn",
            "nodeId" => 42
          }
        ])

      assert %ActionRef{} = action
      assert action.kind == :button
      assert action.label == "Search"
      assert action.selector == "#search-btn"
      assert action.node_id == 42
    end

    test "skips links in interactive plug output" do
      Process.put(:interactive_elements, [
        %{"tagName" => "a", "role" => "link", "href" => "https://example.com", "name" => "Link"},
        %{tagName: "a", role: "link", href: "https://example.com/atom", name: "Atom Link"},
        %{"tagName" => "button", "role" => "button", "name" => "Go"},
        %{tagName: "div", role: "button", name: "Open"}
      ])

      context = %Context{
        include: [:interactive],
        view: %View{},
        tab: %Tab{driver: ViewShapeProtocol}
      }

      assert %{view: %View{interactive: interactive}} = Plugs.Interactive.call(context, [])
      assert Enum.map(interactive, &(&1["name"] || &1[:name])) == ["Go", "Open"]
    after
      Process.delete(:interactive_elements)
    end

    test "deduplicates links and handles empty link lists" do
      Process.put(:links, [
        %{"href" => "https://example.com/a", "text" => "A"},
        %{"href" => "https://example.com/a", "text" => "A duplicate"},
        %{href: "https://example.com/b", text: "B"}
      ])

      context = %Context{
        include: [:links],
        view: %View{},
        tab: %Tab{driver: ViewShapeProtocol}
      }

      assert %{view: %View{links: links}} = Plugs.Links.call(context, [])

      assert Enum.map(links, &(&1["href"] || &1[:href])) == [
               "https://example.com/a",
               "https://example.com/b"
             ]

      Process.put(:links, [])
      assert %{view: %View{links: []}} = Plugs.Links.call(context, [])
    after
      Process.delete(:links)
    end

    test "builds form and field actions" do
      actions =
        Plugs.ActionRefs.build_from_forms([
          %{
            "name" => "login",
            "selector" => "#login",
            "fields" => [
              %{"tag" => "input", "type" => "email", "label" => "Email", "selector" => "#email"},
              %{"tag" => "select", "label" => "Region", "selector" => "#region"}
            ]
          }
        ])

      assert Enum.map(actions, & &1.kind) == [:form, :input, :select]
      assert Enum.map(actions, & &1.selector) == ["#login", "#email", "#region"]
    end

    test "builds link actions" do
      [action] =
        Plugs.ActionRefs.build_from_links([
          %{"href" => "https://example.com", "text" => "Example", "selector" => "#example"}
        ])

      assert action.kind == :link
      assert action.label == "Example"
      assert action.href == "https://example.com"
    end
  end

  describe "agentic actions" do
    setup do
      Process.put(:action_parent, self())

      on_exit(fn ->
        Process.delete(:action_parent)
        Process.delete(:interactive_elements)
        Process.delete(:links)
      end)

      :ok
    end

    test "navigate finds a link by similar text" do
      Process.put(:links, [
        %{"href" => "https://example.com/latest", "text" => "Latest articles"},
        %{"href" => "https://example.com/contact", "text" => "Contact"}
      ])

      tab = %Tab{driver: ViewShapeProtocol}

      assert :ok = SpectreLens.act(tab, {:navigate, text: "latest article"})
      assert_receive {:navigate, "https://example.com/latest"}
    end

    test "navigate tolerates typo-like text with string distance" do
      Process.put(:links, [
        %{"href" => "https://example.com/latest", "text" => "Latest articles"},
        %{"href" => "https://example.com/contact", "text" => "Contact"}
      ])

      tab = %Tab{driver: ViewShapeProtocol}

      assert :ok = SpectreLens.act(tab, {:navigate, text: "latst articls"})
      assert_receive {:navigate, "https://example.com/latest"}
    end

    test "click finds a non-link control by name" do
      Process.put(:interactive_elements, [
        %{"tagName" => "button", "role" => "button", "name" => "Open menu"},
        %{"tagName" => "button", "role" => "button", "name" => "Subscribe"}
      ])

      tab = %Tab{driver: ViewShapeProtocol}

      assert :ok = SpectreLens.act(tab, {:click, name: "open"})
      assert_receive {:click, %{"name" => "Open menu"}}
    end

    test "click falls back to links by text" do
      Process.put(:interactive_elements, [])
      Process.put(:links, [%{"href" => "https://example.com/pricing", "text" => "Pricing"}])

      tab = %Tab{driver: ViewShapeProtocol}

      assert :ok = SpectreLens.act(tab, {:click, text: "price"})
      assert_receive {:click, %{"href" => "https://example.com/pricing"}}
    end

    test "click ignores link-shaped interactive elements and uses link refs" do
      Process.put(:interactive_elements, [
        %{
          "backendNodeId" => 123,
          "href" => "https://example.com/latest",
          "name" => "Latest articles"
        }
      ])

      Process.put(:links, [
        %{"href" => "https://example.com/latest", "text" => "Latest articles"}
      ])

      tab = %Tab{driver: ViewShapeProtocol}

      assert :ok = SpectreLens.act(tab, {:click, text: "latest"})
      assert_receive {:click, %{"href" => "https://example.com/latest"}}
    end

    test "text actions return element errors when no target matches" do
      Process.put(:interactive_elements, [%{"tagName" => "button", "name" => "Subscribe"}])
      Process.put(:links, [%{"href" => "https://example.com/blog", "text" => "Blog"}])

      tab = %Tab{driver: ViewShapeProtocol}

      assert {:error, %SpectreLens.ElementNotFoundError{}} =
               SpectreLens.act(tab, {:click, text: "settings"})

      assert {:error, %SpectreLens.ElementNotFoundError{}} =
               SpectreLens.act(tab, {:navigate, text: "settings"})
    end
  end

  describe "markdown and hash plugs" do
    test "normalizes markdown and stores a hash" do
      context = %Context{
        view: %View{markdown: " # Title   \n\n\n\nBody  \n", interactive: [], forms: []}
      }

      context =
        context
        |> Plugs.NormalizeMarkdown.call([])
        |> Plugs.Hash.call([])

      assert context.view.markdown == "# Title\n\n\nBody"
      assert byte_size(context.assigns.hash) == 64
    end
  end

  describe "llms.txt agent context" do
    test "parses llms.txt sections and links" do
      doc =
        LlmsTxt.parse(
          """
          # Example Docs

          > Short docs for agents.

          Extra guidance.

          ## Docs

          - [Guide](/guide.md): Start here

          ## Optional

          - [Changelog](/changelog.md)
          """,
          url: "https://example.com/llms.txt"
        )

      assert doc.title == "Example Docs"
      assert doc.summary == "Short docs for agents."
      assert doc.info == "Extra guidance."
      assert [%{title: "Docs"}, %{title: "Optional", optional?: true}] = doc.sections
      assert [%{title: "Guide", url: "https://example.com/guide.md"} | _] = doc.links
    end

    test "builds candidates for directories, pages, and direct files" do
      assert %{
               index: ["https://example.com/docs/llms.txt", "https://example.com/llms.txt"],
               full: [
                 "https://example.com/docs/llms-full.txt",
                 "https://example.com/docs/llms-ctx-full.txt",
                 "https://example.com/llms-full.txt",
                 "https://example.com/llms-ctx-full.txt"
               ]
             } = LlmsTxt.candidate_urls("https://example.com/docs/page.html?x=1")

      assert %{
               index: ["https://example.com/llms.txt"],
               full: [
                 "https://example.com/llms-full.txt",
                 "https://example.com/llms-ctx-full.txt"
               ]
             } =
               LlmsTxt.candidate_urls("https://example.com/llms.txt")
    end

    test "discovers llms.txt from page metadata" do
      fetcher = fn
        "https://example.com/agent/llms.txt", _opts -> {:ok, "# Agent\n\n## Docs\n\n- [A](/a.md)"}
        "https://example.com/agent/llms-full.txt", _opts -> {:ok, "# Full\n\nAll context"}
        url, _opts -> {:error, {:unexpected_url, url}}
      end

      assert {:ok, doc} =
               LlmsTxt.discover_from_page(
                 "https://example.com/docs/page",
                 [%{"source" => "link", "href" => "/agent/llms.txt", "rel" => "llms.txt"}],
                 fetcher: fetcher,
                 header_fetcher: fn _url, _opts -> {:ok, %{}} end,
                 full?: true
               )

      assert doc.url == "https://example.com/agent/llms.txt"
      assert doc.full_url == "https://example.com/agent/llms-full.txt"
      assert {:ok, "# Full\n\nAll context"} = LlmsTxt.to_context(doc)
    end

    test "discovers llms.txt from HTTP Link header" do
      fetcher = fn
        "https://example.com/llms.txt", _opts -> {:ok, "# Agent"}
        url, _opts -> {:error, {:unexpected_url, url}}
      end

      header_fetcher = fn _url, _opts ->
        {:ok, %{"link" => ["</llms.txt>; rel=\"llms.txt\""]}}
      end

      assert {:ok, doc} =
               LlmsTxt.discover_from_page("https://example.com/docs", [],
                 fetcher: fetcher,
                 header_fetcher: header_fetcher
               )

      assert doc.url == "https://example.com/llms.txt"
    end

    test "falls back to index context when full context is missing" do
      doc = %LlmsTxt{content: "# Index", full_content: nil}
      assert {:ok, "# Index"} = LlmsTxt.to_context(doc)
      assert {:ok, "# Index"} = LlmsTxt.to_context(doc, prefer: :both)

      assert {:error, {:invalid_llms_context_preference, :bad}} =
               LlmsTxt.to_context(doc, prefer: :bad)
    end

    test "enforces max body size and reports missing candidates" do
      fetcher = fn _url, _opts -> {:ok, "123456"} end

      assert {:error,
              {:llms_txt_not_found, {:body_too_large, 3}, ["https://example.com/llms.txt"]}} =
               LlmsTxt.discover("https://example.com/llms.txt", fetcher: fetcher, max_bytes: 3)

      assert {:error, {:llms_txt_not_found, :no_page_metadata_or_header, []}} =
               LlmsTxt.discover_from_page("https://example.com/", [],
                 fetcher: fetcher,
                 header_fetcher: fn _url, _opts -> {:ok, %{}} end
               )
    end

    test "look includes llms context when page metadata exposes it" do
      fetcher = fn
        "https://llms.local/llms.txt", _opts -> {:ok, "# Agent\n\n## Docs\n\n- [Docs](/docs)"}
        "https://llms.local/llms-full.txt", _opts -> {:ok, "# Full Agent Context"}
        url, _opts -> {:error, {:unexpected_url, url}}
      end

      tab = %Tab{driver: LlmsProtocol}

      assert {:ok, view} =
               SpectreLens.look(tab,
                 include: [:markdown, :llms],
                 fetcher: fetcher,
                 header_fetcher: fn _url, _opts -> {:ok, %{}} end,
                 full?: true
               )

      assert %LlmsTxt{url: "https://llms.local/llms.txt"} = view.llms
      assert view.llms_context == "# Full Agent Context"
      assert view.markdown == "# LLMS"
    end
  end

  describe "errors" do
    test "builds structured unsupported error" do
      error = SpectreLens.UnsupportedError.new(:pdf, :missing_method)
      assert error.feature == :pdf
      assert error.reason == :missing_method
      assert error.message =~ "pdf is not supported"
    end

    test "explains errors for agents" do
      error = SpectreLens.ElementNotFoundError.new("#missing")

      assert %{
               type: :element_not_found,
               target: "#missing",
               retryable?: true,
               hint: hint
             } = SpectreLens.explain_error(error)

      assert hint =~ "zoom_out/2"
    end

    test "safe catches raised failures for agents" do
      assert {:error, %SpectreLens.CaughtError{} = error} =
               SpectreLens.Errors.safe(:boom, fn -> raise "boom" end)

      assert %{type: :caught, operation: :boom, retryable?: false} =
               SpectreLens.explain_error(error)
    end

    test "safe catches throw and exit failures" do
      assert {:error, %SpectreLens.CaughtError{kind: :throw, reason: :thrown}} =
               SpectreLens.Errors.safe(:throwing, fn -> throw(:thrown) end)

      assert {:error, %SpectreLens.CaughtError{kind: :exit, reason: :shutdown}} =
               SpectreLens.Errors.safe(:exiting, fn -> exit(:shutdown) end)
    end

    test "explains each structured error type" do
      errors = [
        {SpectreLens.TimeoutError.new(operation: :wait, timeout_ms: 10), :timeout},
        {SpectreLens.ConnectionError.new(:closed), :connection},
        {SpectreLens.CDPError.new(-32_000, "temporary", "DOM.querySelector"), :cdp},
        {SpectreLens.JavaScriptError.new("TypeError"), :javascript},
        {SpectreLens.UnsupportedError.new(:pdf), :unsupported},
        {{:unknown_action, :dance}, :unknown_action}
      ]

      for {error, type} <- errors do
        packet = SpectreLens.explain_error(error)
        assert packet.type == type
        assert is_binary(packet.message)
      end

      assert SpectreLens.Errors.retryable?(SpectreLens.TimeoutError.new(operation: :wait))
      assert SpectreLens.Errors.hint(SpectreLens.UnsupportedError.new(:pdf)) =~ "Page.printToPDF"
    end
  end

  describe "telemetry" do
    test "publishes documented span events with result metadata" do
      event = [:spectre_lens, :page, :operation, :stop]
      handler_id = {__MODULE__, self(), :telemetry_span}
      parent = self()

      :ok =
        :telemetry.attach(
          handler_id,
          event,
          &TelemetryHandler.handle_event/4,
          parent
        )

      try do
        assert {:ok, :done} =
                 Telemetry.span([:spectre_lens, :page, :operation], %{operation: :test}, fn ->
                   result = {:ok, :done}
                   {result, %{result: result}}
                 end)

        assert_receive {:telemetry_event, ^event, measurements, metadata}
        assert is_integer(measurements.duration)
        assert metadata.operation == :test
        assert metadata.result == {:ok, :done}
      after
        :telemetry.detach(handler_id)
      end
    end

    test "lists point and span events" do
      assert [:spectre_lens, :cdp, :command, :stop] in Telemetry.events()
      refute [:spectre_lens, :cdp, :command, :exception] in Telemetry.events()
      assert [:spectre_lens, :watcher, :error] in Telemetry.events()
      assert [:spectre_lens, :agent, :llms, :stop] in Telemetry.events()
    end

    test "span catches raised failures and emits stop metadata" do
      event = [:spectre_lens, :agent, :llms, :stop]
      handler_id = {__MODULE__, self(), :telemetry_error_span}
      parent = self()

      :ok = :telemetry.attach(handler_id, event, &TelemetryHandler.handle_event/4, parent)

      try do
        assert {:error, %SpectreLens.CaughtError{} = error} =
                 Telemetry.span([:spectre_lens, :agent, :llms], %{operation: :test}, fn ->
                   raise "telemetry failed"
                 end)

        assert error.operation == :telemetry_span
        assert_receive {:telemetry_event, ^event, _measurements, %{result: {:error, ^error}}}
      after
        :telemetry.detach(handler_id)
      end
    end
  end

  describe "connection" do
    test "open returns a connection error for unreachable endpoints" do
      assert {:error, %ConnectionError{}} =
               Connection.open("http://127.0.0.1:1")
    end
  end
end
