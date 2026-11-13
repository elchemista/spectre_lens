defmodule Spectre.Lens.ServerToolTest do
  use ExUnit.Case, async: true

  alias Spectre.Lens.ServerTool
  alias SpectreLens.{ActionRef, TabRef, View}

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
end
