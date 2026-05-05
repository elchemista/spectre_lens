defmodule SpectreLens.Plugs do
  @moduledoc "Built-in plugs for the agent-readable page projection."

  @doc "Returns the default inspection pipeline."
  @spec default() :: [module()]
  def default do
    [
      SpectreLens.Plugs.BasicInfo,
      SpectreLens.Plugs.Html,
      SpectreLens.Plugs.Markdown,
      SpectreLens.Plugs.SemanticTree,
      SpectreLens.Plugs.Interactive,
      SpectreLens.Plugs.Forms,
      SpectreLens.Plugs.Links,
      SpectreLens.Plugs.StructuredData,
      SpectreLens.Plugs.LlmsTxt,
      SpectreLens.Plugs.NormalizeMarkdown,
      SpectreLens.Plugs.ActionRefs,
      SpectreLens.Plugs.EmptyViewDiagnostics,
      SpectreLens.Plugs.Hash
    ]
  end
end
