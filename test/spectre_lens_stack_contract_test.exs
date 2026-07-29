defmodule SpectreLens.StackContractAgent do
  @moduledoc false

  use Spectre.Agent, stack: SpectreLens.StackContractStack
end

defmodule SpectreLens.StackContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Action.Provider
  alias Spectre.Stack.Contract.V1
  alias Spectre.Stack.Definition
  alias Spectre.Stack.Runtime
  alias SpectreLens.Browsers.Lightpanda
  alias SpectreLens.Protocol
  alias SpectreLens.StackContractAgent
  alias SpectreLens.StackContractStack
  alias SpectreLens.URLPolicy

  test "publishes the versioned perception package manifest" do
    assert SpectreLens.version() == "0.1.3"
    assert {:ok, package} = V1.verify_installable(Spectre.Lens)
    assert package.id == :lens
    assert package.version == "0.1.3"
    assert package.spectre == "~> 0.1.3"
    assert package.provides == [{:service, :lens}]
    assert package.operations == []

    assert package.actions == [
             {:lens, :open},
             {:lens, :look},
             {:lens, :discover},
             {:lens, :act},
             {:lens, :export}
           ]

    assert package.resources == [{:lens, :runtime}]
    assert package.agent_extensions == [Spectre.Lens.Extension]
    assert package.metadata == %{role: :perception}
  end

  test "compiles backend and policy as immutable package-owned data" do
    assert {:ok, installation} =
             Definition.installation(StackContractStack, :lens)

    assert installation.config == %{
             options: [trust: :untrusted],
             backend: %{
               module: Lightpanda,
               options: [
                 instances: 2,
                 network_policy: :public,
                 protocol: Protocol.Lightpanda
               ]
             },
             policy: %{module: URLPolicy, options: []}
           }

    assert {:ok, reference} =
             Definition.resolve(StackContractStack, :service, :lens)

    assert reference.package == :lens
  end

  test "selecting the Stack installs Lens configuration and its action provider" do
    assert {:ok, config} = Spectre.Lens.config(StackContractAgent)
    assert config.backend.module == Lightpanda
    assert StackContractAgent.__spectre_definition__().config[:lens] == config

    assert {:ok, provider} = Spectre.ActionConfig.provider(StackContractAgent, :lens)
    assert provider.module == Spectre.Lens.ActionProvider
    assert {:ok, specs} = Provider.actions(provider, :all)
    assert Enum.map(specs, & &1.name) == [:open, :look, :discover, :act, :export]
    assert Enum.all?(specs, &(&1.visibility == :deterministic))
  end

  test "declares an isolated caller-owned browser runtime resource" do
    assert {:ok, ref} =
             Definition.resolve(StackContractStack, :resource, {:lens, :runtime})

    assert ref.package == :lens
    assert {:ok, [child_spec]} = Runtime.child_specs(StackContractStack)

    assert {SpectreLens.Runtime, :start_link, [runtime_opts]} = child_spec.start
    assert runtime_opts[:instances] == 2
    assert runtime_opts[:network_policy] == :public
    assert runtime_opts[:backend] == Lightpanda
    assert runtime_opts[:protocol] == Protocol.Lightpanda
    assert runtime_opts[:trust] == :untrusted
  end
end
