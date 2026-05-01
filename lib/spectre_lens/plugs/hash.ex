defmodule SpectreLens.Plugs.Hash do
  @moduledoc false

  alias SpectreLens.{Context, Plug}

  @behaviour Plug

  @doc false
  @spec call(Context.t(), keyword()) :: Context.t()
  def call(context, _opts) do
    projection =
      [
        context.view.url,
        context.view.title,
        context.view.markdown,
        context.view.llms_context,
        context.view.semantic_text,
        Jason.encode!(context.view.interactive),
        Jason.encode!(context.view.forms)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    hash = :crypto.hash(:sha256, projection) |> Base.encode16(case: :lower)
    put_in(context.assigns[:hash], hash)
  end
end
