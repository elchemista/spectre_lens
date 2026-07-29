defmodule SpectreLens.RunConformanceTest do
  use ExUnit.Case, async: true

  alias Spectre.Action
  alias Spectre.Context
  alias Spectre.Effect
  alias Spectre.Input
  alias Spectre.Lens.ActionProvider
  alias Spectre.Run
  alias Spectre.State
  alias Spectre.State.Codec
  alias SpectreLens.StackContractAgent
  alias SpectreLens.Tab
  alias SpectreLens.TabRef
  alias SpectreLens.URLPolicy

  test "TabRef is portable while the process-local Tab is rejected by Run checkpoints" do
    tab = %Tab{
      conn: self(),
      runtime: self(),
      request_guard: self(),
      instance_id: 1,
      target_id: "target-1",
      session_id: "session-1"
    }

    assert {:ok, %TabRef{} = ref} = TabRef.new(tab)
    assert TabRef.matches?(ref, tab)

    portable_effect =
      %{name: :open, args: %{url: "https://example.com"}, payload: %{via: :lens}}
      |> Effect.stage_action(StackContractAgent, :agent)
      |> Effect.complete(ref)

    portable_run =
      Run.new(
        StackContractAgent,
        Input.new("open"),
        %State{planned_effects: [portable_effect]}
      )

    assert {:ok, checkpoint} = Run.checkpoint(portable_run)
    assert {:ok, restored} = Run.restore(checkpoint)
    assert hd(restored.state.planned_effects).result == ref
    assert {:ok, encoded_state} = Codec.encode(portable_run.state)
    assert {:ok, restored_state} = Codec.decode(encoded_state)
    assert hd(restored_state.planned_effects).result == ref

    local_effect = Effect.complete(portable_effect, tab)
    local_run = %{portable_run | state: %State{planned_effects: [local_effect]}}

    assert {:error, {:nonportable_run_value, _path, :pid}} = Run.checkpoint(local_run)
    assert {:error, {:unsupported_state_value, :pid}} = Codec.encode(local_run.state)
  end

  test "a declared but unavailable or invalid Lens policy fails closed before runtime access" do
    policy = SpectreLens.RunConformanceTest.MissingPolicy

    action =
      Action.new(:look,
        via: :lens,
        args: %{url: "https://example.com"}
      )

    context = %Context{agent: StackContractAgent, opts: []}
    config = %{options: [], backend: nil, policy: %{module: policy, options: []}}

    assert {:error, {:lens_policy_unavailable, ^policy}} =
             ActionProvider.execute(action, context, config: config)

    invalid_policy = SpectreLens.RunConformanceTest.InvalidPolicy
    invalid_config = put_in(config, [:policy, :module], invalid_policy)

    assert {:error, {:invalid_lens_policy, ^invalid_policy, :authorize}} =
             ActionProvider.execute(action, context, config: invalid_config)
  end

  test "the built-in URL policy satisfies the Stack authorization contract" do
    action =
      Action.new(:open,
        via: :lens,
        args: %{url: "file:///etc/passwd"}
      )

    context = %Context{agent: StackContractAgent, opts: []}
    config = %{options: [], backend: nil, policy: %{module: URLPolicy, options: []}}

    assert {:error, {:unsupported_url_scheme, "file"}} =
             ActionProvider.execute(action, context, config: config)
  end
end

defmodule SpectreLens.RunConformanceTest.InvalidPolicy do
  @moduledoc false

  def loaded?, do: true
end
