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
| Effects | Legacy application policies | Host GAM candidate, presentation, consent and admitted executor |
| Durability | Legacy Run/Instance projection | Server checkpoint, inbox/outbox and typed portable results |

The migration does **not** remove `SpectreLens.open`, native Tabs, views, browser protocols, sessions and exports. Direct calls do not acquire
Server semantics merely because the package is installed. Keep standalone
workflows explicitly caller-owned. Historical examples remain in
[the legacy guide](LEGACY_0_3.md).

## Registration and callback lifecycle

The package's existing `Spectre.Stack.Installable` registration contributes
`tools/1`: a versioned descriptor naming the helper, adapter, default operation
and allowed operations. `use Spectre.Server, tools: MyApp.AI` generates private
helper arities 2 and 3 from the immutable Stack. No package-specific import is
needed, and arbitrary public functions are not exposed automatically.

A helper appends a command to `ctx`; it does not synchronously call the library.
Return that context. Pure adapter preparation validates arguments, Spectre
commits the outbox, then a worker runs the selected cognitive operation or
submits the governed proposal. Projected results are acquired before dispatching
`handle_result/3`. `on_result:` selects the callback tag. Unknown operations and
invalid payloads produce typed rejections; declaration/collision mistakes fail
early. Never put PIDs, functions or provider clients into persisted arguments.

Cognitive `:safe` operations can replay after interruption. `:never` operations
return `{:tool_unknown, details}` after uncertain execution and need application
reconciliation. Governed operations require an explicit host binding and follow
GAM reconciliation; they are not automatically retried as cognitive calls.
Native GenServer callbacks remain available through the Server behavior; return
commands through that boundary rather than bypassing its bookkeeping.

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
block, and configure `:browser_action` in the host's GAM bindings. The host
validates tab/target/action and implements any needed presentation and consent.
After admission, its executor invokes:

```elixir
Spectre.Lens.ServerTool.execute(:act, args,
  %{agent: MyApp.WebAgent, options: [stack_runtime: MyApp.WebRuntime]})
```

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

## GAM and consent

Follow the [Governed Act Model manifesto](https://spectre.guide/en/governed-act-model).
Evidence informs decisions; a Mandate bounds authority; an admitted Act is
recorded before its capability is released. Unresolved obligations remain
represented by Duties. Package installation and model output are neither a
Mandate nor end-user consent.

Spectre's default cognitive calls do not ask permission for every model or
classifier computation. The host chooses the governed surface, which may include
protected disclosure or resource consumption. Effects requiring consent wait in
the Server's pending lifecycle; application handlers can confirm, reject,
suspend, resume or schedule audited closure. A topic change is not consent.

See [core AgentServer](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/AGENT_SERVER.md),
[pending lifecycle](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/PENDING_LIFECYCLE.md) and
[Stack tools](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/STACK_TOOLS.md) for host configuration and recovery.

## Migration checklist

1. Pin compatible core and package feature revisions; keep the old dependency
   lockfile available for rollback.
2. Separate Stack installation, Agent routes and Server callbacks.
3. Replace legacy flow effects with explicit helper commands/result handlers;
   retain direct APIs only where caller-owned execution is intentional.
4. Configure named resources and trusted identity required by the package.
5. Bind governed effects to the host's candidates/executors and consent handling.
6. Test refused, uncertain and interrupted paths as well as successful results;
   verify portable snapshots before deploying existing conversations.
7. Review checkpoint/installation changes explicitly; never replay a potentially
   executed effect just to work around a migration error.
