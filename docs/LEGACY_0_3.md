# Historical Spectre 0.3 integration

These examples describe the former Instance/Run integration. They are retained
for maintaining existing applications, **not as the starting architecture for
core 0.4 AgentServer applications**. Use the [0.4 migration guide](MIGRATING_TO_SPECTRE_0_4.md)
and [current README](../README.md) for the new Stack → Agent → Server lifecycle.
A `protect`/policy block below is legacy application DSL; installing a package
never supplies a 0.4 GAM host binding or end-user consent.

## Optional Spectre Stack Integration

When an application separately includes Spectre, it can install Lens with a
package-local, immutable configuration:

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

Lens declares closed argument schemas for every operation, so `mix spectre.doctor`
reports `agent.planner_action_schema` as bounded. Approval is the Agent's to
declare, not the package's: pair any planner exposure with a protection so a
model-planned browser action still passes your policy.

```elixir
defmodule MyApp.Agent do
  use Spectre.Agent, stack: MyApp.AI

  protect {:lens, :look}, with: MyApp.BrowsingApproval
  protect {:lens, :discover}, with: MyApp.BrowsingApproval
end
```

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

Action arguments are plain JSON, because Spectre validates them against a
bounded JSON-Schema subset before dispatch. The `:open` Action returns the
portable tab projection `SpectreLens.TabRef.to_map/1` produces; `:look`,
`:act`, and `:export` accept it back and resolve the live `%SpectreLens.Tab{}`
from the explicitly supplied runtime. Connection and request-guard PIDs
therefore never enter Spectre State or a checkpointed `Spectre.Run`.

```elixir
{:ok, tab} = # result of the :open Action
  # %{"id" => "…", "instance_id" => 1, "target_id" => "…", …}

Spectre.Action.new(:act,
  via: :lens,
  args: %{
    "tab" => tab,
    "action" => %{"type" => "click", "text" => "Sign in"},
    "opts" => %{"timeout" => 5_000}
  }
)
```

A browser action is an object with a `"type"` of `navigate`, `click`, `fill`,
`submit`, or `scroll` plus the target keys it needs (`ref`, `href`, `text`,
`name`, `label`, `title`, `value`, `form`, `fields`, `selector`, `x`, `y`, and
`url` for `navigate`). `opts` is restricted to `timeout`, `max_depth`,
`max_pages`, `max_links_per_page`, `max_candidates`, and `include`; runtime
controls such as `network_policy` belong to the installation and cannot be
widened by a planned Action. The native `%SpectreLens.TabRef{}` and
`{:click, ref}` forms remain the contract of the `SpectreLens` API itself.

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
duplicated by Lens.
