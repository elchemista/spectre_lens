defmodule SpectreLens.Protocol.Lightpanda do
  @moduledoc """
  Lightpanda-optimized implementation of `SpectreLens.Protocol`.

  Standard navigation and interaction delegate to the browser-neutral CDP
  adapter. Agent projections use Lightpanda's current `LP.*` domain when that
  provides a richer native representation.
  """

  @behaviour SpectreLens.Protocol

  alias SpectreLens.Protocol.CDP
  alias SpectreLens.Tab

  @impl SpectreLens.Protocol
  def new_tab(instance, opts \\ []) do
    opts =
      opts
      |> Keyword.put(:protocol, __MODULE__)
      |> Keyword.put(:runtime, opts[:runtime])
      |> Keyword.put(:instance_id, instance.id)
      |> Keyword.put(:endpoint, instance.endpoint)

    SpectreLens.Page.new(instance.connection, opts)
  end

  @impl SpectreLens.Protocol
  def markdown(%Tab{} = tab, opts) do
    params =
      %{}
      |> maybe_put("nodeId", opts[:node_id])
      |> maybe_put("backendNodeId", opts[:backend_node_id])

    native_or_standard(
      fn ->
        with {:ok, result} <- CDP.command(tab, "LP.getMarkdown", params, opts) do
          {:ok, result["markdown"] || result["text"] || ""}
        end
      end,
      fn -> CDP.markdown(tab, opts) end
    )
  end

  @impl SpectreLens.Protocol
  def semantic_tree(%Tab{} = tab, opts) do
    params =
      %{}
      |> maybe_put("format", semantic_tree_format(opts[:format] || :json))
      |> maybe_put("prune", opts[:prune])

    native_or_standard(
      fn ->
        with {:ok, result} <- CDP.command(tab, "LP.getSemanticTree", params, opts) do
          {:ok, result["semanticTree"] || result["tree"] || result["nodes"] || result}
        end
      end,
      fn -> CDP.semantic_tree(tab, opts) end
    )
  end

  @impl SpectreLens.Protocol
  def interactive_elements(%Tab{} = tab, opts) do
    native_or_standard(
      fn ->
        with {:ok, result} <- CDP.command(tab, "LP.getInteractiveElements", %{}, opts) do
          {:ok, result["elements"] || []}
        end
      end,
      fn -> CDP.interactive_elements(tab, opts) end
    )
  end

  @impl SpectreLens.Protocol
  def structured_data(%Tab{} = tab, opts) do
    native_or_standard(
      fn ->
        with {:ok, result} <- CDP.command(tab, "LP.getStructuredData", %{}, opts) do
          {:ok, result["structuredData"] || result}
        end
      end,
      fn -> CDP.structured_data(tab, opts) end
    )
  end

  @impl SpectreLens.Protocol
  defdelegate close_tab(tab), to: CDP

  @impl SpectreLens.Protocol
  defdelegate command(tab, method, params, opts), to: CDP

  @impl SpectreLens.Protocol
  defdelegate navigate(tab, url, opts), to: CDP

  @impl SpectreLens.Protocol
  defdelegate evaluate(tab, expression, opts), to: CDP

  @impl SpectreLens.Protocol
  defdelegate url(tab), to: CDP

  @impl SpectreLens.Protocol
  defdelegate title(tab), to: CDP

  @impl SpectreLens.Protocol
  defdelegate html(tab, opts), to: CDP

  @impl SpectreLens.Protocol
  defdelegate page_map(tab, opts), to: CDP

  @impl SpectreLens.Protocol
  defdelegate focus(tab, ref, opts), to: CDP

  @impl SpectreLens.Protocol
  defdelegate links(tab, opts), to: CDP

  @impl SpectreLens.Protocol
  defdelegate forms(tab, opts), to: CDP

  @impl SpectreLens.Protocol
  defdelegate screenshot(tab, opts), to: CDP

  @impl SpectreLens.Protocol
  defdelegate pdf(tab, opts), to: CDP

  @impl SpectreLens.Protocol
  defdelegate click(tab, ref, opts), to: CDP

  @impl SpectreLens.Protocol
  defdelegate fill(tab, ref, value, opts), to: CDP

  @impl SpectreLens.Protocol
  defdelegate submit(tab, ref, fields, opts), to: CDP

  @impl SpectreLens.Protocol
  defdelegate wait_for_selector(tab, selector, opts), to: CDP

  @impl SpectreLens.Protocol
  defdelegate wait_for_navigation(tab, fun, opts), to: CDP

  @impl SpectreLens.Protocol
  defdelegate scroll(tab, opts), to: CDP

  @impl SpectreLens.Protocol
  defdelegate capture_session(tab, opts), to: CDP

  @impl SpectreLens.Protocol
  defdelegate restore_session(tab, session, opts), to: CDP

  @impl SpectreLens.Protocol
  defdelegate tab_key(tab), to: CDP

  @impl SpectreLens.Protocol
  defdelegate handle_tab_closed(tab), to: CDP

  @impl SpectreLens.Protocol
  defdelegate subscribe(instance, subscriber), to: CDP

  @impl SpectreLens.Protocol
  defdelegate handle_info(message, instance), to: CDP

  @spec semantic_tree_format(term()) :: binary() | nil
  defp semantic_tree_format(:json), do: nil
  defp semantic_tree_format("json"), do: nil
  defp semantic_tree_format(:text), do: "text"
  defp semantic_tree_format("text"), do: "text"
  defp semantic_tree_format(format), do: to_string(format)

  @spec native_or_standard((-> term()), (-> term())) :: term()
  defp native_or_standard(native, standard) do
    case native.() do
      {:error, %SpectreLens.CDPError{code: -32_601}} -> standard.()
      result -> result
    end
  end

  @spec maybe_put(map(), binary(), term() | nil) :: map()
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
