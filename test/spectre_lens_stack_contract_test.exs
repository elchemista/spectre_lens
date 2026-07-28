defmodule SpectreLens.StackContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Stack.Contract.V1
  alias Spectre.Stack.Definition
  alias Spectre.Stack.Runtime
  alias SpectreLens.Protocol.LightpandaCDP
  alias SpectreLens.StackContractStack
  alias SpectreLens.URLPolicy

  test "publishes the versioned perception package manifest" do
    assert SpectreLens.version() == "0.1.2"
    assert {:ok, package} = V1.verify_installable(Spectre.Lens)
    assert package.id == :lens
    assert package.version == "0.1.2"
    assert package.spectre == "~> 0.1.2"
    assert package.provides == [{:service, :lens}]
    assert package.operations == []
    assert package.actions == []
    assert package.resources == []
    assert package.metadata == %{role: :perception}
  end

  test "compiles backend and policy as immutable package-owned data" do
    assert {:ok, installation} =
             Definition.installation(StackContractStack, :lens)

    assert installation.config == %{
             options: [trust: :untrusted],
             backend: %{
               module: LightpandaCDP,
               options: [instances: 2, network_policy: :public]
             },
             policy: %{module: URLPolicy, options: []}
           }

    assert {:ok, reference} =
             Definition.resolve(StackContractStack, :service, :lens)

    assert reference.package == :lens
  end

  test "does not claim operations or start an unscoped browser runtime" do
    assert {:ok, []} = Runtime.child_specs(StackContractStack)
  end
end
