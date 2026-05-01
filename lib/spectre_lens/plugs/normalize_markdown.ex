defmodule SpectreLens.Plugs.NormalizeMarkdown do
  @moduledoc false

  alias SpectreLens.{Context, Plug}

  @behaviour Plug

  @doc false
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
