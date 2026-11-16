defmodule Spectre.Lens.ServerToolTest do
  use ExUnit.Case, async: true

  alias Spectre.Lens.ServerTool
  alias SpectreLens.{ActionRef, TabRef, View}

  test "managed catalog exposes only bound act and does not promote browser reads" do
    assert %{} = Spectre.Lens.effects(%{options: []})
    effects = Spectre.Lens.effects(%{options: [bind: [act: :browser_action]]})
    assert %{browser_action: %{adapter: ServerTool, operation: :act}} = effects
    assert map_size(effects) == 1
    assert Spectre.Stack.Effects.validate!(effects) == effects
  end

  test "navigation bindings govern both URL entry points" do
    config = %{options: [bind: [open: :browser_open, look: :browser_look, act: :browser_act]]}
    tools = Spectre.Lens.tools(config)
    assert tools.lens.operations.open.path == :governed
    assert tools.lens.operations.look.path == :governed
    assert tools.lens.operations.close.path == :cognitive
    effects = Spectre.Lens.effects(config)
    assert effects.browser_open.operation == :open
    assert effects.browser_look.operation == :look
    assert Spectre.Stack.Tools.validate!(tools) == tools
    assert Spectre.Stack.Effects.validate!(effects) == effects

    for bind <- [
          [open: :open],
          [look: :look],
          [open: :same, look: :same],
          [open: nil, look: :look]
        ] do
      assert_raise ArgumentError, fn -> Spectre.Lens.tools(%{options: [bind: bind]}) end
    end
  end

  defmodule BrowserProtocol do
    use SpectreLens.Protocol.Adapter

    def new_tab(instance, opts) do
      {:ok,
       %SpectreLens.Tab{
         id: "tool-tab",
         instance_id: instance.id,
         protocol: __MODULE__,
         handle: %{owner: instance.owner},
         url_policy: SpectreLens.URLPolicy.take_options(opts)
       }}
    end

    def navigate(_tab, _url, _opts), do: :ok

    def click(tab, ref, _opts) do
      send(tab.handle.owner, {:browser_clicked, tab.id, ref})
      :ok
    end

    def close_tab(tab) do
      send(tab.handle.owner, {:browser_closed, tab.id})
      if is_pid(tab.runtime), do: SpectreLens.Runtime.release_tab(tab.runtime, tab)
      :ok
    end
  end

  defmodule Browser do
    @behaviour SpectreLens.Browser
    def default_protocol, do: BrowserProtocol

    def start_instance(index, opts),
      do:
        {:ok,
         %SpectreLens.Browser.Instance{
           id: index,
           backend: __MODULE__,
           protocol: BrowserProtocol,
           owner: opts[:test_pid]
         }}

    def stop_instance(_instance), do: :ok
    def max_tabs(_instance, _opts), do: 1
  end

  defmodule Stack do
    use Spectre.Stack

    install Spectre.Lens, bind: [act: :browser_action] do
      backend(Browser, instances: 1)
    end
  end

  defmodule Agent do
    use Spectre.Agent, stack: Stack
  end

  @config %{options: [], backend: nil, policy: nil}

  test "all action types use the same explicit governed binding" do
    tools = Spectre.Lens.tools(%{options: [bind: [act: :browser_action]]})
    assert tools.lens.operations.open.retry == :never
    assert tools.lens.operations.look.retry == :safe
    assert tools.lens.operations.act.path == :governed
    assert tools.lens.operations.act.operation == :browser_action
    refute Map.has_key?(Spectre.Lens.tools(@config).lens.operations, :act)
    assert Spectre.Stack.Tools.validate!(tools) == tools
  end

  test "preparation validates the provider's closed schema before any browser access" do
    {:ok, tab} = TabRef.to_map(%TabRef{id: "tab", instance_id: 1})
    trusted = %{config: @config}

    assert {:ok, %{"url" => "https://example.test"}} =
             ServerTool.prepare(:open, ["https://example.test"], trusted)

    assert {:ok, _} = ServerTool.prepare(:look, [tab], trusted)

    assert {:ok, _} =
             ServerTool.prepare(:act, [tab, %{"type" => "click", "text" => "Save"}], trusted)

    assert {:error, _} =
             ServerTool.prepare(:act, [tab, %{"type" => "execute_javascript"}], trusted)

    assert {:error, _} =
             ServerTool.prepare(:act, [tab, %{"type" => "click", "runtime" => self()}], trusted)

    assert {:error, :lens_tab_reference_required} = ServerTool.prepare(:look, [self()], trusted)
  end

  test "view projection preserves untrusted content without live handles or native records" do
    view = %View{
      url: "https://example.test",
      title: "Luca",
      markdown: "Uses Shopify",
      actions: [%ActionRef{id: "save", kind: :button, label: "Save"}]
    }

    assert {:ok, {:ok, result}} = ServerTool.project(:look, {:ok, view})
    assert result.trust == :untrusted
    assert result.markdown == "Uses Shopify"
    assert result.actions == [Map.from_struct(hd(view.actions))]
    assert is_binary(result.context)
    assert {:ok, _} = Spectre.GAM.Canonical.Value.encode(result)
    assert {:error, :nonportable_lens_result} = ServerTool.project(:open, {:ok, %{tab: self()}})
  end

  test "executor adapter acts once through the real provider and close releases the resource" do
    runtime =
      start_supervised!(
        {Spectre.Stack.Runtime, stack: Stack, packages: [lens: [test_pid: self()]]}
      )

    context = %{
      agent: Agent,
      options: [stack_runtime: runtime, lens_opts: [network_policy: :any]]
    }

    {:ok, config} = Spectre.Lens.config(Agent)
    tool_context = %{service_context: context, config: config}

    assert {:ok, tab} =
             ServerTool.execute_effect(:open, %{"url" => "https://example.test"}, context)

    assert {:ok, ref} = TabRef.from_map(tab)
    assert {:ok, browser_runtime} = Spectre.Lens.runtime(Agent, context.options)
    assert {:ok, _live_tab} = SpectreLens.resolve_tab(browser_runtime, ref)

    assert {:ok, args} =
             ServerTool.prepare(:act, [tab, %{"type" => "click", "ref" => "#save"}], %{
               config: config
             })

    refute_received {:browser_clicked, _, _}
    assert {:ok, :ok} = ServerTool.execute(:act, args, context)
    assert_receive {:browser_clicked, "tool-tab", "#save"}
    refute_received {:browser_clicked, _, _}

    assert {:error, _} =
             ServerTool.execute(
               :act,
               %{"tab" => tab, "action" => %{"type" => "execute_javascript"}},
               context
             )

    refute_received {:browser_clicked, _, _}

    assert {:ok, close_args} = ServerTool.prepare(:close, [tab], %{config: config})
    assert {:ok, %{closed: true}} = ServerTool.invoke(:close, close_args, tool_context)
    assert_receive {:browser_closed, "tool-tab"}
    # Synchronize the runtime after the protocol's release cast.
    :sys.get_state(browser_runtime)
    assert {:error, _} = SpectreLens.resolve_tab(browser_runtime, ref)
    assert {:error, _} = ServerTool.invoke(:close, close_args, tool_context)
    refute_received {:browser_closed, _}
  end
end
