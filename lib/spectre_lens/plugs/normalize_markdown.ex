defmodule SpectreLens.Plugs.NormalizeMarkdown do
  @moduledoc """
  Normalizes Markdown whitespace before the view leaves the pipeline.

  The goal is stable, readable context: trailing line spaces are removed and
  excessive blank runs are collapsed without changing content.
  """

  alias SpectreLens.{Context, Plug}

  @behaviour Plug

  @impl Plug
  @spec call(Context.t(), keyword()) :: Context.t()
  def call(%{view: %{markdown: markdown}} = context, _opts) when is_binary(markdown) do
    normalized =
      markdown
      |> String.replace(~r/[ \t]+\n/, "\n")
      |> String.replace(~r/\n{4,}/, "\n\n\n")
      |> String.trim()

    put_in(context.view.markdown, normalized)
  end

  def call(context, _opts), do: context
end
