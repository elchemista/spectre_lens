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
reconciliation. Governed operations require an allowed operation entry in automatic GAM and follow
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
5. Configure allowed operations and confirmation in AgentServer; use
   `handle_action/2` for business checks. Spectre constructs GAM records and runs
   the registered executor only after admission.
6. Test refused, uncertain and interrupted paths as well as successful results;
   verify portable snapshots before deploying existing conversations.
7. Review checkpoint/installation changes explicitly; never replay a potentially
   executed effect just to work around a migration error.

## Reusable Skill servers

Use the Stack-generated `lens` helper in a Skill's ordinary
`Spectre.Server` callbacks. The Agent mounts `Spectre.Skill, server: ...`; each
mount then owns its GenServer, state, workers, streams, pending intentions and
checkpoint key. No package-specific Skill adapter or extra installation is needed.

```text
AgentServer ─────┐
Research Skill ──┼──→ one automatic GAM boundary → same Domain / authority ledger
Knowledge Skill ┘
```

The root creates this connection once and passes it to the children. Do not
bootstrap another Domain, copy the ledger, implement a Skill Host or extend
ingress manually. Mounting grants no authority. Governed effects must satisfy
both root `gam:` operations and the mount's `governed:` references; scoped
Kinetic references keep their complete mounted scope. Ledger/Lab inspect the
calling runtime's checkpoint, not a copy of the shared GAM history.

The shared kernel orders admission while workers can run concurrently. Every
proposal retains its Skill invocation provenance. A confirmation belongs to the
originating mount and exact presentation, so it cannot approve a different
Skill's pending request. Timer expiry and closure enter the same lifecycle
ledger without erasing Acts, uncertain Outcomes or Duties. No per-Skill GAM
configuration is required.

See the [core shared/local ownership table and confirmation example](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/SKILLS.md),
[automatic GAM contract](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/MANAGED_GAM.md)
and [LiveView showcase](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/DEMO.md).

### Runtime ownership and teardown

Keep the caller-owned Stack runtime alive for the lifetime of the Agent and its
Skills. Stopping that supervisor closes its Lens tabs and browser instances.
Standalone runtimes also close when their owning caller exits. The 0.4 branch
now explicitly handles owner exit after safe startup; a post-start link alone
was insufficient to run cleanup during supervisor shutdown. Regressions cover
normal owner exit and supervised cleanup of two actual Lightpanda processes.
