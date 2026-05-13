# Spectre Lens

Agent-first Elixir browser lens for Lightpanda.

Spectre Lens controls Lightpanda through CDP, but CDP is only a driver detail.
The public contract is `SpectreLens.Protocol`: page views, actions, exports,
page maps, watchers, and agent context. Other browser backends can implement
the same protocol later.

## Features

- Start one or more Lightpanda instances and balance tabs across them.
- Navigate, click, fill, submit, scroll, wait for selectors, and send raw CDP.
- Extract agent-readable views: markdown, HTML, semantic tree, forms, links,
  structured data, interactive elements, and action refs.
- Describe page layout in words with `zoom_out/2`, `zoom_in/3`, and `unfocus/2`.
- Run goal-scoped site discovery with deterministic or custom pluggable scoring.
- Export screenshots, HTML, markdown, and PDF when the browser supports it.
- Discover and parse `llms.txt` / `llms-full.txt` context for agents.
- Auto-include `llms.txt` context in `SpectreLens.look/2` when pages expose it
  through metadata or HTTP `Link` headers.
- Return agent-friendly errors instead of crashing at public API edges.
- Emit telemetry events without attaching loggers or writing logs.

## Installation

Add the package to your Mix project once published or through a local/path
dependency while developing:

```elixir
def deps do
  [
    {:spectre_lens, path: "../spectre_lens"}
  ]
end
```

Install or inspect the Lightpanda binary:

```sh
mix spectre.lens.install --channel nightly --out ~/.local/bin --force
mix spectre.lens.doctor
```

You can also point Spectre Lens at an existing binary:

```elixir
{:ok, lens} = SpectreLens.open(binary: "/path/to/lightpanda")
```

## Quick Start

```elixir
{:ok, lens} = SpectreLens.open(instances: 2)
{:ok, tab} = SpectreLens.new_tab(lens, url: "https://example.com")

{:ok, view} =
  SpectreLens.look(tab,
    include: [:markdown, :semantic_tree, :interactive, :forms, :links, :structured_data]
  )

view.markdown
view.actions
view.llms_context

{:ok, map} = SpectreLens.zoom_out(tab)
map.description

{:ok, focused} = SpectreLens.zoom_in(tab, "#contact")

{:ok, discovery} = SpectreLens.discover(tab, goal: "api reference")
discovery.text
discovery.candidates

:ok = SpectreLens.act(tab, {:fill, ref: "#q", value: "spectre"})
:ok = SpectreLens.act(tab, {:click, ref: "button[type=submit]"})

{:ok, "screenshots/example.png"} =
  SpectreLens.export(tab, :screenshot, path: "screenshots/example.png")

:ok = SpectreLens.close(lens)
```

## Lightpanda Runtime Model

Spectre Lens currently ships with the Lightpanda CDP driver. Chrome, WebDriver
BiDi, MCP, or another browser backend could implement `SpectreLens.Protocol`
later, but they are not included today.

With the current Lightpanda driver:

- `instances: n` starts `n` Lightpanda browser processes.
- Each Lightpanda instance supports one live tab at a time.
- Concurrent tabs require multiple instances.
- `max_tabs_per_instance` is ignored for Lightpanda because Lightpanda rejects a
  second live CDP target with `TargetAlreadyLoaded`.
- When all Lightpanda instances already have a live tab, `new_tab/2` returns
  `{:error, :tab_capacity_exceeded}`.

For example, two concurrent tabs need two instances:

```elixir
{:ok, lens} = SpectreLens.open(instances: 2)

{:ok, first} = SpectreLens.new_tab(lens, url: "https://example.com")
{:ok, second} = SpectreLens.new_tab(lens, url: "https://elchemista.com")

first.instance_id != second.instance_id
```

To open another page on a single-instance runtime, close the current tab first:

```elixir
{:ok, lens} = SpectreLens.open(instances: 1)

{:ok, tab} = SpectreLens.new_tab(lens, url: "https://example.com")
:ok = SpectreLens.close_tab(tab)

{:ok, next_tab} = SpectreLens.new_tab(lens, url: "https://elchemista.com")
```

## Browser Sessions

Use logical sessions when login state should survive across tabs or process
boundaries. Sessions are stored in the runtime's ETS table and copied into a
fresh Lightpanda browser context when a tab is opened.

```elixir
{:ok, lens} = SpectreLens.open(instances: 2)
{:ok, tab} = SpectreLens.new_tab(lens, url: "https://app.example/login", session: :work)

# log in with normal actions...
:ok = SpectreLens.act(tab, {:fill, ref: "#email", value: "agent@example.com"})
:ok = SpectreLens.act(tab, {:click, ref: "button[type=submit]"})

{:ok, session} = SpectreLens.save_session(tab)
{:ok, saved_map} = SpectreLens.export_session(lens, :work)

{:ok, _session} = SpectreLens.import_session(lens, :work, saved_map)
{:ok, next_tab} = SpectreLens.new_tab(lens, url: "https://app.example/dashboard", session: :work)
```

Session snapshots include cookies, `localStorage`, and `sessionStorage` for
visited origins. Tabs receive isolated copies: changes in one tab are not
written back to ETS until `save_session/2` or `save_session/3` is called.

Use `require_session?: true` when a missing named session should fail instead
of starting with an empty snapshot:

```elixir
SpectreLens.new_tab(lens, session: :work, require_session?: true)
```

Local Lightpanda builds currently allow one live tab per instance, so concurrent
session tabs are balanced across runtime instances.

## Agent Views

`SpectreLens.look/2` returns a `%SpectreLens.View{}`:

```elixir
%SpectreLens.View{
  url: "https://example.com",
  title: "Example",
  markdown: "...",
  html: nil,
  semantic_tree: %{},
  semantic_text: nil,
  interactive: [],
  forms: [],
  links: [],
  structured_data: %{},
  llms: %SpectreLens.LlmsTxt{},
  llms_context: "# Full agent context...",
  actions: [],
  warnings: [],
  errors: []
}
```

The default include list is:

```elixir
[:markdown, :interactive, :forms, :links]
```

You can request more:

```elixir
SpectreLens.look(tab,
  include: [:html, :markdown, :semantic_tree, :semantic_text, :interactive, :forms, :links, :structured_data, :llms]
)
```

`semantic_tree` returns Lightpanda's structured tree. `semantic_text` returns
Lightpanda's text tree:

```elixir
{:ok, view} = SpectreLens.look(tab, include: [:semantic_tree, :semantic_text])

view.semantic_tree
view.semantic_text
```

`links` and `interactive` are intentionally separate:

- `links` contains navigation targets deduped by `href`.
- `interactive` contains non-link controls such as buttons, inputs, selects,
  textareas, forms, ARIA buttons, and other pressable/focusable controls.

Exports return binaries by default. Pass `:path` or `:to` to save the artifact
and receive the saved path instead:

```elixir
{:ok, "tmp/page.png"} = SpectreLens.export(tab, :screenshot, path: "tmp/page.png")
{:ok, "tmp/page.html"} = SpectreLens.export(tab, :html, to: "tmp/page.html")
```

Disable automatic `llms.txt` discovery when you only want browser-rendered
content:

```elixir
SpectreLens.look(tab, llms?: false)
```

## llms.txt Support

Spectre Lens supports the `llms.txt` convention for websites that expose
agent-oriented documentation.

Manual discovery:

```elixir
{:ok, doc} = SpectreLens.llms("https://example.com/docs", full?: true)

doc.title
doc.summary
doc.sections
doc.links
doc.content
doc.full_content
```

Direct context:

```elixir
{:ok, markdown} = SpectreLens.llms_context("https://example.com/docs")
```

From an open tab:

```elixir
{:ok, doc} = SpectreLens.llms(tab)
{:ok, markdown} = SpectreLens.llms_context(tab, prefer: :both)
```

During `look/2`, Spectre Lens checks:

- `<link href="/llms.txt" rel="llms.txt">`
- `<meta name="llms" content="/llms.txt">`
- HTTP `Link` headers such as `</llms.txt>; rel="llms.txt"`
- fallback candidate paths such as `/llms.txt`, `/llms-full.txt`, and
  `/llms-ctx-full.txt`

Useful options:

```elixir
SpectreLens.look(tab,
  llms?: true,
  llms_headers?: true,
  full?: true,
  prefer: :full
)
```

`prefer` can be `:full`, `:index`, or `:both`.

## Page Maps

Use page maps when an agent needs a spatial, human-readable description of the
page instead of raw DOM:

```elixir
{:ok, map} = SpectreLens.zoom_out(tab)

map.description
# "Zoomed out, the page is organized as follows: navigation at the top..."

{:ok, local} = SpectreLens.zoom_in(tab, "#pricing")
{:ok, global} = SpectreLens.unfocus(tab)
```

The map contains regions such as navigation, hero, sidebar, gallery, content,
contact form, and footer when Spectre Lens can infer them.

For faster orientation, use `outline/2`. It returns compact text plus the
structured sections behind that text:

```elixir
{:ok, outline} = SpectreLens.outline(tab)

outline.text
# [Navigation]
# [Hero / Elchemista: A Builder’s Blog on Elixir, AI, and MVPs]
# [Gallery / Featured Stories]
# [Gallery / Explore topics]
# [Gallery / Fresh from the Blog]
# [Form / Stay updated]
# [Footer]

hero = Enum.find(outline.sections, &(&1.purpose == :hero))
{:ok, hero_map} = SpectreLens.zoom_in(tab, hero)
```

Ask for a more descriptive outline with `:detailed`, `detailed: true`, or
`detailed?: true`:

```elixir
{:ok, outline} = SpectreLens.outline(tab, [:detailed])

outline.text
# [ Hero / Elchemista: A Builder’s Blog on Elixir, AI, and MVPs ]
#   [ Selector: div:nth-of-type(2) > section:nth-of-type(1) ]
#   [ Heading: Elchemista: A Builder’s Blog on Elixir, AI, and MVPs ]
#   [ Text: Welcome Elchemista: A Builder’s Blog on Elixir, AI, and MVPs ... ]
#   [ Links: Latest articles | Book a Call ]
#   [ Contains: 2 links, 1 images ]
# [end Hero / Elchemista: A Builder’s Blog on Elixir, AI, and MVPs]
```

You can also map a URL through a runtime. Spectre Lens opens a temporary tab and
closes it after building the outline:

```elixir
{:ok, outline} = SpectreLens.outline(lens, url: "https://elchemista.com", detailed: true)
```

For one-off inspection, pass only a URL. Spectre Lens starts and closes a
temporary runtime:

```elixir
{:ok, outline} = SpectreLens.outline(url: "https://elchemista.com", detailed: true)
```

## Goal-Scoped Discovery

Use `discover/2` when an agent has a goal but should not crawl an entire site.
Spectre Lens visits a small same-origin frontier, ranks links against the goal,
and returns compact context plus structured candidates:

```elixir
{:ok, discovery} =
  SpectreLens.discover(tab,
    goal: "api reference",
    max_depth: 2,
    max_pages: 8,
    max_links_per_page: 40,
    max_candidates: 20
  )

discovery.text
discovery.visited
discovery.candidates
discovery.forms
```

The default scorer is deterministic and dependency-free. To plug in an LLM or
domain-specific ranker later, implement `SpectreLens.Discovery.Scorer`:

```elixir
defmodule MyApp.LlmScorer do
  @behaviour SpectreLens.Discovery.Scorer

  def score_candidate(candidate, context, opts) do
    # Use context.goal, context.page, context.outline, context.view, etc.
    {:ok, %{candidate | score: 10.0, reason: "ranked by custom scorer"}}
  end

  def rank_candidates(candidates, _context, _opts) do
    {:ok, Enum.sort_by(candidates, & &1.score, :desc)}
  end
end

{:ok, discovery} =
  SpectreLens.discover(tab,
    goal: "api reference",
    scorer: {MyApp.LlmScorer, model: "my-model"}
  )
```

## Actions

Actions accept selectors, node ids, maps, `%SpectreLens.ActionRef{}` values,
and agent-friendly text queries. Text queries use normalized partial matching
and string distance, so close labels can still resolve when an agent is slightly
off.

```elixir
:ok = SpectreLens.act(tab, {:navigate, "https://example.com"})
:ok = SpectreLens.act(tab, {:click, ref: "#login"})
:ok = SpectreLens.act(tab, {:navigate, text: "Latest articles"})
:ok = SpectreLens.act(tab, {:click, text: "Book a Call"})
:ok = SpectreLens.act(tab, {:fill, ref: "#email", value: "agent@example.com"})
:ok = SpectreLens.act(tab, {:submit, ref: "#login-form", fields: %{"#password" => "secret"}})
:ok = SpectreLens.act(tab, {:scroll, by: 800})
```

For links, prefer a text query when an agent only knows the visible label:

```elixir
:ok = SpectreLens.act(tab, {:navigate, text: "Latest articles"})
:ok = SpectreLens.act(tab, {:click, text: "Latest articles"})
```

Use `:navigate` when you want to move to the link URL. Use `:click` when you
want the page element's click behavior, such as hash scrolling, JavaScript
handlers, or UI state changes. If you already have a link map from `view.links`,
that map is still a valid ref:

```elixir
:ok = SpectreLens.act(tab, {:navigate, link})
:ok = SpectreLens.act(tab, {:click, ref: link})
```

Direct navigation is simplest when you already know the URL:

```elixir
:ok = SpectreLens.act(tab, {:navigate, "https://elchemista.com/en/post/example"})
```

Raw protocol commands are still available:

```elixir
{:ok, version} = SpectreLens.cdp(tab, "Browser.getVersion")
```

## Exports

```elixir
{:ok, png} = SpectreLens.export(tab, :screenshot)
{:ok, html} = SpectreLens.export(tab, :html)
{:ok, markdown} = SpectreLens.export(tab, :markdown)
{:ok, pdf} = SpectreLens.export(tab, :pdf)
```

Pass `:path` or `:to` to write an export directly to disk:

```elixir
{:ok, "tmp/page.png"} = SpectreLens.export(tab, :screenshot, path: "tmp/page.png")
{:ok, "tmp/page.pdf"} = SpectreLens.export(tab, :pdf, path: "tmp/page.pdf")
{:ok, "tmp/page.html"} = SpectreLens.export(tab, :html, to: "tmp/page.html")
```

PDF uses `Page.printToPDF`. If the active browser does not support it, Spectre
Lens returns:

```elixir
{:error, %SpectreLens.UnsupportedError{feature: :pdf}}
```

## Watchers

```elixir
{:ok, watcher} =
  SpectreLens.watch(tab,
    every: 2_000,
    include: [:markdown, :interactive]
  )

receive do
  {:spectre_lens_watch, _pid, :initial, view} -> view
  {:spectre_lens_watch, _pid, :changed, view} -> view
  {:spectre_lens_watch, _pid, :error, reason} -> reason
end

:ok = SpectreLens.stop_watch(watcher)
```

## Errors

Public API edges catch raised, thrown, and exited failures and return tagged
errors.

```elixir
case SpectreLens.act(tab, {:click, ref: "#missing"}) do
  :ok ->
    :ok

  {:error, reason} ->
    SpectreLens.explain_error(reason)
end
```

`SpectreLens.explain_error/1` returns an agent-readable map:

```elixir
%{
  type: :element_not_found,
  message: "element not found: \"#missing\"",
  retryable?: true,
  hint: "Refresh the page map with zoom_out/2...",
  operation: nil,
  target: "#missing",
  details: %SpectreLens.ElementNotFoundError{}
}
```

## Telemetry

Spectre Lens emits telemetry events but does not attach loggers.

Examples:

- `[:spectre_lens, :cdp, :command, :start]`
- `[:spectre_lens, :cdp, :command, :stop]`
- `[:spectre_lens, :page, :operation, :stop]`
- `[:spectre_lens, :agent, :llms, :stop]`
- `[:spectre_lens, :watcher, :changed]`

List all events:

```elixir
SpectreLens.Telemetry.events()
```

Attach your own handlers with `:telemetry.attach/4` or
`:telemetry.attach_many/4` from your application.

## Testing

Run the standard suite:

```sh
mix test
mix credo --strict
mix dialyzer
```

Integration tests require a local Lightpanda binary and are gated:

```sh
SPECTRE_LENS_INTEGRATION=1 mix test
```

## Credits

Spectre Lens is built from scratch, but it was inspired by the shape and spirit
of browser automation work around Lightpanda.

Credits and thanks:

- [`lessless/light_cdp`](https://github.com/lessless/light_cdp) for inspiration
  around small Elixir CDP primitives.
- [Lightpanda](https://lightpanda.io/) for the browser and its agent-friendly
  `LP.*` capabilities.
