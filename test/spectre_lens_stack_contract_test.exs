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
    assert SpectreLens.version() == "0.1.5"
    assert {:ok, package} = V1.verify_installable(Spectre.Lens)
    assert package.id == :lens
    assert package.version == "0.1.5"
    assert package.spectre == "~> 0.1.5"
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

  test "DSL compilation accepts each declaration form and rejects ambiguous configuration" do
    block =
      quote do
        backend(SpectreLens.BrowserRuntimeTest.FakeBackend,
          instances: 3,
          network_policy: :any
        )

        policy(SpectreLens.URLPolicy)
      end

    assert {:ok, config} =
             Spectre.Lens.compile([planner_exposure: :all], block, __ENV__)

    assert config == %{
             options: [planner_exposure: :all],
             backend: %{
               module: SpectreLens.BrowserRuntimeTest.FakeBackend,
               options: [instances: 3, network_policy: :any]
             },
             policy: %{module: SpectreLens.URLPolicy, options: []}
           }

    assert {:ok, %{backend: nil, policy: nil, options: [trust: :untrusted]}} =
             Spectre.Lens.compile([trust: :untrusted], nil, __ENV__)

    duplicate =
      quote do
        backend(SpectreLens.Browsers.RemoteCDP)
        backend(SpectreLens.Browsers.Lightpanda)
      end

    assert_raise ArgumentError, ~r/backend may only be declared once/, fn ->
      Spectre.Lens.compile([], duplicate, __ENV__)
    end

    non_keyword =
      quote do
        policy(SpectreLens.URLPolicy, [:not_keyword])
      end

    assert_raise ArgumentError, ~r/options must be a keyword list/, fn ->
      Spectre.Lens.compile([], non_keyword, __ENV__)
    end

    invalid_module =
      quote do
        backend("not-a-module")
      end

    assert_raise ArgumentError, ~r/must be a module with keyword options/, fn ->
      Spectre.Lens.compile([], invalid_module, __ENV__)
    end
  end

  test "child specs merge declared, installation and caller runtime options in order" do
    installation = %{
      id: :custom_lens,
      config: %{
        backend: %{
          module: SpectreLens.BrowserRuntimeTest.FakeBackend,
          options: [instances: 2, endpoint: "declared"]
        },
        policy: nil,
        options: [instances: 3, network_policy: :public]
      }
    }

    assert [{{:lens, :runtime}, child_spec}] =
             Spectre.Lens.child_specs(
               installation,
               instances: 4,
               network_policy: :any
             )

    assert {SpectreLens.Runtime, :start_link, [opts]} = child_spec.start
    assert child_spec.id == {:spectre_lens_runtime, :custom_lens}
    assert opts[:backend] == SpectreLens.BrowserRuntimeTest.FakeBackend
    assert opts[:endpoint] == "declared"
    assert opts[:instances] == 4
    assert opts[:network_policy] == :any

    no_backend = %{
      installation
      | id: :default_lens,
        config: %{installation.config | backend: nil}
    }

    assert [{{:lens, :runtime}, default_spec}] = Spectre.Lens.child_specs(no_backend, [])
    assert {SpectreLens.Runtime, :start_link, [default_opts]} = default_spec.start
    refute Keyword.has_key?(default_opts, :backend)
  end

  test "runtime binding accepts explicit handles and fails clearly without a Stack resource" do
    runtime = %SpectreLens.Runtime{pid: self()}
    assert {:ok, ^runtime} = Spectre.Lens.runtime(StackContractAgent, lens_runtime: runtime)
    assert {:ok, pid} = Spectre.Lens.runtime(StackContractAgent, lens_runtime: self())
    assert pid == self()

    assert {:error, {:invalid_lens_runtime, :invalid}} =
             Spectre.Lens.runtime(StackContractAgent, lens_runtime: :invalid)

    assert {:error, :lens_runtime_required} = Spectre.Lens.runtime(StackContractAgent)

    assert {:error, :lens_stack_required} =
             Spectre.Lens.runtime(
               SpectreLens.NoStackContractAgent,
               stack_runtime: self()
             )

    {:ok, empty_supervisor} = Supervisor.start_link([], strategy: :one_for_one)

    assert {:error, _reason} =
             Spectre.Lens.runtime(
               StackContractAgent,
               stack_runtime: empty_supervisor
             )

    Supervisor.stop(empty_supervisor)

    assert {:error, _reason} = Spectre.Lens.config(SpectreLens.NoStackContractAgent)
  end
end
