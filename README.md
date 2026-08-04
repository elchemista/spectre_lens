# Spectre Lens

Agent-first, backend-neutral browser perception for Elixir.

Spectre Lens separates browser lifecycle from page semantics. A
`SpectreLens.Browser` backend starts, connects, monitors, and stops browser
instances; a `SpectreLens.Protocol` adapter implements tabs, views, actions,
exports, sessions, and events. Lightpanda is the default local backend, not a
dependency of the Lens runtime contract.

Lens has no compile-time or runtime dependency on `:spectre`. Its direct
browser, perception, session, and export APIs work as a standalone library.
The repository uses Spectre from GitHub only in the test environment to verify
the optional late-bound Stack and Action-provider integration.

The exact `0.2.0` compatibility surface is published in the
[public API manifest](docs/PUBLIC_API.md).

## 0.2.0 Spectre Compatibility

Version `0.2.0` aligns Lens's package, Action provider, and Stack contracts
with Spectre `~> 0.2.0`. Browser processes remain caller-owned runtime
resources; Spectre checkpoints retain only portable references and continue to
own policy, idempotency, Effect execution, and operational-loop state.

## 0.1.6 Recoverable Baseline

Version `0.1.6` is a consolidation-only release with no new runtime feature and
no intentional breaking change. Elixir 1.19 on Erlang/OTP 28 is the initially
guaranteed pair. Uniform CI runs format, warnings-as-errors compilation, tests,
non-strict Credo, Dialyzer, ExDoc, and local package validation with no
publication. Its explicit API
manifest is the compatibility fence while Lens participates in later `0.2.0`
work.

## Features

- Start local browser processes or connect to external endpoints and balance
  tabs according to backend capacity.
- Navigate, click, fill, submit, scroll, wait for selectors, and send raw CDP.
- Extract agent-readable views: markdown, HTML, semantic tree, forms, links,
  structured data, interactive elements, and action refs.
- Describe page layout in words with `zoom_out/2`, `zoom_in/3`, and `unfocus/2`.
- Run goal-scoped site discovery with deterministic or custom pluggable scoring.
- Export screenshots, HTML, markdown, and PDF when the browser supports it.
- Discover and parse `llms.txt` / `llms-full.txt` context for agents.
- Opt in to page-advertised `llms.txt` context through metadata or HTTP `Link`
  headers.
- Return agent-friendly errors instead of crashing at public API edges.
- Emit payload-redacted telemetry events without attaching loggers or writing logs.

## Installation

Add the package to your Mix project once published or through a local/path
dependency while developing:

```elixir
def deps do
  [
    {:spectre_lens, github: "elchemista/spectre_lens"}
  ]
end
```

Install or inspect the optional local Lightpanda binary:

```sh
mix spectre.lens.install --channel nightly --out ~/.local/bin --force
mix spectre.lens.doctor
```

The installer resolves the platform asset from Lightpanda's official GitHub
release metadata, requires its published SHA-256 digest, validates the browser
version, and atomically replaces the destination only after every check passes.
For a trusted mirror, pass both `--url` and `--sha256`.

Starting a runtime never downloads a browser binary. Provision Lightpanda
yourself or run the installer task explicitly before `SpectreLens.open/1`.
Lens 0.2.0 requires Lightpanda `1.0.0-nightly.8362` or newer when the local
Lightpanda backend is selected.

You can also point Spectre Lens at an existing binary:

```elixir
{:ok, lens} = SpectreLens.open(binary: "/path/to/lightpanda")
```

The path can also be configured with `config :spectre_lens,
:lightpanda_path, "/path/to/lightpanda"` or `LIGHTPANDA_PATH`.

## Optional Spectre Stack Integration

When an application separately includes Spectre 0.2.0, it can install Lens with
a package-local, immutable configuration:

```elixir
defmodule MyApp.AI do
  use Spectre.Stack

  install Spectre.Lens, planner_exposure: [:look, :discover] do
    backend SpectreLens.Browsers.Lightpanda,
      instances: 2,
      protocol: SpectreLens.Protocol.Lightpanda

    policy MyApp.WebPolicy
  end
end

defmodule MyApp.Agent do
  use Spectre.Agent, stack: MyApp.AI
end
```

Selecting the Stack automatically binds Lens configuration and its real
`:open`, `:look`, `:discover`, `:act`, and `:export` Action provider. Operations
are deterministic-only by default; `planner_exposure:` opts selected operations
into model planning. A second `use Spectre.Lens` is not required.

Browser processes are isolated caller-owned Stack resources. Start the runtime
explicitly so binary paths and other runtime-only values never enter the
compiled definition:

```elixir
{:ok, stack_runtime} =
  Spectre.Stack.start_link(MyApp.AI,
    packages: [
      lens: [binary: "/opt/lightpanda"]
    ]
  )

{:ok, lens_runtime} =
  Spectre.Lens.runtime(MyApp.Agent, stack_runtime: stack_runtime)
```

Pass `stack_runtime:` through the Spectre execution options when a staged Lens
Action is dispatched. Spectre owns policy, approval, idempotency, and the
effect lifecycle; the declared Lens policy is checked again at the browser
boundary. Journal records contain operation/outcome metadata but never CDP
payloads, HTML, cookies, screenshots, or credentials.

The `:open` Action returns a portable `%SpectreLens.TabRef{}`. Subsequent
`:look`, `:act`, and `:export` Actions accept that reference and resolve the
live `%SpectreLens.Tab{}` from the explicitly supplied runtime. Connection and
request-guard PIDs therefore never enter Spectre State or a checkpointed
`Spectre.Run`.

### Agent Instance boundary

For subject continuity, the application submits turns to the unique
core-owned Instance and supplies an explicitly started Stack runtime only when
a staged Lens Action is executed:

```elixir
{:ok, instance} =
  Spectre.instance(MyApp.SpectreSupervisor, MyApp.Agent, account_id)

{:ok, turn} =
  Spectre.turn(instance, "inspect the account page",
    stack_runtime: stack_runtime
  )
```

Lens contributes perception Actions plus a caller-owned browser resource. It
does not create or look up Agent Instances, enqueue Runs, retain Agent State,
own the ready queue or Invocation registry, or autonomously schedule browser
work. The Instance retains only portable values such as `TabRef`; live browser
processes remain outside Runs and checkpoints. `wake on_change`, autonomous
world observation, and continuity-plane lifecycle are later phases and are not
duplicated by Lens 0.2.0.

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
view.trust # :untrusted

{:ok, agent_context} = SpectreLens.agent_context(view)

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

## Network and Agent Safety

The default `network_policy: :public` is designed for agent-controlled URLs. It
allows only absolute HTTP(S) URLs, rejects embedded credentials and non-standard
ports, resolves hostnames before use, and blocks loopback, private, link-local,
reserved, multicast, and common cloud-metadata destinations. With the built-in
CDP protocol, request interception applies the same policy to redirects and page
subrequests.

Local development servers require an explicit opt-out:

```elixir
{:ok, lens} = SpectreLens.open(network_policy: :any)
{:ok, tab} = SpectreLens.new_tab(lens, url: "http://127.0.0.1:4000")
```

You can extend the public-policy port allowlist with `allowed_ports: [80, 443,
8443]`. `network_policy: :any` still rejects unsupported URL schemes and URL
credentials.

This library-level policy does not claim DNS-rebinding protection. Production
deployments should also isolate browser egress and deny private/metadata ranges
at the network layer.

Top-level agent-facing projections (`View`, `LlmsTxt`, `Discovery`, `PageMap`,
and `Outline`) carry `trust: :untrusted`. Use
`SpectreLens.agent_context/2` before inserting a view, outline, page map, or
discovery result into a model context; it adds a stable prompt-injection trust
boundary. `llms_context/2` and discovery text are wrapped automatically. Raw
projection fields remain available for parsing and storage.

Form projections omit hidden inputs and all current/default values, including
email, CSRF, checkbox, and selected-option values. Telemetry uses an allowlist
of structural metadata and never includes CDP results, HTML, cookies, storage,
screenshots, PDFs, or exception payloads.

## Browser Backends and Protocols

The two adapter layers are deliberately independent:

| Layer | Owns | Built-in adapters |
| --- | --- | --- |
| `SpectreLens.Browser` | allocation, endpoint connection, health, capacity, shutdown | `SpectreLens.Browsers.Lightpanda`, `SpectreLens.Browsers.RemoteCDP` |
| `SpectreLens.Protocol` | tabs, navigation, projections, actions, exports, sessions, events | `SpectreLens.Protocol.Lightpanda`, `SpectreLens.Protocol.CDP` |

The generic CDP protocol uses standard CDP domains and DOM JavaScript only.
The Lightpanda protocol delegates normal CDP operations to it and optimizes
markdown, semantic trees, interactive elements, and structured data through
the current `LP.*` domain. A Playwright, WebDriver BiDi, ExGram bridge, ExWapp
bridge, or hosted browser can be added without changing the runtime scheduler:
implement the backend contract, the protocol contract, or both.

Connect to an already-running CDP service without giving Lens ownership of its
process:

```elixir
{:ok, lens} =
  SpectreLens.open(
    backend: SpectreLens.Browsers.RemoteCDP,
    protocol: SpectreLens.Protocol.CDP,
    endpoint: "http://127.0.0.1:9222",
    max_tabs_per_instance: 8
  )
```

Closing this runtime closes only its CDP connection. It never terminates the
external browser. `endpoints: [...]` can provide one endpoint per configured
instance.

For a new integration, `use SpectreLens.Browser.Adapter, protocol: MyProtocol`
supplies protocol and capacity defaults while the module implements allocation
and shutdown. `use SpectreLens.Protocol.Adapter` supplies explicit
`UnsupportedError` defaults for every page capability, so an ExGram, ExWapp, or
other bridge can implement incrementally without an incomplete runtime
contract. Lens validates both adapters before allocating any browser resource.

Page inspection remains independently extensible: `SpectreLens.look/2` runs
`SpectreLens.PlugPipeline`. Add application-wide plugs with
`config :spectre_lens, :plugs, [...]`, or per-call plugs with `plugs: [...]`.
This lets integrations enrich or normalize views without modifying the browser
backend or protocol.

With the local Lightpanda backend:

- `instances: n` starts `n` Lightpanda browser processes.
- Each Lightpanda instance supports one live tab at a time.
- Concurrent tabs require multiple instances.
- `max_tabs_per_instance` is ignored for Lightpanda because Lightpanda rejects a
  second live CDP target with `TargetAlreadyLoaded`.
- When all Lightpanda instances already have a live tab, `new_tab/2` returns
  `{:error, :tab_capacity_exceeded}`.
- Browser exit and CDP connection events are monitored and stop the owning
  runtime with an instance-scoped reason.

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

### Current Lightpanda serve options

Lens 0.2.0 uses the current `serve` interface (`--http-timeout` and
`--watchdog-ms`; the removed legacy `--timeout` flag is never emitted). It
binds to loopback by default, disables the metrics endpoint, obeys
`robots.txt`, and enables Lightpanda's private-network blocking for the default
public network policy.

Common runtime options include CDP connection/message limits, HTTP
timeouts/response limits, proxy settings, CA files, cookies, storage/cache,
subframe and worker controls, logging, user-agent configuration, V8 heap and
watchdog controls, WebSocket concurrency, and Web Bot Auth. Raw `serve_args`
may carry future Lightpanda options, but cannot override flags managed by Lens.
Binding a non-loopback host requires `allow_remote_bind: true`.

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
  llms: nil,
  llms_context: nil,
  actions: [],
  trust: :untrusted,
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

With `SpectreLens.Protocol.Lightpanda`, `semantic_tree` and `semantic_text` use
Lightpanda's native semantic projection. With `SpectreLens.Protocol.CDP`, they
are derived from the standard CDP accessibility tree:

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

Page-advertised `llms.txt` discovery is disabled by default. Enable it
explicitly:

```elixir
SpectreLens.look(tab, llms?: true)
# or
SpectreLens.look(tab, include: [:markdown, :llms])
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

The returned string is enclosed in an `UNTRUSTED WEB CONTENT` boundary. For
non-agent parsing or storage, request the raw document explicitly with
`raw?: true`.

From an open tab:

```elixir
{:ok, doc} = SpectreLens.llms(tab)
{:ok, markdown} = SpectreLens.llms_context(tab, prefer: :both)
```

When `look/2` is explicitly opted in, Spectre Lens checks:

- `<link href="/llms.txt" rel="llms.txt">`
- `<meta name="llms" content="/llms.txt">`
- HTTP `Link` headers such as `</llms.txt>; rel="llms.txt"`
- fallback candidate paths such as `/llms.txt`, `/llms-full.txt`, and
  `/llms-ctx-full.txt`

Page-advertised URLs must be same-origin by default. Set
`allow_cross_origin_llms?: true` only for sites whose external agent context you
trust; the network policy still validates every fetch and redirect.

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

Spectre Lens emits telemetry events but does not attach loggers. Metadata is
allowlisted and payload-redacted: stop events report `:outcome` and
`:error_kind`, never the full command result or exception.

Examples:

- `[:spectre_lens, :cdp, :command, :start]`
- `[:spectre_lens, :cdp, :command, :stop]`
- `[:spectre_lens, :page, :operation, :stop]`
- `[:spectre_lens, :agent, :llms, :stop]`
- `[:spectre_lens, :network, :blocked]`
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
