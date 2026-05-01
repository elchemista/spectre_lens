defmodule SpectreLens.Plugs.SemanticTree do
  @moduledoc false

  alias SpectreLens.{Context, Plug}
  alias SpectreLens.Plugs.Helpers

  @behaviour Plug

  @doc false
  @spec call(Context.t(), keyword()) :: Context.t()
  def call(context, opts) do
    context
    |> maybe_json(opts)
    |> maybe_text(opts)
  end

  @spec maybe_json(Context.t(), keyword()) :: Context.t()
  defp maybe_json(context, opts) do
    if Helpers.included?(context, :semantic_tree) do
      Helpers.collect(context, :semantic_tree, fn ->
        SpectreLens.Protocol.semantic_tree(context.tab, Keyword.merge(opts, format: :json))
      end)
    else
      context
    end
  end

  @spec maybe_text(Context.t(), keyword()) :: Context.t()
  defp maybe_text(context, opts) do
    if Helpers.included?(context, :semantic_text) do
      Helpers.collect(context, :semantic_text, fn ->
        SpectreLens.Protocol.semantic_tree(context.tab, Keyword.merge(opts, format: :text))
      end)
    else
      context
    end
  end
end
