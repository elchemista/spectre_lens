defmodule SpectreLens.Plugs.EmptyViewDiagnostics do
  @moduledoc """
  Adds diagnostics when requested page projections come back empty.

  Empty rendered output is usually an adapter or page-readiness problem. The
  diagnostic map keeps those details visible without raising from `look/2`.
  """

  alias SpectreLens.{Context, Plug}
  alias SpectreLens.Plugs.Helpers

  @behaviour Plug

  @impl Plug
  @spec call(Context.t(), keyword()) :: Context.t()
  def call(%Context{} = context, _opts) do
    if empty_requested_projection?(context) do
      Helpers.put_error(context, {:empty_page_projection, diagnostic_details(context)})
    else
      context
    end
  end

  @spec empty_requested_projection?(Context.t()) :: boolean()
  defp empty_requested_projection?(%Context{include: include, view: view}) do
    projection_requested?(include) and empty_view_content?(view)
  end

  @spec projection_requested?([atom()]) :: boolean()
  defp projection_requested?(include) do
    requested = MapSet.new(include)
    MapSet.member?(requested, :markdown) or MapSet.member?(requested, :semantic_tree)
  end

  @spec empty_view_content?(SpectreLens.View.t()) :: boolean()
  defp empty_view_content?(view) do
    blank?(view.markdown) and blank_tree?(view.semantic_tree) and
      Enum.empty?(view.interactive) and Enum.empty?(view.forms) and Enum.empty?(view.links)
  end

  @spec diagnostic_details(Context.t()) :: map()
  defp diagnostic_details(%Context{view: view}) do
    %{
      url: view.url,
      title: view.title,
      markdown_size: byte_size(view.markdown || ""),
      semantic_children: semantic_child_count(view.semantic_tree),
      interactive_count: length(view.interactive),
      form_count: length(view.forms),
      link_count: length(view.links)
    }
  end

  @spec blank?(term()) :: boolean()
  defp blank?(value) when value in [nil, ""], do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  @spec blank_tree?(term()) :: boolean()
  defp blank_tree?(nil), do: true
  defp blank_tree?(%{} = tree) when map_size(tree) == 0, do: true

  defp blank_tree?(%{"children" => children}) when is_list(children),
    do: Enum.empty?(children)

  defp blank_tree?(_tree), do: false

  @spec semantic_child_count(term()) :: non_neg_integer()
  defp semantic_child_count(%{"children" => children}) when is_list(children),
    do: length(children)

  defp semantic_child_count(_tree), do: 0
end
