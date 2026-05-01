defmodule SpectreLens.Plugs.Interactive do
  @moduledoc false

  alias SpectreLens.{Context, Plug}
  alias SpectreLens.Plugs.Helpers

  @behaviour Plug

  @doc false
  @spec call(Context.t(), keyword()) :: Context.t()
  def call(context, opts) do
    if Helpers.included?(context, :interactive) do
      Helpers.collect(context, :interactive, fn ->
        SpectreLens.Protocol.interactive_elements(context.tab, opts)
      end)
    else
      context
    end
  end
end
