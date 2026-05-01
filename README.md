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
{:ok, lens} = SpectreLens.open(instances: 2, max_tabs_per_instance: 8)
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

:ok = SpectreLens.act(tab, {:fill, ref: "#q", value: "spectre"})
:ok = SpectreLens.act(tab, {:click, ref: "button[type=submit]"})

{:ok, png} = SpectreLens.export(tab, :screenshot)

:ok = SpectreLens.close(lens)
```

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

## Actions

Actions accept selectors, node ids, maps, and `%SpectreLens.ActionRef{}` values
generated in `view.actions`.

```elixir
:ok = SpectreLens.act(tab, {:navigate, "https://example.com"})
:ok = SpectreLens.act(tab, {:click, ref: "#login"})
:ok = SpectreLens.act(tab, {:fill, ref: "#email", value: "agent@example.com"})
:ok = SpectreLens.act(tab, {:submit, ref: "#login-form", fields: %{"#password" => "secret"}})
:ok = SpectreLens.act(tab, {:scroll, by: 800})
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
