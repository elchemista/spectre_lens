# Migrating Lens to Spectre core 0.4

This guide describes the implemented `feature/stack-tools-0.4` branch, paired
with core `feature/agent-server-gam`. Core 0.4 is unreleased here; satellite
version numbers remain independent. Use the Git/path dependencies in the
[current README](../README.md), not an assumed published Hex version.

## What changes from core 0.3

| Concern | Existing 0.3 application | Core 0.4 application |
| --- | --- | --- |
| Installation | Stack package configuration | Same package registration plus optional `tools/1` descriptor |
| Recognition | Flows and route strategies | Agent keeps declaration-only routes and classifiers |
| Application behavior | Flow bodies / Instance and Run continuation | `Spectre.Server` callbacks and queued commands |
| Tool entry | Direct call / Action provider | Generated helper schedules a command; no import from package |
| Results | Immediate value or Invocation resumption | `handle_result(tag, result, ctx)` after worker result acquisition |
| Effects | Legacy application policies | Automatic AgentServer GAM lifecycle and registered effect adapter |
| Durability | Legacy Run/Instance projection | Server checkpoint, inbox/outbox and typed portable results |

The migration does **not** remove `SpectreLens.open`, native Tabs, views, browser protocols, sessions and exports. Direct calls do not acquire
Server semantics merely because the package is installed. Keep standalone
workflows explicitly caller-owned. Historical examples remain in
[the legacy guide](LEGACY_0_3.md).

## Server callbacks

`use Spectre.Server, tools: MyApp.AI` generates helpers from the installed Stack.
Return the context produced by a helper; the result arrives later through
`handle_result/3` using its `on_result:` tag. Keep process handles outside durable
arguments and assigns. The [core tool guide](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/STACK_TOOLS.md) defines validation, checkpointing and recovery.

## From Action provider to explicit Server helpers

The 0.3 provider integration staged browser Actions through Instance/Run.
The provider remains available, but new Server code uses the helpers generated
from the installed descriptor. Native `SpectreLens` calls are still immediate
caller-owned APIs; they are not implicitly checkpointed or admitted by GAM.

| Operation | Scheduling | Result passed to handle_result |
| --- | --- | --- |
| `open` | Cognitive, `retry: :never` | `{:ok, portable_tab}` |
| `look` | Cognitive, `retry: :safe` | `{:ok, untrusted_view_map}` |
| `close` | Cognitive, `retry: :never` | `{:ok, %{closed: true}}` |
| `act` | Governed, explicit `bind:` | `{:governed, result}` / pending consent |

`open`, `look`, `close` are the explicit helper surface. Direct Lens APIs such
as export/discovery remain available; registration does not invent helpers for
every public function. Model-facing Action provider exposure is separately
controlled by `planner_exposure:`.

## Governed browser actions

Install `Spectre.Lens, bind: [act: :browser_action]`, retain your backend/policy
block, and configure `gam: [operations: %{browser_action: [confirm: true]}]` at
AgentServer startup. Spectre owns the Domain, presentation and registered effect
execution. `handle_action/2` can add application checks for tab/target/action;
it cannot perform the browser effect before admission.

`args` is the prepared plain map with `"tab"` and `"action"`; it is not an
arbitrary native Tab, PID, JavaScript expression or runtime configuration.
Supported action types are `navigate`, `click`, `fill`, `submit`, `scroll`.
Declared schemas reject additional runtime controls before browser access.

## Resource lifecycle and observation trust

The named Stack runtime owns browsers; durable tab maps identify resources but
are not ownership capabilities. Hosts sharing a runtime must enforce their own
tab ownership boundary. Do not persist live Tabs, cookies or connections in
Server assigns. Close known tabs explicitly and arrange abandonment cleanup.
An uncertain open/close returns `{:tool_unknown, details}`; it is not safe to
blindly repeat an allocation just because its result was lost.

The observation projection includes `trust: :untrusted` and an escaped context
representation. Treat all site text as external data. Default public URL policy
checks and egress controls remain necessary independently of GAM consent.
The [standalone guide](STANDALONE.md) explains protocols, sessions and exports.


## Migration checklist

1. Pin compatible core and package feature revisions; keep the old dependency
   lockfile available for rollback.
2. Separate Stack installation, Agent routes and Server callbacks.
3. Replace legacy flow effects with explicit helper commands/result handlers;
   retain direct APIs only where caller-owned execution is intentional.
4. Configure named resources and trusted identity required by the package.
5. Configure allowed operations and confirmation in AgentServer; use
   `handle_action/2` for business checks. Spectre constructs GAM records and runs
   the registered executor only after admission.
6. Test refused, uncertain and interrupted paths as well as successful results;
   verify portable snapshots before deploying existing conversations.
7. Review checkpoint/installation changes explicitly; never replay a potentially
   executed effect just to work around a migration error.

## Reusable Skill servers

The same helper works in a mounted Skill Server. Configure GAM on the root;
the mount's `governed:` references restrict its effect operations. Skills share
the root Domain while keeping their own state and checkpoints. See the
[Skill guide](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/SKILLS.md) for setup and consent routing.

### Runtime ownership and teardown

Keep the caller-owned Stack runtime alive for the lifetime of the Agent and its
Skills. Stopping that supervisor closes its Lens tabs and browser instances.
Standalone runtimes also close when their owning caller exits. The 0.4 branch
now explicitly handles owner exit after safe startup; a post-start link alone
was insufficient to run cleanup during supervisor shutdown. Regressions cover
normal owner exit and supervised cleanup of two actual Lightpanda processes.

## Require GAM consent for navigation

`open(url)` and `look(url)` can both navigate. Applications requiring consent
for browsing can bind them to their existing managed GAM operations:

```elixir
install Spectre.Lens,
  bind: [open: :browser_open, look: :browser_look, act: :browser_act] do
  backend(MyApp.Browser)
end
```

Lens requires paired `open`/`look` bindings when either is selected, plus distinct
host operation names. The helpers retain the same arguments and portable
results. Enable the operations in the root `gam.operations` and apply the
required consent policy to each. They execute through the existing provider
only after admission, without retrying uncertain browser effects. `close` still
releases a known resource. Existing installations without navigation bindings
retain cognitive `open`/`look` behavior; native provider APIs remain host APIs.

For approvals in a different person's agent chat, see the
[Pulse external consent guide](https://github.com/elchemista/spectre_pulse/blob/feature/stack-tools-0.4/docs/EXTERNAL_APPROVALS.md).
