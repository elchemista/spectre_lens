defmodule SpectreLens.Plugs.Hash do
  @moduledoc """
  Computes a stable hash for the agent-facing view projection.

  Watchers use this hash to detect meaningful page changes without comparing
  full nested view structs.
  """

  alias SpectreLens.{Context, Plug}

  @behaviour Plug

  @impl Plug
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
